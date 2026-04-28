#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Hydrates an unmanaged Hyper-V VM on an Azure Local cluster into Azure Local management.

.DESCRIPTION
    Takes an existing Hyper-V VM running on an Azure Local cluster that has never been registered
    with Azure, and brings it under Azure Local management as a
    Microsoft.AzureStackHCI/virtualMachineInstances resource — without re-imaging, Sysprepping,
    or disrupting the workload.

    The operation proceeds in the following order:
      1. Pre-flight validation (prerequisites, Azure login, resource group)
      2. VM inventory (collects OS disk + data disk paths from Hyper-V)
      3. Create Azure NIC resource
      4. Hydrate OS disk via az stack-hci-vm disk create-from-local (Gen2)
         or ARM REST API (Gen1, required because CLI lacks hyperVGeneration parameter)
      5. Hydrate any additional data disks
      6. Create Azure Local VM resource pointing at the hydrated disks
      7. Attach data disks
      8. Summary and next steps

    Primary reference: reference/AzureLocalVMReconnectPrivatePreview_02232026.md
    Community research: reference/hybridcore-vm-adoption-research.md

.PARAMETER VMName
    Name of the VM in Hyper-V Manager on this cluster node.

.PARAMETER ResourceGroup
    Azure resource group to create the VM and disk resources in.

.PARAMETER CustomLocation
    Full ARM URI of the custom location for this Azure Local cluster.
    Example: /subscriptions/<sub>/resourcegroups/<rg>/providers/microsoft.extendedlocation/customlocations/<name>

.PARAMETER StoragePathId
    ARM resource ID of the Azure Local storage path to associate with the VM.
    Example: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/storageContainers/<name>

.PARAMETER NicName
    Name for the new Azure NIC resource that will be created and attached to the VM.

.PARAMETER SubnetId
    Name or ARM resource ID of the logical network (lnet) for the NIC.

.PARAMETER Location
    Azure region (e.g. 'eastus').

.PARAMETER AzureVMName
    Name for the VM resource in Azure. Defaults to VMName if not specified.

.PARAMETER IpAddress
    Static IP address for the NIC. Omit to use DHCP.

.PARAMETER OsType
    Guest OS type. 'windows' or 'linux'. Default: 'windows'.

.PARAMETER HyperVGeneration
    Hyper-V generation of the VM. 'V1' or 'V2'. Default: 'V2'.
    Gen1 uses ARM REST API for disk creation and disables vTPM/Secure Boot.

.PARAMETER SkipClusterCheck
    Skip the HA/Failover Cluster check. Use only in non-clustered test environments.

.EXAMPLE
    .\Invoke-VMHydration.ps1 `
        -VMName 'WEBSRV01' `
        -ResourceGroup 'rg-azlocal-prod' `
        -CustomLocation '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-azlocal-prod/providers/microsoft.extendedlocation/customlocations/cl-eastus-01' `
        -StoragePathId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-azlocal-prod/providers/Microsoft.AzureStackHCI/storageContainers/UserStorage1' `
        -NicName 'WEBSRV01-nic1' `
        -SubnetId 'lnet-prod-vlan10' `
        -Location 'eastus'

.EXAMPLE
    .\Invoke-VMHydration.ps1 -VMName 'LEGACYAPP' -HyperVGeneration V1 `
        -ResourceGroup 'rg-azlocal-prod' -CustomLocation '...' -StoragePathId '...' `
        -NicName 'LEGACYAPP-nic1' -SubnetId 'lnet-prod-vlan10' -Location 'eastus' -WhatIf

.NOTES
    Run on one of the Azure Local cluster nodes directly, or connect remotely via PowerShell.
    Azure CLI must be authenticated before running (az login).
    stack-hci-vm extension >= 1.11.9 required.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$CustomLocation,

    [Parameter(Mandatory)]
    [string]$StoragePathId,

    [Parameter(Mandatory)]
    [string]$NicName,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [string]$AzureVMName,

    [Parameter()]
    [string]$IpAddress,

    [Parameter()]
    [ValidateSet('windows', 'linux')]
    [string]$OsType = 'windows',

    [Parameter()]
    [ValidateSet('V1', 'V2')]
    [string]$HyperVGeneration = 'V2',

    [Parameter()]
    [switch]$SkipClusterCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\helpers\Common-Functions.ps1"
. "$ScriptDir\helpers\Test-HydrationPrerequisites.ps1"

