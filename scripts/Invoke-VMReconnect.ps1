#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reconnects an Azure Local VM to its Azure resource after restore to a different cluster.

.DESCRIPTION
    Implements the Microsoft Private Preview VM Reconnection procedure for Azure Local.
    Use this script when a VM has been restored (via Veeam, export/import, or other backup tool)
    to a different Azure Local cluster and its Azure resource is now orphaned or disconnected.

    The operation follows the 5-step Microsoft Private Preview procedure:
      Step 1  Pre-flight validation (prerequisites, cluster version, integration services)
      Step 2  Remove network interfaces from the restored VM (optional)
      Step 3  Hydrate data disks via az stack-hci-vm disk create-from-local
      Step 4  Reconnect the VM and attach hydrated disks via az stack-hci-vm reconnect-to-azure
      Step 5  Create and attach a new NIC on the destination cluster's logical network

    Primary reference: reference/AzureLocalVMReconnectPrivatePreview_02232026.md

.PARAMETER VMName
    The VM name as it exists in Azure (the original Azure resource name).

.PARAMETER LocalVMName
    The VM name as it appears in Hyper-V Manager on the restored (destination) cluster.
    If not specified, defaults to VMName.

.PARAMETER ResourceGroup
    The original Azure resource group the VM was created in.

.PARAMETER CustomLocation
    Full ARM URI of the custom location for the DESTINATION Azure Local cluster.
    Example: /subscriptions/<sub>/resourcegroups/<rg>/providers/microsoft.extendedlocation/customlocations/<name>

.PARAMETER NicName
    Name for the new Azure NIC resource to be created on the destination cluster.

.PARAMETER SubnetId
    Name or ARM resource ID of the logical network (lnet) on the destination cluster.

.PARAMETER Location
    Azure region (e.g. 'eastus').

.PARAMETER DataDiskLocalPaths
    Array of local file paths for data disks to hydrate before reconnecting.
    Must be full paths under the cluster storage GUID folder.
    Example: @('C:\ClusterStorage\Vol1\abc123\MyVM\data1.vhdx', 'C:\ClusterStorage\Vol1\abc123\MyVM\data2.vhdx')

.PARAMETER DataDiskNames
    Parallel array of Azure resource names for the hydrated data disks.
    Must match the length of DataDiskLocalPaths.
    Example: @('myvm-data1', 'myvm-data2')

.PARAMETER IpAddress
    Static IP address for the new NIC. Omit to use DHCP.

.PARAMETER RemoveSourceVM
    Passes --yes to az stack-hci-vm reconnect-to-azure. This removes the VM resource
    from the source cluster without prompting. Use with care — this is not reversible.

.PARAMETER SkipNicRemoval
    Skip Step 2 (removing old NICs from the restored VM). Use this if you have already
    removed NICs manually, or if you prefer to add the new NIC as a second NIC after reconnect
    and remove the original NIC afterward.

.PARAMETER SkipClusterCheck
    Skip the HA/Failover Cluster check. Use only in non-clustered test environments.

.EXAMPLE
    .\Invoke-VMReconnect.ps1 `
        -VMName 'APPSRV01' `
        -LocalVMName 'APPSRV01_restored' `
        -ResourceGroup 'rg-azlocal-prod' `
        -CustomLocation '/subscriptions/00000000.../customlocations/cl-eastus-02' `
        -NicName 'APPSRV01-nic2' `
        -SubnetId 'lnet-prod-vlan10' `
        -Location 'eastus' `
        -DataDiskLocalPaths @('C:\ClusterStorage\Volume1\abc123\APPSRV01\data1.vhdx') `
        -DataDiskNames @('APPSRV01-data1') `
        -RemoveSourceVM

.EXAMPLE
    .\Invoke-VMReconnect.ps1 -VMName 'APPSRV01' -LocalVMName 'APPSRV01_restored' `
        -ResourceGroup 'rg-azlocal-prod' -CustomLocation '...' `
        -NicName 'APPSRV01-nic2' -SubnetId 'lnet-prod-vlan10' -Location 'eastus' -WhatIf

.NOTES
    Run on one of the DESTINATION Azure Local cluster nodes, or connect remotely via PowerShell.
    Azure CLI must be authenticated before running (az login).
    stack-hci-vm extension >= 1.11.9 required.
    Azure Local cluster must be running version 2602 or above.

    IMPORTANT — If reconnect fails, do NOT delete the VM resource from the Azure portal or CLI.
    A VM resource may still be created in a failed state. Fix the root cause (ensure VM is
    running and files are in the GUID folder) then re-run this script to repair the resource.
    See: reference/AzureLocalVMReconnectPrivatePreview_02232026.md — Known Issues.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter()]
    [string]$LocalVMName,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$CustomLocation,

    [Parameter(Mandatory)]
    [string]$NicName,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [string[]]$DataDiskLocalPaths = @(),

    [Parameter()]
    [string[]]$DataDiskNames = @(),

    [Parameter()]
    [string]$IpAddress,

    [Parameter()]
    [switch]$RemoveSourceVM,

    [Parameter()]
    [switch]$SkipNicRemoval,

    [Parameter()]
    [switch]$SkipClusterCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\helpers\Common-Functions.ps1"
