#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up the "was managed, now orphaned" test scenario for Invoke-VMReconnect.ps1.

.DESCRIPTION
    Simulates the cross-cluster restore scenario where a VM was registered with Azure Local,
    was backed up, and then restored to a different cluster location — leaving the original
    Azure resource orphaned.

    On a single cluster this is simulated by:

    PHASE A — Create and hydrate a test VM (makes it Azure-managed):
      1. Create a plain Hyper-V test VM (via New-HydrationTestVM.ps1)
      2. Hydrate it (via Invoke-VMHydration.ps1) — now it has an Azure resource
      3. Validate the Azure resource exists and is Succeeded

    PHASE B — Simulate the restore / disconnect:
      4. Stop the VM
      5. Export the VM to a temporary backup location
      6. Delete the Azure VM resource (az stack-hci-vm delete) — this orphans the Azure record
         NOTE: The VM still exists in Hyper-V; only the Azure resource is removed
      7. Import the VM from the export into a NEW GUID folder path
         (simulates what Veeam/export-import does: VM lands at a different storage path)
      8. Add re-imported VM to Failover Cluster as HA
      9. Start the re-imported VM

    The result: a VM running in Hyper-V with no Azure resource — exactly what
    Invoke-VMReconnect.ps1 is designed to fix.

.PARAMETER VMName
    Base name for the test VM. The re-imported VM gets a "-restored" suffix.
    Defaults to "test-reconnect-<timestamp>".

.PARAMETER ResourceGroup
    Azure resource group used during the initial hydration phase.

.PARAMETER CustomLocation
    Custom location URI for the Azure Local cluster.

.PARAMETER StoragePathId
    Storage path resource ID used during hydration.

.PARAMETER StorageRootPath
    Local filesystem root of the cluster shared volume (e.g. C:\ClusterStorage\Volume1).

.PARAMETER SubnetId
    Logical network for the initial NIC (hydration phase).

.PARAMETER Location
    Azure region.

.PARAMETER ExportPath
    Temporary path for the VM export. Defaults to C:\Temp\HydrationTestExport.
    Cleaned up automatically after re-import.

.EXAMPLE
    $ctx = .\New-ReconnectTestScenario.ps1 `
        -ResourceGroup 'rg-azlocal-test' `
        -CustomLocation '...' -StoragePathId '...' `
        -StorageRootPath 'C:\ClusterStorage\Volume1' `
        -SubnetId 'lnet-test' -Location 'eastus'

.NOTES
    Run on one of the Azure Local cluster nodes. Azure CLI must be authenticated.
    After setup, run Invoke-ReconnectTest.ps1.
    Run Remove-ReconnectTestResources.ps1 to clean up.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VMName,

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
    [string]$ExportPath = 'C:\Temp\HydrationTestExport',

    [Parameter()]
    [switch]$SkipClusterCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptsDir = Join-Path (Split-Path -Parent $TestDir) 'scripts'

. "$TestDir\helpers\Test-Common.ps1"

if (-not $VMName) {
    $VMName = "test-reconnect-$(Get-Date -Format 'yyyyMMddHHmmss')"
}
$RestoredVMName = "$VMName-restored"
$InitialNicName = "$VMName-nic1"

Write-TestBanner "Reconnect Test Scenario Setup: $VMName"

#region ── Phase A: Create and Hydrate Test VM ────────────────────────────────

Write-TestStep "Phase A — Creating and hydrating test VM '$VMName'"

