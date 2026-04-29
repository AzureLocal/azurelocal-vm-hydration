#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a plain, never-managed Hyper-V VM on an Azure Local cluster ready for hydration testing.

.DESCRIPTION
    Sets up a test VM that mirrors a real "unmanaged VM" scenario:
    - Creates a small dynamically-expanding VHD under the cluster storage GUID folder
    - Creates the Hyper-V VM pointing at that VHD
    - Enables required integration services (KVP, Guest Service Interface)
    - Configures the VM as Highly Available in Failover Cluster Manager
    - Starts the VM

    The VM has no Azure registration, no Arc agent, and no Azure resource — exactly
    what Invoke-VMHydration.ps1 expects as input.

    Outputs a hashtable of test context values for use by Invoke-HydrationTest.ps1.

.PARAMETER VMName
    Name for the test VM. Defaults to "test-hydration-<timestamp>".

.PARAMETER StorageRootPath
    Root path of the cluster shared volume to place the VHD under.
    Example: C:\ClusterStorage\Volume1

.PARAMETER VhdSizeGB
    Size of the test VHD in GB. Default: 8 (small for fast setup).

.PARAMETER Generation
    Hyper-V generation. 1 or 2. Default: 2.

.PARAMETER SourceVhdPath
    Optional. Full path to an existing Windows Server VHDX to copy into the test VM folder.
    If omitted, an empty dynamically-allocated VHD is created — sufficient to test Azure resource
    registration but the VM will not boot into Windows (no guest OS, no Arc agent, no KVP exchange).

    For full end-to-end testing (Arc agent, Guest Management, KVP), supply a path to a sysprepped
    or clean Windows Server VHDX. Example:
        -SourceVhdPath 'C:\ClusterStorage\csv-01\ISOs\WS2022_template.vhdx'

.PARAMETER SwitchName
    Hyper-V virtual switch to connect the VM to. If not specified, no NIC is attached
    (the hydration script will create the Azure NIC separately).

.EXAMPLE
    # Azure resource layer test only (no OS needed):
    $ctx = .\New-HydrationTestVM.ps1 -StorageRootPath 'C:\ClusterStorage\Volume1'

.EXAMPLE
    # Full end-to-end test with a real Windows Server VHD:
    $ctx = .\New-HydrationTestVM.ps1 `
        -StorageRootPath 'C:\ClusterStorage\Volume1' `
        -SourceVhdPath   'C:\ClusterStorage\Volume1\ISOs\WS2022_template.vhdx'

.NOTES
    Run on one of the Azure Local cluster nodes.
    After this script completes, run Invoke-HydrationTest.ps1 to execute the test.
    Run Remove-HydrationTestResources.ps1 to clean up after testing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$StorageRootPath,

    [Parameter()]
    [int]$VhdSizeGB = 8,

    [Parameter()]
    [ValidateSet(1, 2)]
    [int]$Generation = 2,

    [Parameter()]
    [string]$SourceVhdPath,

    [Parameter()]
    [string]$SwitchName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. "$TestDir\helpers\Test-Common.ps1"