. "$ScriptDir\helpers\Test-HydrationPrerequisites.ps1"

if (-not $LocalVMName) { $LocalVMName = $VMName }

# Validate parallel arrays
if ($DataDiskLocalPaths.Count -ne $DataDiskNames.Count) {
    Write-Error "DataDiskLocalPaths ($($DataDiskLocalPaths.Count)) and DataDiskNames ($($DataDiskNames.Count)) must have the same number of entries."
    exit 1
}

#region ── Banner ─────────────────────────────────────────────────────────────

Write-HydrationBanner -Title 'Azure Local VM Reconnect' -Parameters ([ordered]@{
    'VM Name (Azure)'         = $VMName
    'VM Name (Hyper-V)'       = $LocalVMName
    'Resource Group'          = $ResourceGroup
    'Destination Custom Loc.' = $CustomLocation
    'New NIC Name'            = $NicName
    'Subnet / lnet'           = $SubnetId
    'Data Disks to Hydrate'   = if ($DataDiskLocalPaths.Count) { $DataDiskLocalPaths.Count } else { 'None' }
    'Remove Source VM'        = $RemoveSourceVM.IsPresent
    'Skip NIC Removal'        = $SkipNicRemoval.IsPresent
    'WhatIf'                  = $WhatIfPreference
})

Write-Host "  ⚠  IMPORTANT: If reconnect fails, do NOT delete the VM resource from Azure." -ForegroundColor Yellow
Write-Host "     Fix the root cause and re-run this script to repair it.`n" -ForegroundColor Yellow

#endregion

#region ── Pre-flight Validation ─────────────────────────────────────────────

Write-Step "Running pre-flight validation"

# Reconnect requires the VM to be Running
$failures = Test-HydrationPrerequisites -VMName $LocalVMName -RequireRunning -SkipClusterCheck:$SkipClusterCheck

# Azure login check
$accountInfo = & az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    $failures.Add("Not logged in to Azure CLI. Run 'az login' before executing this script.")
} else {
    $account = $accountInfo | ConvertFrom-Json
    Write-OK "Azure CLI authenticated (subscription: $($account.name))"
}