if (-not $AzureVMName) { $AzureVMName = $VMName }

#region ── Banner ─────────────────────────────────────────────────────────────

Write-HydrationBanner -Title 'Azure Local VM Hydration' -Parameters ([ordered]@{
    'VM (Hyper-V)'       = $VMName
    'VM (Azure)'         = $AzureVMName
    'Resource Group'     = $ResourceGroup
    'Location'           = $Location
    'Hyper-V Generation' = $HyperVGeneration
    'OS Type'            = $OsType
    'NIC Name'           = $NicName
    'Subnet / lnet'      = $SubnetId
    'WhatIf'             = $WhatIfPreference
})

#endregion

#region ── Pre-flight Validation ─────────────────────────────────────────────���

Write-Step "Running pre-flight validation"

$failures = Test-HydrationPrerequisites -VMName $VMName -SkipClusterCheck:$SkipClusterCheck

# Azure login check
$accountInfo = & az account show --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    $failures.Add("Not logged in to Azure CLI. Run 'az login' before executing this script.")
} else {
    $account = $accountInfo | ConvertFrom-Json
    Write-OK "Azure CLI authenticated (subscription: $($account.name))"
}

# Resource group exists
if ($failures.Count -eq 0) {
    $rgCheck = & az group show --name $ResourceGroup --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("Resource group '$ResourceGroup' not found. Create it or check the name.")
    } else {
        Write-OK "Resource group '$ResourceGroup' exists"
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

#region ── Collect VM Info from Hyper-V ──────────────────────────────────────

Write-Step "Collecting VM disk inventory from Hyper-V"

$vm       = Get-VM -Name $VMName -ErrorAction Stop
$allDisks = Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop | Sort-Object ControllerType, ControllerNumber, ControllerLocation

if (-not $allDisks) {
    Write-Fail "No hard disks found on VM '$VMName'."
    exit 1
}

# First disk = OS disk; remaining = data disks
$osDisk    = $allDisks[0]
$dataDisks = @($allDisks | Select-Object -Skip 1)

Write-OK "OS disk  : $($osDisk.Path)"
foreach ($d in $dataDisks) {
    Write-OK "Data disk: $($d.Path)"
}

#endregion

#region ── Step 1: Create Azure NIC ──────────────────────────────────────────

Write-Step "Step 1/5 — Creating Azure NIC '$NicName'"

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

#endregion

#region ── Step 2: Hydrate OS Disk ───────────────────────────────────────────

Write-Step "Step 2/5 — Hydrating OS disk ($HyperVGeneration)"

$osDiskName = "$AzureVMName-osdisk"

if ($HyperVGeneration -eq 'V2') {
    $osDiskArgs = @(
        'stack-hci-vm', 'disk', 'create-from-local',
        '--resource-group', $ResourceGroup,
        '--custom-location', $CustomLocation,
        '--name', $osDiskName,
        '--local-vhd-path', $osDisk.Path,
        '--output', 'json'
    )
    $osDiskResult = Invoke-AzCli -Arguments $osDiskArgs -StepName 'az stack-hci-vm disk create-from-local (OS)'
} else {
    # Gen1: CLI lacks --hyper-v-generation; use ARM REST API directly
    # Determine disk file format from extension
    $diskFormat = if ($osDisk.Path -match '\.vhd$') { 'vhd' } else { 'vhdx' }

    # Resolve storage container ID from StoragePathId
    $containerUri = "https://management.azure.com${StoragePathId}?api-version=2023-09-01-preview"
    $spInfo = Invoke-ArmRestApi -Method GET -Uri $containerUri -StepName 'Get storage path info'

    $diskUri = "https://management.azure.com/subscriptions/$(
        ($StoragePathId -split '/')[2]
    )/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/virtualHardDisks/${osDiskName}?api-version=2023-09-01-preview"

    $diskBody = @{
        location         = $Location
        extendedLocation = @{ name = $CustomLocation; type = 'CustomLocation' }
        properties       = @{
            hyperVGeneration = 'V1'
            diskFileFormat   = $diskFormat
            dynamic          = $true
            diskSizeGB       = [math]::Ceiling((Get-Item $osDisk.Path).Length / 1GB)
            containerId      = $spInfo.id
        }
    }
    $osDiskResult = Invoke-ArmRestApi -Method PUT -Uri $diskUri -Body $diskBody -StepName 'ARM: Create Gen1 OS disk'
}

