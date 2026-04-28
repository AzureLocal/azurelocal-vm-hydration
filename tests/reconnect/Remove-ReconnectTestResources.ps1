#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans up all resources created by the reconnect integration test.

.DESCRIPTION
    Removes Azure and Hyper-V resources for both the original and restored VMs:
      - Azure VM resource (original Azure name)
      - Azure NIC resources (initial NIC from hydration phase + new NIC from reconnect)
      - Azure OS disk resource
      - Hyper-V VMs (original, if still present, and restored)
      - VHD files from cluster storage

.PARAMETER VMName
    Original Azure VM name (base name used during test setup).

.PARAMETER ResourceGroup
    Azure resource group containing the test resources.

.PARAMETER RestoredVMName
    Hyper-V name of the restored VM. Defaults to "<VMName>-restored".

.PARAMETER KeepVhd
    Leave VHD files on disk.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Remove-ReconnectTestResources.ps1 -VMName 'test-reconnect-20260428120000' -ResourceGroup 'rg-azlocal-test'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$RestoredVMName,

    [Parameter()]
    [switch]$KeepVhd,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. "$TestDir\helpers\Test-Common.ps1"

if (-not $RestoredVMName) { $RestoredVMName = "$VMName-restored" }

if (-not $Force -and -not $PSCmdlet.ShouldProcess("reconnect test resources for '$VMName'", 'Delete')) {
    Write-TestWarn "Cleanup cancelled."
    exit 0
}

Write-TestBanner "Reconnect Test Cleanup: $VMName"

#region ── Azure Resource Cleanup ─────────────────────────────────────────────

# Delete Azure VM
foreach ($name in @($VMName)) {
    Write-TestStep "Deleting Azure Local VM '$name'"
    $out = & az stack-hci-vm delete --name $name --resource-group $ResourceGroup --yes --output json 2>&1
    if ($LASTEXITCODE -eq 0) { Write-TestInfo "Deleted Azure VM: $name" }
    else { Write-TestWarn "Could not delete Azure VM '$name' (may not exist)" }
}

# Delete NICs — initial NIC from hydration phase + new NIC from reconnect
$nicNames = @("$VMName-nic1", "$VMName-nic2", "$VMName-test-nic")
foreach ($nic in $nicNames) {
    $out = & az stack-hci-vm network nic delete --name $nic --resource-group $ResourceGroup --yes --output json 2>&1
    if ($LASTEXITCODE -eq 0) { Write-TestInfo "Deleted NIC: $nic" }
}

# Delete OS disk
$osDiskName = "$VMName-osdisk"
$out = & az stack-hci-vm disk delete --name $osDiskName --resource-group $ResourceGroup --yes --output json 2>&1
if ($LASTEXITCODE -eq 0) { Write-TestInfo "Deleted OS disk: $osDiskName" }
else { Write-TestWarn "Could not delete OS disk '$osDiskName' (may not exist)" }

# Delete any data disks
for ($i = 1; $i -le 5; $i++) {
    $ddName = "$VMName-datadisk$i"
    $out = & az stack-hci-vm disk delete --name $ddName --resource-group $ResourceGroup --yes --output json 2>&1
    if ($LASTEXITCODE -eq 0) { Write-TestInfo "Deleted data disk: $ddName" }
}

#endregion

#region ── Hyper-V VM Cleanup ─────────────────────────────────────────────────

foreach ($hvVmName in @($VMName, $RestoredVMName)) {
    $vm = Get-VM -Name $hvVmName -ErrorAction SilentlyContinue
    if (-not $vm) { continue }

    Write-TestStep "Removing Hyper-V VM '$hvVmName'"
    $vhdPaths = (Get-VMHardDiskDrive -VMName $hvVmName -ErrorAction SilentlyContinue).Path

    if ($vm.State -ne 'Off') {
        Stop-VM -Name $hvVmName -Force -ErrorAction SilentlyContinue
    }

    try {
        $clusterResource = Get-ClusterResource -ErrorAction SilentlyContinue |
            Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.Name -like "*$hvVmName*" }
        if ($clusterResource) {
            Remove-ClusterGroup -Name $clusterResource.OwnerGroup -RemoveResources -Force
            Write-TestInfo "Removed '$hvVmName' from Failover Cluster"
        }
    } catch {
        Write-TestWarn "Cluster removal skipped for '$hvVmName': $_"
    }

    Remove-VM -Name $hvVmName -Force -ErrorAction SilentlyContinue
    Write-TestInfo "Removed Hyper-V VM: $hvVmName"

    if (-not $KeepVhd -and $vhdPaths) {
        foreach ($vhd in $vhdPaths) {
            if (Test-Path $vhd) {
                Remove-Item $vhd -Force -ErrorAction SilentlyContinue
                Write-TestInfo "Deleted VHD: $vhd"
                $dir = Split-Path $vhd -Parent
                if ((Get-ChildItem $dir -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item $dir -Force -ErrorAction SilentlyContinue
                    Write-TestInfo "Removed empty folder: $dir"
                }
            }
        }
    }
}

#endregion

Write-TestBanner "Cleanup Complete"
Write-TestInfo "All reconnect test resources for '$VMName' / '$RestoredVMName' have been removed."