# Verify data disk paths exist on disk (only if not WhatIf)
if (-not $WhatIfPreference) {
    foreach ($path in $DataDiskLocalPaths) {
        if (-not (Test-Path $path)) {
            $failures.Add("Data disk path not found: '$path'. Ensure all VM files are restored under the cluster storage GUID folder.")
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n  Pre-flight failed with $($failures.Count) issue(s):`n" -ForegroundColor Red
    foreach ($f in $failures) { Write-Fail $f }
    Write-Host ""
    exit 1
}

Write-OK "All pre-flight checks passed"

#endregion

#region ── Step 2: Remove Network Interfaces (optional) ──────────────────────

if ($SkipNicRemoval) {
    Write-Step "Step 2/5 — Skipping NIC removal (-SkipNicRemoval specified)"
    Write-Info "You can add the new NIC as a second NIC after reconnect, then remove the original."
} else {
    Write-Step "Step 2/5 — Removing network interfaces from restored VM '$LocalVMName'"

    $nics = Get-VMNetworkAdapter -VMName $LocalVMName -ErrorAction SilentlyContinue
    if ($nics) {
        foreach ($nic in $nics) {
            Write-Info "Removing NIC: $($nic.Name)"
            if ($PSCmdlet.ShouldProcess("NIC '$($nic.Name)' on VM '$LocalVMName'", 'Remove')) {
                Remove-VMNetworkAdapter -VMNetworkAdapter $nic -ErrorAction Stop
                Write-OK "Removed NIC: $($nic.Name)"
            }
        }
    } else {
        Write-Info "No NICs found on VM '$LocalVMName' — nothing to remove."
    }
}

#endregion

#region ── Step 3: Hydrate Data Disks ────────────────────────────────────────

$hydatedDiskIds = @()

if ($DataDiskLocalPaths.Count -gt 0) {
    Write-Step "Step 3/5 — Hydrating $($DataDiskLocalPaths.Count) data disk(s)"

    for ($i = 0; $i -lt $DataDiskLocalPaths.Count; $i++) {
        $localPath = $DataDiskLocalPaths[$i]
        $diskName  = $DataDiskNames[$i]

        Write-Info "Hydrating: $localPath → '$diskName'"

        $ddArgs = @(
            'stack-hci-vm', 'disk', 'create-from-local',
            '--resource-group', $ResourceGroup,
            '--custom-location', $CustomLocation,
            '--name', $diskName,
            '--local-vhd-path', $localPath,
            '--output', 'json'
        )
        $ddResult = Invoke-AzCli -Arguments $ddArgs -StepName "az stack-hci-vm disk create-from-local ($diskName)"
        $hydatedDiskIds += $ddResult.id
        Write-OK "Hydrated: $($ddResult.id)"
    }
} else {
    Write-Step "Step 3/5 — No data disks to hydrate"
    Write-Info "No -DataDiskLocalPaths provided. Only the OS disk will be reconnected."
}

#endregion

#region ── Step 4: Reconnect the VM ──────────────────────────────────────────

Write-Step "Step 4/5 — Reconnecting VM '$VMName' to Azure"

$reconnectArgs = @(
    'stack-hci-vm', 'reconnect-to-azure',
    '--custom-location', $CustomLocation,
    '--local-vm-name', $LocalVMName,
    '--name', $VMName,
    '--resource-group', $ResourceGroup,
    '--output', 'json'
)

if ($hydatedDiskIds.Count -gt 0) {
    $reconnectArgs += @('--attach-data-disks', ($hydatedDiskIds -join ' '))
}

if ($RemoveSourceVM) {
    $reconnectArgs += '--yes'
    Write-Warn "RemoveSourceVM specified — VM will be removed from the source cluster upon successful reconnect."
}

$reconnectResult = Invoke-AzCli -Arguments $reconnectArgs -StepName 'az stack-hci-vm reconnect-to-azure'
Write-OK "VM reconnected: $($reconnectResult.id ?? $VMName)"

if ($RemoveSourceVM) {
    Write-Info "VM has been removed from the source cluster."
}

Write-Warn "The Arc agent (azcmagent) does not yet have internet access — the NIC is not configured. Proceeding to Step 5."

#endregion

#region ── Step 5: Create and Attach Network Interface ───────────────────────

Write-Step "Step 5/5 — Creating and attaching NIC '$NicName' on destination cluster"

$nicArgs = @(
    'stack-hci-vm', 'network', 'nic', 'create',
    '--resource-group', $ResourceGroup,
    '--custom-location', $CustomLocation,
    '--location', $Location,
    '--name', $NicName,
    '--subnet-id', $SubnetId,
    '--output', 'json'
)
if ($IpAddress) { $nicArgs += @('--ip-address', $IpAddress) }

$nicResult = Invoke-AzCli -Arguments $nicArgs -StepName 'az stack-hci-vm network nic create'
Write-OK "NIC created: $($nicResult.id)"

$attachArgs = @(
    'stack-hci-vm', 'nic', 'add',
    '--resource-group', $ResourceGroup,
    '--vm-name', $VMName,
    '--nics', $NicName,
    '--output', 'json'
)
Invoke-AzCli -Arguments $attachArgs -StepName 'az stack-hci-vm nic add' | Out-Null
Write-OK "NIC '$NicName' attached to VM '$VMName'"

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$border = '═' * 72
Write-Host "`n$border" -ForegroundColor Green
Write-Host "  VM Reconnect Complete" -ForegroundColor White
Write-Host $border -ForegroundColor Green
Write-Host ""
Write-Host "  VM '$VMName' is reconnected to Azure Local on the destination cluster." -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "  1. Confirm the VM appears in the Azure portal under the destination cluster."
Write-Host "  2. SDN-enabled clusters: the guest OS IP is configured automatically."
Write-Host "  3. Non-SDN clusters: manually configure the IP address inside the guest OS:"
Write-Host "       Connect via RDP or VM Connect, then run inside the guest:"
Write-Host "       New-NetIPAddress -InterfaceIndex <idx> -IPAddress <IP> -PrefixLength <len> -DefaultGateway <gw>"
Write-Host "       Set-DnsClientServerAddress -InterfaceIndex <idx> -ServerAddresses ('<dns>')"
Write-Host "  4. Once the Arc agent reconnects, verify Guest Management is active in the portal."
Write-Host ""
Write-Host "  ⚠  If something went wrong with the reconnect:" -ForegroundColor Yellow
Write-Host "     Do NOT delete the VM resource from Azure portal or CLI." -ForegroundColor Yellow
Write-Host "     Fix the root cause, then re-run this script to repair the resource." -ForegroundColor Yellow
Write-Host ""
if ($WhatIfPreference) {
    Write-Host "  NOTE: This was a WhatIf (dry run) — no resources were created or modified." -ForegroundColor Yellow
}
Write-Host "$border`n" -ForegroundColor Green

#endregion
