#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans up all Azure and Hyper-V resources created by the hydration integration test.

.DESCRIPTION
    Removes, in order:
      1. Azure Local VM resource
      2. Azure OS disk resource
      3. Azure NIC resource
      4. Hyper-V VM (stops if running, removes from cluster, deletes VM)
      5. VHD files from cluster storage (optional — see -KeepVhd)

.PARAMETER VMName
    Name of the test VM to clean up.

.PARAMETER ResourceGroup
    Azure resource group containing the test resources.

.PARAMETER NicName
    Name of the test NIC to delete. Defaults to "<VMName>-test-nic".

.PARAMETER OsDiskName
    Name of the test OS disk to delete. Defaults to "<VMName>-osdisk".

.PARAMETER KeepVhd
    If specified, leaves the VHD files on disk (skips file deletion).
    Useful if you want to re-run the test without re-creating the VHD.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Remove-HydrationTestResources.ps1 -VMName 'test-hydration-20260428120000' -ResourceGroup 'rg-azlocal-test'

.NOTES
    Safe to run even if some resources don't exist — missing resources are skipped with a warning.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$NicName,

    [Parameter()]
    [string]$OsDiskName,

    [Parameter()]
    [switch]$KeepVhd,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. "$TestDir\helpers\Test-Common.ps1"

if (-not $NicName)    { $NicName    = "$VMName-test-nic" }
if (-not $OsDiskName) { $OsDiskName = "$VMName-osdisk" }

if (-not $Force -and -not $PSCmdlet.ShouldProcess("test resources for VM '$VMName'", 'Delete')) {
    Write-TestWarn "Cleanup cancelled."
    exit 0
}

Write-TestBanner "Hydration Test Cleanup: $VMName"

#region ── Azure Resource Cleanup ─────────────────────────────────────────────

Write-TestStep "Deleting Azure Local VM resource '$VMName'"
$vmOutput = & az stack-hci-vm delete --name $VMName --resource-group $ResourceGroup --yes --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-TestInfo "Azure VM resource deleted"
} else {
    Write-TestWarn "Could not delete Azure VM (may not exist): $($vmOutput | Out-String)"
}

Write-TestStep "Deleting Azure OS disk '$OsDiskName'"
$diskOutput = & az stack-hci-vm disk delete --name $OsDiskName --resource-group $ResourceGroup --yes --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-TestInfo "OS disk resource deleted"
} else {
    Write-TestWarn "Could not delete OS disk (may not exist): $($diskOutput | Out-String)"
}

# Also look for any numbered data disks (e.g. VMName-datadisk1, -datadisk2)
for ($i = 1; $i -le 5; $i++) {
    $ddName   = "$VMName-datadisk$i"
    $ddOutput = & az stack-hci-vm disk delete --name $ddName --resource-group $ResourceGroup --yes --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-TestInfo "Data disk '$ddName' deleted"
    }
}

Write-TestStep "Deleting Azure NIC '$NicName'"
$nicOutput = & az stack-hci-vm network nic delete --name $NicName --resource-group $ResourceGroup --yes --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-TestInfo "NIC resource deleted"
} else {
    Write-TestWarn "Could not delete NIC (may not exist): $($nicOutput | Out-String)"
}

#endregion

#region ── Hyper-V VM Cleanup ─────────────────────────────────────────────────

Write-TestStep "Removing Hyper-V VM '$VMName'"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm) {
    # Get VHD paths before removing the VM
    $vhdPaths = (Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue).Path

    # Stop if running
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
        Write-TestInfo "VM stopped"
    }

    # Remove from cluster
    try {
        $clusterResource = Get-ClusterResource -ErrorAction SilentlyContinue |
            Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.Name -like "*$VMName*" }
        if ($clusterResource) {
            Remove-ClusterGroup -Name $clusterResource.OwnerGroup -RemoveResources -Force -ErrorAction Stop
            Write-TestInfo "Removed from Failover Cluster"
        }
    } catch {
        Write-TestWarn "Could not remove from cluster: $_"
    }

    # Remove the VM
    Remove-VM -Name $VMName -Force -ErrorAction Stop
    Write-TestInfo "Hyper-V VM removed"

    # Delete VHD files
    if (-not $KeepVhd -and $vhdPaths) {
        Write-TestStep "Deleting VHD files"
        foreach ($vhd in $vhdPaths) {
            if (Test-Path $vhd) {
                Remove-Item $vhd -Force -ErrorAction SilentlyContinue
                Write-TestInfo "Deleted: $vhd"

                # Also clean up the VM folder if it's empty
                $vmDir = Split-Path $vhd -Parent
                if ((Get-ChildItem $vmDir -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item $vmDir -Force -ErrorAction SilentlyContinue
                    Write-TestInfo "Removed empty folder: $vmDir"
                }
            }
        }
    } elseif ($KeepVhd) {
        Write-TestInfo "-KeepVhd specified — VHD files left on disk"
    }
} else {
    Write-TestWarn "Hyper-V VM '$VMName' not found — may have already been removed"
}

#endregion

Write-TestBanner "Cleanup Complete"
Write-TestInfo "All test resources for '$VMName' have been removed."
