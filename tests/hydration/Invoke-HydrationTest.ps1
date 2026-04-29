#Requires -RunAsAdministrator
<#
.SYNOPSIS
    End-to-end integration test for Invoke-VMHydration.ps1.

.DESCRIPTION
    Orchestrates the full hydration test:
      1. Creates a plain Hyper-V test VM (via New-HydrationTestVM.ps1)
      2. Runs Invoke-VMHydration.ps1 against it
      3. Validates the result in Azure (VM exists, disks hydrated, NIC attached)
      4. Reports pass/fail

    After this test completes (pass or fail), run Remove-HydrationTestResources.ps1 to clean up.

.PARAMETER ResourceGroup
    Azure resource group to create test resources in.

.PARAMETER CustomLocation
    Full ARM URI of the custom location for the test Azure Local cluster.

.PARAMETER StoragePathId
    ARM resource ID of the storage path for the test cluster.

.PARAMETER StorageRootPath
    Local filesystem root of the cluster shared volume (e.g. C:\ClusterStorage\Volume1).
    Used by the test VM setup script.

.PARAMETER SubnetId
    Logical network name or ARM ID for the test NIC.

.PARAMETER Location
    Azure region.

.PARAMETER VMName
    Optional. If specified, skips VM creation and runs the hydration test against an
    already-created test VM (from a previous New-HydrationTestVM.ps1 run).

.PARAMETER NicName
    Name for the test NIC resource. Defaults to "<VMName>-test-nic".

.PARAMETER Generation
    Hyper-V generation to test. 1 or 2. Default: 2.

.PARAMETER SkipClusterCheck
    Skip the HA/cluster check — use on single-node or non-clustered test environments.

.PARAMETER SourceVhdPath
    Optional. Full path to an existing Windows Server VHDX to use as the test VM disk.
    If omitted, an empty VHD is created. The test validates Azure resource registration
    in either mode. Supply a real VHD for full end-to-end testing (Arc agent, Guest Management).

.PARAMETER SkipSetup
    Skip the New-HydrationTestVM step. Use when the VM already exists.

.EXAMPLE
    # Azure resource layer test (empty VHD):
    .\Invoke-HydrationTest.ps1 `
        -ResourceGroup   'rg-azlocal-test' `
        -CustomLocation  '/subscriptions/.../customlocations/cl-test' `
        -StoragePathId   '/subscriptions/.../storageContainers/UserStorage1' `
        -StorageRootPath 'C:\ClusterStorage\Volume1' `
        -SubnetId        'lnet-test-vlan10' `
        -Location        'eastus'