Write-OK "OS disk hydrated: $($osDiskResult.id ?? $osDiskResult.name ?? $osDiskName)"

#endregion

#region ── Step 3: Hydrate Data Disks ────────────────────────────────────────

$dataDiskIds = @()

if ($dataDisks.Count -gt 0) {
    Write-Step "Step 3/5 — Hydrating $($dataDisks.Count) data disk(s)"

    for ($i = 0; $i -lt $dataDisks.Count; $i++) {
        $dd     = $dataDisks[$i]
        $ddName = "$AzureVMName-datadisk$($i + 1)"

        Write-Info "Hydrating data disk $($i + 1)/$($dataDisks.Count): $($dd.Path)"

        $ddArgs = @(
            'stack-hci-vm', 'disk', 'create-from-local',
            '--resource-group', $ResourceGroup,
            '--custom-location', $CustomLocation,
            '--name', $ddName,
            '--local-vhd-path', $dd.Path,
            '--output', 'json'
        )
        $ddResult = Invoke-AzCli -Arguments $ddArgs -StepName "az stack-hci-vm disk create-from-local (data disk $($i+1))"
        $dataDiskIds += $ddResult.id
        Write-OK "Data disk $($i + 1) hydrated: $($ddResult.id)"
    }
} else {
    Write-Step "Step 3/5 — No data disks to hydrate"
    Write-Info "VM has only an OS disk."
}

#endregion

#region ── Step 4: Create Azure Local VM ──────────────────────────────────────

Write-Step "Step 4/5 — Creating Azure Local VM '$AzureVMName'"

$vmArgs = @(
    'stack-hci-vm', 'create',
    '--resource-group', $ResourceGroup,
    '--custom-location', $CustomLocation,
    '--location', $Location,
    '--name', $AzureVMName,
    '--os-disk-name', $osDiskName,
    '--os-type', $OsType,
    '--nics', $NicName,
    '--storage-path-id', $StoragePathId,
    '--enable-agent', 'false',
    '--enable-vm-config-agent', 'false',
    '--output', 'json'
)

if ($HyperVGeneration -eq 'V2') {
    $vmArgs += @('--enable-vtpm', 'true', '--enable-secure-boot', 'true')
} else {
    $vmArgs += @('--enable-vtpm', 'false', '--enable-secure-boot', 'false')
}

$vmResult = Invoke-AzCli -Arguments $vmArgs -StepName 'az stack-hci-vm create'
Write-OK "VM resource created: $($vmResult.id ?? $AzureVMName)"

#endregion

#region ── Step 5: Attach Data Disks ──────────────────────────────────────────

if ($dataDiskIds.Count -gt 0) {
    Write-Step "Step 5/5 — Attaching $($dataDiskIds.Count) data disk(s)"

    foreach ($diskId in $dataDiskIds) {
        $attachArgs = @(
            'stack-hci-vm', 'disk', 'attach',
            '--resource-group', $ResourceGroup,
            '--vm-name', $AzureVMName,
            '--disk', $diskId,
            '--output', 'json'
        )
        Invoke-AzCli -Arguments $attachArgs -StepName 'az stack-hci-vm disk attach' | Out-Null
        Write-OK "Attached: $diskId"
    }
} else {
    Write-Step "Step 5/5 — No data disks to attach"
}

#endregion

#region ── Summary ────────────────────────────────────────────────────────────

$border = '═' * 72
Write-Host "`n$border" -ForegroundColor Green
Write-Host "  VM Hydration Complete" -ForegroundColor White
Write-Host $border -ForegroundColor Green
Write-Host ""
Write-Host "  VM '$AzureVMName' is now managed by Azure Local." -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "  1. In the Azure portal, confirm the VM appears under your Azure Local cluster."
Write-Host "  2. Wait for the VM to reach Running state."
Write-Host "  3. Enable Guest Management to install the Arc for Servers agent inside the guest."
Write-Host "     This enables Azure extensions, policy, and patch management."
Write-Host "  4. If SDN is not enabled on the cluster, manually configure the NIC IP address"
Write-Host "     inside the guest OS (RDP or VM Connect)."
Write-Host ""
if ($WhatIfPreference) {
    Write-Host "  NOTE: This was a WhatIf (dry run) — no resources were created." -ForegroundColor Yellow
}
Write-Host "$border`n" -ForegroundColor Green

#endregion
