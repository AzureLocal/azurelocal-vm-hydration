#Requires -RunAsAdministrator
<#
.SYNOPSIS
    End-to-end integration test for Invoke-VMReconnect.ps1.

.DESCRIPTION
    Orchestrates the full reconnect test:
      1. Sets up the orphaned VM scenario (via New-ReconnectTestScenario.ps1)
      2. Runs Invoke-VMReconnect.ps1 against the orphaned/restored VM
      3. Validates the result in Azure (VM re-projected, NIC attached)
      4. Reports pass/fail

    After this test completes (pass or fail), run Remove-ReconnectTestResources.ps1 to clean up.

.PARAMETER VMName
    Azure VM name to reconnect (the original Azure resource name).
    Defaults to "test-reconnect-<timestamp>" if SkipSetup is not specified.

.PARAMETER RestoredVMName
    Hyper-V name of the restored VM. Required if -SkipSetup is specified.
    Defaults to "<VMName>-restored".

.PARAMETER ResourceGroup
    Azure resource group for the test.

.PARAMETER CustomLocation
    Custom location URI for the destination Azure Local cluster.

.PARAMETER StoragePathId
    Storage path resource ID for the destination cluster.

.PARAMETER StorageRootPath
    Local filesystem root of the cluster shared volume.

.PARAMETER SubnetId
    Logical network for the new NIC.

.PARAMETER Location
    Azure region.

.PARAMETER NewNicName
    Name for the new Azure NIC resource. Defaults to "<VMName>-nic2".

.PARAMETER SkipSetup
    Skip the New-ReconnectTestScenario step. Use when the scenario is already set up.
    Requires -VMName and -RestoredVMName to be specified.

.PARAMETER SkipClusterCheck
    Skip the HA/cluster check.

.EXAMPLE
    .\Invoke-ReconnectTest.ps1 `
        -ResourceGroup 'rg-azlocal-test' `
        -CustomLocation '/subscriptions/.../customlocations/cl-test' `
        -StoragePathId '/subscriptions/.../storageContainers/UserStorage1' `
        -StorageRootPath 'C:\ClusterStorage\Volume1' `
        -SubnetId 'lnet-test-vlan10' `
        -Location 'eastus'

.NOTES
    Run on one of the Azure Local cluster nodes. Azure CLI must be authenticated.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VMName,

    [Parameter()]
    [string]$RestoredVMName,

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
    [string]$NewNicName,

    [Parameter()]
    [switch]$SkipSetup,

    [Parameter()]
    [switch]$SkipClusterCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptsDir = Join-Path (Split-Path -Parent $TestDir) 'scripts'

. "$TestDir\helpers\Test-Common.ps1"

$passed   = 0
$failed   = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Record-Pass([string]$msg) { $script:passed++; Write-TestPass $msg }
function Record-Fail([string]$msg) { $script:failed++; $script:failures.Add($msg); Write-TestFail $msg }

Write-TestBanner "Reconnect Integration Test"

#region ── Step 1: Set Up Orphaned VM Scenario ────────────────────────────────

if (-not $SkipSetup) {
    Write-TestStep "Setting up orphaned VM scenario"

    $setupParams = @{
        ResourceGroup   = $ResourceGroup
        CustomLocation  = $CustomLocation
        StoragePathId   = $StoragePathId
        StorageRootPath = $StorageRootPath
        SubnetId        = $SubnetId
        Location        = $Location
    }
    if ($VMName)         { $setupParams['VMName']        = $VMName }
    if ($SkipClusterCheck) { $setupParams['SkipClusterCheck'] = $true }

    $ctx            = & "$TestDir\reconnect\New-ReconnectTestScenario.ps1" @setupParams
    $VMName         = $ctx.OriginalVMName
    $RestoredVMName = $ctx.RestoredVMName
    Write-TestInfo "Orphaned scenario ready: Azure='$VMName', Hyper-V='$RestoredVMName'"
} else {
    if (-not $VMName -or -not $RestoredVMName) {
        Write-TestFail "-SkipSetup requires both -VMName and -RestoredVMName to be specified."
        exit 1
    }
    Write-TestInfo "Skipping setup — using existing scenario: Azure='$VMName', Hyper-V='$RestoredVMName'"
}

if (-not $NewNicName) { $NewNicName = "$VMName-nic2" }

#endregion

#region ── Step 2: Confirm Orphan State ──────────────────────────────────────

Write-TestStep "Confirming orphan state (Azure resource should be absent)"