.EXAMPLE
    # Full end-to-end test with real Windows Server VHD:
    .\Invoke-HydrationTest.ps1 `
        -ResourceGroup   'rg-azlocal-test' `
        -CustomLocation  '/subscriptions/.../customlocations/cl-test' `
        -StoragePathId   '/subscriptions/.../storageContainers/UserStorage1' `
        -StorageRootPath 'C:\ClusterStorage\Volume1' `
        -SubnetId        'lnet-test-vlan10' `
        -Location        'eastus' `
        -SourceVhdPath   'C:\ClusterStorage\csv-01\ISOs\WS2022_template.vhdx'

.NOTES
    Run on one of the Azure Local cluster nodes.
    Azure CLI must be authenticated (az login).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$CustomLocation,

    [Parameter(Mandatory)]
    [string]$StoragePathId,

    [Parameter(Mandatory)]
    [string]$StorageRootPath,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [string]$VMName,

    [Parameter()]
    [string]$NicName,

    [Parameter()]
    [ValidateSet(1, 2)]
    [int]$Generation = 2,

    [Parameter()]
    [string]$SourceVhdPath,

    [Parameter()]
    [switch]$SkipClusterCheck,

    [Parameter()]
    [switch]$SkipSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptsDir = Join-Path (Split-Path -Parent $TestDir) 'scripts'

. "$TestDir\helpers\Test-Common.ps1"

$passed   = 0
$failed   = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Record-Pass([string]$msg) { $script:passed++; Write-TestPass $msg }
function Record-Fail([string]$msg) { $script:failed++; $script:failures.Add($msg); Write-TestFail $msg }

Write-TestBanner "Hydration Integration Test"

#region ── Step 1: Create Test VM ─────────────────────────────────────────────

if (-not $SkipSetup) {
    Write-TestStep "Setting up test VM"

    $setupParams = @{
        StorageRootPath = $StorageRootPath
        Generation      = $Generation
    }
    if ($VMName)       { $setupParams['VMName']       = $VMName }
    if ($SourceVhdPath){ $setupParams['SourceVhdPath'] = $SourceVhdPath }

    $ctx = & "$TestDir\hydration\New-HydrationTestVM.ps1" @setupParams
    $VMName = $ctx.VMName
    Write-TestInfo "Test VM created: $VMName (HasRealOS: $($ctx.HasRealOS))"
} else {
    Write-TestInfo "Skipping setup — using existing VM: $VMName"
}

if (-not $NicName) { $NicName = "$VMName-test-nic" }

#endregion

#region ── Step 2: Run Invoke-VMHydration ─────────────────────────────────────

Write-TestStep "Running Invoke-VMHydration.ps1"

$hydrationParams = @{
    VMName          = $VMName
    ResourceGroup   = $ResourceGroup
    CustomLocation  = $CustomLocation
    StoragePathId   = $StoragePathId
    NicName         = $NicName
    SubnetId        = $SubnetId
    Location        = $Location
    HyperVGeneration = if ($Generation -eq 1) { 'V1' } else { 'V2' }
}
if ($SkipClusterCheck) { $hydrationParams['SkipClusterCheck'] = $true }

$hydrationSuccess = $true
try {
    & "$ScriptsDir\Invoke-VMHydration.ps1" @hydrationParams
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $hydrationSuccess = $false
    }
} catch {
    $hydrationSuccess = $false
    Record-Fail "Invoke-VMHydration.ps1 threw an exception: $_"
}

if (-not $hydrationSuccess) {
    Record-Fail "Invoke-VMHydration.ps1 did not complete successfully"
}

#endregion

#region ── Step 3: Validate Azure Resources ───────────────────────────────────

Write-TestStep "Validating Azure resources"

# Wait for provisioning to complete
$ready = Wait-ForAzureResource -VMName $VMName -ResourceGroup $ResourceGroup -TimeoutSeconds 300
if ($ready) {
    Record-Pass "VM '$VMName' reached provisioningState: Succeeded"
} else {
    Record-Fail "VM '$VMName' did not reach Succeeded state within 300s"
}

# VM resource exists
$azVm = Get-AzureLocalVM -VMName $VMName -ResourceGroup $ResourceGroup
if (Assert-NotNull -Label "Azure Local VM resource '$VMName'" -Value $azVm) {
    Record-Pass "VM resource exists in Azure"

    # Provisioning state
    if (Assert-Equal -Label 'provisioningState' -Expected 'Succeeded' -Actual $azVm.properties.provisioningState) {
        Record-Pass "provisioningState is Succeeded"
    } else {
        Record-Fail "provisioningState is not Succeeded: $($azVm.properties.provisioningState)"
    }
} else {
    Record-Fail "VM resource '$VMName' not found in resource group '$ResourceGroup'"
}

# OS disk resource
$osDiskName = "$VMName-osdisk"
$osDisk = Get-AzureLocalDisk -DiskName $osDiskName -ResourceGroup $ResourceGroup
if (Assert-NotNull -Label "OS disk '$osDiskName'" -Value $osDisk) {
    Record-Pass "OS disk resource exists"
} else {
    Record-Fail "OS disk '$osDiskName' not found in Azure"
}

# NIC resource
$nic = Get-AzureLocalNic -NicName $NicName -ResourceGroup $ResourceGroup
if (Assert-NotNull -Label "NIC '$NicName'" -Value $nic) {
    Record-Pass "NIC resource exists"
} else {
    Record-Fail "NIC '$NicName' not found in Azure"
}

#endregion

#region ── Step 4: Summary ────────────────────────────────────────────────────

$allPassed = Write-TestSummary `
    -TestName 'Hydration Integration Test' `
    -Passed $passed `
    -Failed $failed `
    -Failures $failures.ToArray()

Write-Host "  Test VM name   : $VMName" -ForegroundColor Cyan
Write-Host "  Resource group : $ResourceGroup" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cleanup: .\tests\hydration\Remove-HydrationTestResources.ps1 -VMName '$VMName' -ResourceGroup '$ResourceGroup'" -ForegroundColor Yellow
Write-Host ""

exit ($allPassed ? 0 : 1)

#endregion