if (-not $VMName) {
    $VMName = "test-hydration-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

Write-TestBanner "Hydration Test VM Setup: $VMName"

#region ── Validate Storage Root ─────────────────────────────────────────────

Write-TestStep "Validating storage root path"

if (-not (Test-Path $StorageRootPath)) {
    Write-TestFail "Storage root path not found: $StorageRootPath"
    exit 1
}
Write-TestInfo "Storage root: $StorageRootPath"

#endregion

#region ── Create GUID Folder and VHD ────────────────────────────────────────

Write-TestStep "Creating VM folder under cluster storage GUID path"

$vmFolder = Get-ClusterStorageGuidPath -StorageRootPath $StorageRootPath -VMName $VMName
Write-TestInfo "VM folder: $vmFolder"

$vhdPath = Join-Path $vmFolder "$VMName-os.vhdx"

if ($SourceVhdPath) {
    if (-not (Test-Path $SourceVhdPath)) {
        Write-TestFail "SourceVhdPath not found: $SourceVhdPath"
        exit 1
    }
    Write-TestStep "Copying source VHD to test folder: $vhdPath"
    if ($PSCmdlet.ShouldProcess($vhdPath, 'Copy-Item')) {
        Copy-Item -Path $SourceVhdPath -Destination $vhdPath -Force -ErrorAction Stop
        Write-TestInfo "VHD copied from: $SourceVhdPath"
    }
} else {
    Write-TestStep "Creating empty test VHD ($VhdSizeGB GB): $vhdPath"
    Write-TestWarn "No -SourceVhdPath specified — VHD will be empty (no OS)."
    Write-TestWarn "VM will start but not boot. Azure resource registration tests will still pass."
    Write-TestWarn "For full end-to-end testing supply -SourceVhdPath pointing to a Windows Server VHDX."
    if ($PSCmdlet.ShouldProcess($vhdPath, 'New-VHD')) {
        New-VHD -Path $vhdPath -SizeBytes ($VhdSizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
        Write-TestInfo "Empty VHD created: $vhdPath"
    }
}

#endregion

#region ── Create Hyper-V VM ──────────────────────────────────────────────────

Write-TestStep "Creating Hyper-V VM '$VMName' (Generation $Generation)"

$vmParams = @{
    Name               = $VMName
    MemoryStartupBytes = 512MB
    Generation         = $Generation
    VHDPath            = $vhdPath
    Path               = $vmFolder
    ErrorAction        = 'Stop'
}
if ($SwitchName) { $vmParams['SwitchName'] = $SwitchName }

if ($PSCmdlet.ShouldProcess($VMName, 'New-VM')) {
    $vm = New-VM @vmParams
    Write-TestInfo "VM created: $($vm.VMId)"

    # Configure processors and memory
    Set-VMProcessor -VMName $VMName -Count 2
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes 512MB
}

#endregion

#region ── Enable Integration Services ───────────────────────────────────────

Write-TestStep "Enabling required Hyper-V integration services"

if ($PSCmdlet.ShouldProcess($VMName, 'Enable integration services')) {
    Enable-VMIntegrationService -VMName $VMName -Name 'Key-Value Pair Exchange' -ErrorAction Stop
    Write-TestInfo "Enabled: Key-Value Pair Exchange (KVP)"

    Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction Stop
    Write-TestInfo "Enabled: Guest Service Interface"
}

#endregion

#region ── Configure as Highly Available VM ───────────────────────────────────

Write-TestStep "Configuring VM as Highly Available in Failover Cluster"

try {
    if ($PSCmdlet.ShouldProcess($VMName, 'Add-ClusterVirtualMachineRole')) {
        Add-ClusterVirtualMachineRole -VMName $VMName -ErrorAction Stop | Out-Null
        Write-TestInfo "VM added to Failover Cluster as HA VM"
    }
} catch {
    Write-TestWarn "Could not add to cluster: $_"
    Write-TestWarn "If this is a single-node test environment, the HA check will fail in pre-flight."
    Write-TestWarn "Pass -SkipClusterCheck to Invoke-VMHydration.ps1 in that case."
}

#endregion

#region ── Start VM ───────────────────────────────────────────────────────────

Write-TestStep "Starting VM '$VMName'"

if ($PSCmdlet.ShouldProcess($VMName, 'Start-VM')) {
    Start-VM -Name $VMName -ErrorAction Stop
    Write-TestInfo "VM started"
}

#endregion

#region ── Output Test Context ────────────────────────────────────────────────

$guidFolder = Split-Path $vmFolder -Parent

$context = @{
    VMName         = $VMName
    VhdPath        = $vhdPath
    VMFolder       = $vmFolder
    GuidFolderPath = $guidFolder
    StorageRoot    = $StorageRootPath
    Generation     = $Generation
    HasRealOS      = [bool]$SourceVhdPath
    SetupTime      = (Get-Date -Format 'o')
}

Write-TestBanner "Test VM Ready"
Write-TestInfo "VM Name       : $VMName"
Write-TestInfo "VHD Path      : $vhdPath"
Write-TestInfo "GUID Folder   : $guidFolder"
Write-TestInfo "Generation    : Gen$Generation"
Write-TestInfo "Has real OS   : $([bool]$SourceVhdPath)"
Write-Host ""
Write-Host "  Next: run Invoke-HydrationTest.ps1 with these values." -ForegroundColor Cyan
Write-Host "  Cleanup: run Remove-HydrationTestResources.ps1 -VMName '$VMName'" -ForegroundColor Cyan
Write-Host ""

# Return context for pipeline use
return $context

#endregion
