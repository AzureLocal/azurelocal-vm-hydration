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

.PARAMETER GalleryImageName
    Name of an Azure Local gallery (marketplace) image already downloaded to this cluster.
    Resolves to the local VHDX automatically — recommended for realistic full-OS testing.
    List available images: az stack-hci-vm image list -g <rg> --output table

.PARAMETER SourceVhdPath
    Explicit local path to a VHDX/VHD to copy into the test VM folder.
    Use when -GalleryImageName resolution fails or you have a custom template.

.PARAMETER IsoPath
    Path to a Windows Server ISO on the cluster node. The script converts it to a
    bootable VHDX using Convert-WindowsImage.ps1 (downloaded automatically from MSLab).
    Use with -Generation to produce Gen1 (MBR/BIOS) or Gen2 (GPT/UEFI) output.

.PARAMETER DownloadEvalIso
    Download the Windows Server 2022 Evaluation ISO from Microsoft automatically,
    then convert it to VHDX. Requires ~5 GB download + conversion time.
    Override the download URL with -EvalIsoUrl if the default link has changed.

.PARAMETER EvalIsoUrl
    Override the default Microsoft evaluation ISO download URL.
    Visit https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
    to get a current direct-download link if the default has expired.

.PARAMETER IsoEdition
    Windows Server edition to install when converting from ISO.
    Default: 'Windows Server 2022 Datacenter'
    Common values:
      'Windows Server 2022 Standard'
      'Windows Server 2022 Standard (Desktop Experience)'
      'Windows Server 2022 Datacenter'
      'Windows Server 2022 Datacenter (Desktop Experience)'

.PARAMETER SkipSetup
    Skip the New-HydrationTestVM step. Use when the VM already exists.

.EXAMPLE
    # Azure resource layer test only (empty VHD, no OS needed):
    .\Invoke-HydrationTest.ps1 -ResourceGroup 'rg-test' -CustomLocation '...' `
        -StoragePathId '...' -StorageRootPath 'C:\ClusterStorage\csv-01' `
        -SubnetId 'lnet-test' -Location 'eastus'

.EXAMPLE
    # Use a marketplace image already on the cluster (recommended):
    .\Invoke-HydrationTest.ps1 ... -GalleryImageName 'windows-server-2022-datacenter'

.EXAMPLE
    # Use an ISO already on cluster storage:
    .\Invoke-HydrationTest.ps1 ... -IsoPath 'C:\ClusterStorage\csv-01\ISOs\WS2022.iso'

.EXAMPLE
    # Download eval ISO automatically and convert (Gen2):
    .\Invoke-HydrationTest.ps1 ... -DownloadEvalIso

.EXAMPLE
    # Download eval ISO and test Gen1 hydration path:
    .\Invoke-HydrationTest.ps1 ... -DownloadEvalIso -Generation 1

.NOTES
    Run on one of the Azure Local cluster nodes as Administrator.
    Azure CLI must be authenticated (az login).
    VHD source priority: GalleryImageName > IsoPath/DownloadEvalIso > SourceVhdPath > empty VHD.
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
    [string]$GalleryImageName,

    [Parameter()]
    [string]$SourceVhdPath,

    [Parameter()]
    [string]$IsoPath,

    [Parameter()]
    [switch]$DownloadEvalIso,

    [Parameter()]
    [string]$EvalIsoUrl,

    [Parameter()]
    [string]$IsoEdition = 'Windows Server 2022 Datacenter',

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

#region ── Resolve VHD Source ─────────────────────────────────────────────────
# Priority: GalleryImageName > IsoPath/DownloadEvalIso > SourceVhdPath > empty VHD

if (-not $SkipSetup) {

    if ($GalleryImageName) {
        # ── Option 1: Marketplace / gallery image already on the cluster
        $resolvedPath = Get-GalleryImagePath `
            -ImageName       $GalleryImageName `
            -ResourceGroup   $ResourceGroup `
            -StorageRootPath $StorageRootPath
        if ($resolvedPath) {
            $SourceVhdPath = $resolvedPath
            Write-Host "  [VHD] Gallery image : $GalleryImageName" -ForegroundColor Cyan
            Write-Host "        Local path    : $SourceVhdPath"    -ForegroundColor Cyan
        } else {
            Write-Host "  [WARN] Gallery image '$GalleryImageName' not resolved — check next option or use -SourceVhdPath." -ForegroundColor Yellow
        }
    }

    if (-not $SourceVhdPath -and ($IsoPath -or $DownloadEvalIso)) {
        # ── Option 2: ISO → convert to VHDX
        $iso = $IsoPath

        if ($DownloadEvalIso -and -not $iso) {
            $isoFile      = Join-Path $env:TEMP 'WS2022_eval.iso'
            $dlParams     = @{ DestinationPath = $isoFile }
            if ($EvalIsoUrl) { $dlParams['DownloadUrl'] = $EvalIsoUrl }
            $iso = Invoke-EvalIsoDownload @dlParams
        }

        if ($iso) {
            $genTag  = "gen$Generation"
            $vhdxOut = Join-Path $env:TEMP "ws2022-test-${genTag}.vhdx"
            $cvParams = @{
                IsoPath    = $iso
                OutputPath = $vhdxOut
                Generation = $Generation
                Edition    = $IsoEdition
            }
            $converted = Convert-IsoToVhdx @cvParams
            if ($converted) {
                $SourceVhdPath = $converted
                Write-Host "  [VHD] Converted ISO : Gen$Generation VHDX" -ForegroundColor Cyan
                Write-Host "        Path          : $SourceVhdPath"       -ForegroundColor Cyan
            } else {
                Write-Host "  [WARN] ISO conversion failed — falling back to empty VHD." -ForegroundColor Yellow
            }
        }
    }

    if ($SourceVhdPath) {
        # ── Option 3: Explicit path already set (from above or passed directly)
        Write-Host "  [VHD] Source VHDX   : $SourceVhdPath" -ForegroundColor Cyan
    } else {
        # ── Option 4: Empty VHD — Azure resource layer testing only
        Write-Host "  [VHD] Mode: empty VHD (no OS) — Azure resource registration only." -ForegroundColor Yellow
        Write-Host "        Supply -GalleryImageName, -IsoPath, -DownloadEvalIso, or -SourceVhdPath for full OS testing." -ForegroundColor Yellow
    }
}

#endregion

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
