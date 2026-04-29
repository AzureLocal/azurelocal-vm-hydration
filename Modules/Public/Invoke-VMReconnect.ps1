function Invoke-VMReconnect {
    <#
    .SYNOPSIS
        Reconnects an Azure Local VM to its Azure resource after restore to a different cluster.

    .DESCRIPTION
        Implements the Microsoft Private Preview VM Reconnection procedure for Azure Local.
        Use when a VM has been restored (via Veeam, export/import, or other backup tool)
        to a different Azure Local cluster and its Azure resource is now orphaned or disconnected.

        Follows the 5-step Microsoft Private Preview procedure:
          Step 1  Pre-flight validation
          Step 2  Remove NICs from the restored VM (optional)
          Step 3  Hydrate data disks via az stack-hci-vm disk create-from-local
          Step 4  Reconnect the VM via az stack-hci-vm reconnect-to-azure
          Step 5  Create and attach a new NIC on the destination cluster

    .PARAMETER VMName
        The VM name as it exists in Azure (the original Azure resource name).

    .PARAMETER LocalVMName
        The VM name in Hyper-V Manager on the restored (destination) cluster.
        Defaults to VMName if not specified.

    .PARAMETER ResourceGroup
        The original Azure resource group the VM was created in.

    .PARAMETER CustomLocation
        Full ARM URI of the custom location for the DESTINATION Azure Local cluster.

    .PARAMETER NicName
        Name for the new Azure NIC resource on the destination cluster.

    .PARAMETER SubnetId
        Name or ARM resource ID of the logical network (lnet) on the destination cluster.

    .PARAMETER Location
        Azure region (e.g. 'eastus').

    .PARAMETER DataDiskLocalPaths
        Array of local file paths for data disks to hydrate before reconnecting.

    .PARAMETER DataDiskNames
        Parallel array of Azure resource names for the hydrated data disks.

    .PARAMETER IpAddress
        Static IP for the new NIC. Omit to use DHCP.

    .PARAMETER RemoveSourceVM
        Passes --yes to az stack-hci-vm reconnect-to-azure, removing the VM from the
        source cluster on success. Not reversible — use with care.

    .PARAMETER SkipNicRemoval
        Skip Step 2 (removing old NICs). Use if NICs were already removed manually.

    .PARAMETER SkipClusterCheck
        Skip the HA/Failover Cluster check for non-clustered test environments.

    .EXAMPLE
        Invoke-VMReconnect `
            -VMName 'APPSRV01' `
            -LocalVMName 'APPSRV01_restored' `
            -ResourceGroup 'rg-azlocal-prod' `
            -CustomLocation '/subscriptions/.../customlocations/cl-eastus-02' `
            -NicName 'APPSRV01-nic2' `
            -SubnetId 'lnet-prod-vlan10' `
            -Location 'eastus' `
            -RemoveSourceVM

    .NOTES
        Must be run as Administrator on one of the DESTINATION Azure Local cluster nodes.
        Azure CLI must be authenticated (az login).
        stack-hci-vm extension >= 1.11.9 required.
        Cluster must be running Azure Local 2602 or above.

        IMPORTANT: If reconnect fails, do NOT delete the VM resource from Azure.
        Fix the root cause and re-run this command to repair the resource.

        Install from PSGallery:
            Install-Module AzureLocalVMHydration -Scope CurrentUser
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

    Assert-AdminElevation -FunctionName 'Invoke-VMReconnect'

    if (-not $LocalVMName) { $LocalVMName = $VMName }

    if ($DataDiskLocalPaths.Count -ne $DataDiskNames.Count) {
        throw "DataDiskLocalPaths ($($DataDiskLocalPaths.Count)) and DataDiskNames ($($DataDiskNames.Count)) must have the same number of entries."
    }

    #region ── Banner ─────────────────────────────────────────────────────────

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
    Write-Host "     Fix the root cause and re-run this command to repair it.`n" -ForegroundColor Yellow

    #endregion

    #region ── Pre-flight Validation ──────────────────────────────────────────

    Write-Step "Running pre-flight validation"

    $failures = Test-HydrationPrerequisites -VMName $LocalVMName -RequireRunning -SkipClusterCheck:$SkipClusterCheck

    $accountInfo = & az account show --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("Not logged in to Azure CLI. Run 'az login' before executing this command.")
    } else {
        $account = $accountInfo | ConvertFrom-Json
        Write-OK "Azure CLI authenticated (subscription: $($account.name))"
    }

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
        throw "Pre-flight validation failed. Correct the issues above and retry."
    }

    Write-OK "All pre-flight checks passed"

    #endregion

    #region ── Step 2: Remove NICs ────────────────────────────────────────────

    if ($SkipNicRemoval) {
        Write-Step "Step 2/5 — Skipping NIC removal (-SkipNicRemoval specified)"
    } else {
        Write-Step "Step 2/5 — Removing NICs from restored VM '$LocalVMName'"

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
            Write-Info "No NICs found on VM '$LocalVMName'."
        }
    }

    #endregion

    #region ── Step 3: Hydrate Data Disks ─────────────────────────────────────

    $hydratedDiskIds = @()

    if ($DataDiskLocalPaths.Count -gt 0) {
        Write-Step "Step 3/5 — Hydrating $($DataDiskLocalPaths.Count) data disk(s)"

        for ($i = 0; $i -lt $DataDiskLocalPaths.Count; $i++) {
            Write-Info "Hydrating: $($DataDiskLocalPaths[$i]) → '$($DataDiskNames[$i])'"

            $ddArgs = @(
                'stack-hci-vm', 'disk', 'create-from-local',
                '--resource-group', $ResourceGroup,
                '--custom-location', $CustomLocation,
                '--name', $DataDiskNames[$i],
                '--local-vhd-path', $DataDiskLocalPaths[$i],
                '--output', 'json'
            )
            $ddResult        = Invoke-AzCli -Arguments $ddArgs -StepName "az stack-hci-vm disk create-from-local ($($DataDiskNames[$i]))"
            $hydratedDiskIds += $ddResult.id
            Write-OK "Hydrated: $($ddResult.id)"
        }
    } else {
        Write-Step "Step 3/5 — No data disks to hydrate"
    }

    #endregion

    #region ── Step 4: Reconnect VM ───────────────────────────────────────────

    Write-Step "Step 4/5 — Reconnecting VM '$VMName' to Azure"

    $reconnectArgs = @(
        'stack-hci-vm', 'reconnect-to-azure',
        '--custom-location', $CustomLocation,
        '--local-vm-name', $LocalVMName,
        '--name', $VMName,
        '--resource-group', $ResourceGroup,
        '--output', 'json'
    )

    if ($hydratedDiskIds.Count -gt 0) {
        $reconnectArgs += @('--attach-data-disks', ($hydratedDiskIds -join ' '))
    }

    if ($RemoveSourceVM) {
        $reconnectArgs += '--yes'
        Write-Warn "RemoveSourceVM specified — VM will be removed from the source cluster on success."
    }

    $reconnectResult = Invoke-AzCli -Arguments $reconnectArgs -StepName 'az stack-hci-vm reconnect-to-azure'
    Write-OK "VM reconnected: $($reconnectResult.id ?? $VMName)"

    Write-Warn "Arc agent does not yet have internet access — NIC not configured. Proceeding to Step 5."

    #endregion

    #region ── Step 5: Create and Attach NIC ──────────────────────────────────

    Write-Step "Step 5/5 — Creating and attaching NIC '$NicName'"

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

    #region ── Summary ────────────────────────────────────────────────────────

    $border = '═' * 72
    Write-Host "`n$border" -ForegroundColor Green
    Write-Host "  VM Reconnect Complete" -ForegroundColor White
    Write-Host $border -ForegroundColor Green
    Write-Host ""
    Write-Host "  VM '$VMName' is reconnected to Azure Local on the destination cluster." -ForegroundColor White
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Confirm the VM appears in the Azure portal under the destination cluster."
    Write-Host "  2. SDN clusters: guest OS IP is configured automatically."
    Write-Host "  3. Non-SDN clusters: manually configure IP inside the guest OS:"
    Write-Host "       New-NetIPAddress -InterfaceIndex <idx> -IPAddress <IP> -PrefixLength <len> -DefaultGateway <gw>"
    Write-Host "       Set-DnsClientServerAddress -InterfaceIndex <idx> -ServerAddresses ('<dns>')"
    Write-Host "  4. Verify Guest Management is active in the Azure portal."
    Write-Host ""
    Write-Host "  ⚠  If something went wrong:" -ForegroundColor Yellow
    Write-Host "     Do NOT delete the VM resource from Azure portal or CLI." -ForegroundColor Yellow
    Write-Host "     Fix the root cause, then re-run Invoke-VMReconnect to repair it." -ForegroundColor Yellow
    Write-Host ""
    if ($WhatIfPreference) {
        Write-Host "  NOTE: This was a WhatIf (dry run) — no resources were created or modified." -ForegroundColor Yellow
    }
    Write-Host "$border`n" -ForegroundColor Green

    #endregion
}