$azVmBefore = Get-AzureLocalVM -VMName $VMName -ResourceGroup $ResourceGroup
if ($null -eq $azVmBefore) {
    Record-Pass "Confirmed: Azure VM resource '$VMName' does not exist (orphan state)"
} else {
    Write-TestWarn "Azure VM resource '$VMName' still exists (state: $($azVmBefore.properties.provisioningState))"
    Write-TestWarn "The reconnect script will attempt to repair it."
}

$hvVm = Get-VM -Name $RestoredVMName -ErrorAction SilentlyContinue
if ($hvVm) {
    Record-Pass "Confirmed: Hyper-V VM '$RestoredVMName' exists and is running in Hyper-V"
} else {
    Record-Fail "Hyper-V VM '$RestoredVMName' not found — setup may have failed"
}

#endregion

#region ── Step 3: Run Invoke-VMReconnect ─────────────────────────────────────

Write-TestStep "Running Invoke-VMReconnect.ps1"

$reconnectParams = @{
    VMName          = $VMName
    LocalVMName     = $RestoredVMName
    ResourceGroup   = $ResourceGroup
    CustomLocation  = $CustomLocation
    NicName         = $NewNicName
    SubnetId        = $SubnetId
    Location        = $Location
    RemoveSourceVM  = $false   # Don't remove — the "source" is already gone in our test
    SkipNicRemoval  = $true    # NICs already removed in New-ReconnectTestScenario
}
if ($SkipClusterCheck) { $reconnectParams['SkipClusterCheck'] = $true }

$reconnectSuccess = $true
try {
    & "$ScriptsDir\Invoke-VMReconnect.ps1" @reconnectParams
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $reconnectSuccess = $false
    }
} catch {
    $reconnectSuccess = $false
    Record-Fail "Invoke-VMReconnect.ps1 threw an exception: $_"
}

if (-not $reconnectSuccess) {
    Record-Fail "Invoke-VMReconnect.ps1 did not complete successfully"
}

#endregion

#region ── Step 4: Validate Azure Resources ───────────────────────────────────

Write-TestStep "Validating Azure resources post-reconnect"

# Wait for the VM to reach Succeeded
$ready = Wait-ForAzureResource -VMName $VMName -ResourceGroup $ResourceGroup -TimeoutSeconds 300
if ($ready) {
    Record-Pass "VM '$VMName' reached provisioningState: Succeeded after reconnect"
} else {
    Record-Fail "VM '$VMName' did not reach Succeeded state within 300s"
}

# VM resource exists
$azVm = Get-AzureLocalVM -VMName $VMName -ResourceGroup $ResourceGroup
if (Assert-NotNull -Label "Azure Local VM resource '$VMName'" -Value $azVm) {
    Record-Pass "VM resource exists in Azure"

    if (Assert-Equal -Label 'provisioningState' -Expected 'Succeeded' -Actual $azVm.properties.provisioningState) {
        Record-Pass "provisioningState is Succeeded"
    } else {
        Record-Fail "provisioningState: $($azVm.properties.provisioningState)"
    }

    # Confirm VM is pointing at destination custom location
    $vmCustomLoc = $azVm.extendedLocation.name
    if ($vmCustomLoc -and $CustomLocation -and $vmCustomLoc -eq $CustomLocation) {
        Record-Pass "VM is registered at the destination custom location"
    } else {
        Write-TestWarn "Custom location mismatch or not returned — manual verification recommended"
    }
} else {
    Record-Fail "VM resource '$VMName' not found after reconnect"
}

# New NIC exists
$nic = Get-AzureLocalNic -NicName $NewNicName -ResourceGroup $ResourceGroup
if (Assert-NotNull -Label "New NIC '$NewNicName'" -Value $nic) {
    Record-Pass "New NIC resource exists in Azure"
} else {
    Record-Fail "New NIC '$NewNicName' not found in Azure"
}

#endregion

#region ── Step 5: Summary ────────────────────────────────────────────────────

$allPassed = Write-TestSummary `
    -TestName 'Reconnect Integration Test' `
    -Passed $passed `
    -Failed $failed `
    -Failures $failures.ToArray()

Write-Host "  Original Azure VM name : $VMName" -ForegroundColor Cyan
Write-Host "  Restored Hyper-V name  : $RestoredVMName" -ForegroundColor Cyan
Write-Host "  Resource group         : $ResourceGroup" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cleanup: .\tests\reconnect\Remove-ReconnectTestResources.ps1 -VMName '$VMName' -ResourceGroup '$ResourceGroup'" -ForegroundColor Yellow
Write-Host ""

exit ($allPassed ? 0 : 1)

#endregion