# Create plain Hyper-V VM
$ctx = & "$TestDir\hydration\New-HydrationTestVM.ps1" `
    -VMName $VMName `
    -StorageRootPath $StorageRootPath `
    -Generation 2

Write-TestInfo "VM created at: $($ctx.VMFolder)"

# Hydrate it
Write-TestStep "Hydrating VM (creating Azure resource)"
& "$ScriptsDir\Invoke-VMHydration.ps1" `
    -VMName $VMName `
    -ResourceGroup $ResourceGroup `
    -CustomLocation $CustomLocation `
    -StoragePathId $StoragePathId `
    -NicName $InitialNicName `
    -SubnetId $SubnetId `
    -Location $Location `
    -SkipClusterCheck:$SkipClusterCheck

# Wait for Azure resource to be Succeeded
$ready = Wait-ForAzureResource -VMName $VMName -ResourceGroup $ResourceGroup -TimeoutSeconds 300
if (-not $ready) {
    Write-TestFail "VM did not reach Succeeded state after hydration. Cannot continue setup."
    exit 1
}
Write-TestInfo "Azure resource confirmed Succeeded"

#endregion

#region ── Phase B: Simulate Restore / Disconnect ────────────────────────────

Write-TestStep "Phase B — Simulating disconnect and cross-cluster restore"

# Stop the VM
Write-TestInfo "Stopping VM '$VMName'"
Stop-VM -Name $VMName -Force -ErrorAction Stop

# Export VM to temp path
Write-TestStep "Exporting VM to '$ExportPath' (simulating backup)"
if (-not (Test-Path $ExportPath)) { New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null }
Export-VM -Name $VMName -Path $ExportPath -ErrorAction Stop
Write-TestInfo "Export complete: $ExportPath\$VMName"

# Delete the Azure resource — this is the "orphan" step
Write-TestStep "Deleting Azure VM resource '$VMName' (simulating orphan state)"
Write-TestWarn "This is intentional — simulating a VM that lost its Azure connection."
$delOutput = & az stack-hci-vm delete --name $VMName --resource-group $ResourceGroup --yes --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-TestWarn "Azure VM delete returned non-zero: $($delOutput | Out-String)"
    Write-TestWarn "Continuing anyway — the VM may have already been unregistered."
}
Write-TestInfo "Azure VM resource deleted (orphan state created)"

# Remove the original VM from Hyper-V (keeping the export)
Write-TestStep "Removing original Hyper-V VM (keeping export)"
try {
    $clusterResource = Get-ClusterResource -ErrorAction SilentlyContinue |
        Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.Name -like "*$VMName*" }
    if ($clusterResource) {
        Remove-ClusterGroup -Name $clusterResource.OwnerGroup -RemoveResources -Force
        Write-TestInfo "Removed from Failover Cluster"
    }
} catch {
    Write-TestWarn "Cluster removal skipped: $_"
}
Remove-VM -Name $VMName -Force -ErrorAction Stop
Write-TestInfo "Original Hyper-V VM removed"

# Import VM into a NEW GUID folder (simulating restore to different path)
Write-TestStep "Re-importing VM to a new GUID folder (simulating backup restore)"

$newVmFolder   = Get-ClusterStorageGuidPath -StorageRootPath $StorageRootPath -VMName $RestoredVMName
$exportVmcx    = Get-ChildItem -Path "$ExportPath\$VMName" -Filter '*.vmcx' -Recurse | Select-Object -First 1
$exportVhdPath = Get-ChildItem -Path "$ExportPath\$VMName" -Filter '*.vhdx' -Recurse | Select-Object -First 1

if (-not $exportVmcx) {
    Write-TestFail "Could not find .vmcx in export at '$ExportPath\$VMName'"
    exit 1
}

# Copy VHD to new GUID folder before import
$newVhdPath = Join-Path $newVmFolder "$RestoredVMName-os.vhdx"
Copy-Item -Path $exportVhdPath.FullName -Destination $newVhdPath -Force
Write-TestInfo "VHD copied to new GUID folder: $newVhdPath"

# Import as new VM with a different name to the new path
$importedVm = Import-VM `
    -Path $exportVmcx.FullName `
    -Copy `
    -GenerateNewId `
    -VirtualMachinePath $newVmFolder `
    -VhdDestinationPath $newVmFolder `
    -ErrorAction Stop

# Rename to the restored VM name
Rename-VM -VM $importedVm -NewName $RestoredVMName
Write-TestInfo "VM imported as '$RestoredVMName'"

# Update VHD path to the copied one
Get-VMHardDiskDrive -VMName $RestoredVMName | Remove-VMHardDiskDrive
Add-VMHardDiskDrive -VMName $RestoredVMName -Path $newVhdPath
Write-TestInfo "VHD path updated to: $newVhdPath"

# Remove any NICs from the restored VM (they reference the old switch)
Get-VMNetworkAdapter -VMName $RestoredVMName -ErrorAction SilentlyContinue |
    Remove-VMNetworkAdapter -ErrorAction SilentlyContinue
Write-TestInfo "Removed NICs from restored VM (will be added by reconnect script)"

# Re-enable integration services
Enable-VMIntegrationService -VMName $RestoredVMName -Name 'Key-Value Pair Exchange'
Enable-VMIntegrationService -VMName $RestoredVMName -Name 'Guest Service Interface'
Write-TestInfo "Integration services re-enabled"

# Make HA
try {
    Add-ClusterVirtualMachineRole -VMName $RestoredVMName -ErrorAction Stop | Out-Null
    Write-TestInfo "Re-imported VM configured as HA"
} catch {
    Write-TestWarn "Could not add restored VM to cluster: $_"
}

# Start restored VM
Start-VM -Name $RestoredVMName -ErrorAction Stop
Write-TestInfo "Restored VM started"

# Clean up export
Remove-Item -Path "$ExportPath\$VMName" -Recurse -Force -ErrorAction SilentlyContinue
Write-TestInfo "Export temp files cleaned up"

#endregion

#region ── Output Test Context ────────────────────────────────────────────────

$guidFolder = Split-Path $newVmFolder -Parent

$context = @{
    OriginalVMName   = $VMName
    RestoredVMName   = $RestoredVMName
    ResourceGroup    = $ResourceGroup
    NewVhdPath       = $newVhdPath
    NewVmFolder      = $newVmFolder
    GuidFolderPath   = $guidFolder
    InitialNicName   = $InitialNicName
    SetupTime        = (Get-Date -Format 'o')
}

Write-TestBanner "Reconnect Test Scenario Ready"
Write-TestInfo "Original Azure VM name : $VMName"
Write-TestInfo "Restored Hyper-V name  : $RestoredVMName"
Write-TestInfo "New GUID folder        : $guidFolder"
Write-TestInfo "New VHD path           : $newVhdPath"
Write-Host ""
Write-Host "  Next: run Invoke-ReconnectTest.ps1 with these values." -ForegroundColor Cyan
Write-Host "  Cleanup: run Remove-ReconnectTestResources.ps1 -VMName '$VMName'" -ForegroundColor Cyan
Write-Host ""

return $context

#endregion
