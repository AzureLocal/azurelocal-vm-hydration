<#
.SYNOPSIS
    Shared helpers for the hydration/reconnect integration test harness.
.NOTES
    Dot-sourced by all test runner scripts. Do not run directly.
#>

#region ── Test Output Helpers ────────────────────────────────────────────────

function Write-TestStep {
    param([string]$Message)
    Write-Host "`n[TEST] $Message" -ForegroundColor Magenta
}

function Write-TestPass {
    param([string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

function Write-TestFail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-TestWarn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-TestInfo {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-TestBanner {
    param([string]$Title)
    $border = '─' * 72
    Write-Host "`n$border" -ForegroundColor Magenta
    Write-Host "  TEST: $Title" -ForegroundColor White
    Write-Host "$border`n" -ForegroundColor Magenta
}

#endregion

#region ── Assertion Helpers ──────────────────────────────────────────────────

function Assert-Equal {
    param([string]$Label, $Expected, $Actual)
    if ($Actual -eq $Expected) {
        Write-TestPass "${Label}: '$Actual'"
        return $true
    }
    Write-TestFail "${Label}: expected '$Expected', got '$Actual'"
    return $false
}

function Assert-NotNull {
    param([string]$Label, $Value)
    if ($null -ne $Value -and $Value -ne '') {
        Write-TestPass "${Label} is present"
        return $true
    }
    Write-TestFail "${Label} is null or empty"
    return $false
}

function Assert-True {
    param([string]$Label, [bool]$Value)
    if ($Value) {
        Write-TestPass $Label
        return $true
    }
    Write-TestFail $Label
    return $false
}

#endregion

#region ── Azure Validation Helpers ───────────────────────────────────────────

function Get-AzureLocalVM {
    <#
    .SYNOPSIS
        Queries Azure for an Azure Local VM resource and returns it, or $null if not found.
    #>
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )
    $output = & az stack-hci-vm show --name $VMName --resource-group $ResourceGroup --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output | ConvertFrom-Json -ErrorAction SilentlyContinue
}

function Get-AzureLocalDisk {
    <#
    .SYNOPSIS
        Queries Azure for an Azure Local virtual hard disk resource.
    #>
    param(
        [Parameter(Mandatory)] [string]$DiskName,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )
    $output = & az stack-hci-vm disk show --name $DiskName --resource-group $ResourceGroup --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output | ConvertFrom-Json -ErrorAction SilentlyContinue
}

function Get-AzureLocalNic {
    <#
    .SYNOPSIS
        Queries Azure for an Azure Local network interface resource.
    #>
    param(
        [Parameter(Mandatory)] [string]$NicName,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )
    $output = & az stack-hci-vm network nic show --name $NicName --resource-group $ResourceGroup --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output | ConvertFrom-Json -ErrorAction SilentlyContinue
}

function Wait-ForAzureResource {
    <#
    .SYNOPSIS
        Polls an Azure Local VM until provisioningState is Succeeded (or fails/times out).
    .PARAMETER TimeoutSeconds
        How long to wait before giving up. Default: 300 seconds.
    .PARAMETER PollIntervalSeconds
        How often to poll. Default: 15 seconds.
    #>
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [int]$TimeoutSeconds = 300,
        [int]$PollIntervalSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-TestInfo "Waiting up to ${TimeoutSeconds}s for '$VMName' to reach Succeeded state..."

    while ((Get-Date) -lt $deadline) {
        $vm = Get-AzureLocalVM -VMName $VMName -ResourceGroup $ResourceGroup
        if ($vm) {
            $state = $vm.properties.provisioningState
            Write-TestInfo "  provisioningState: $state"
            if ($state -eq 'Succeeded') { return $true }
            if ($state -in @('Failed', 'Canceled')) {
                Write-TestFail "VM '$VMName' reached terminal state: $state"
                return $false
            }
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-TestFail "Timed out after ${TimeoutSeconds}s waiting for '$VMName'"
    return $false
}

#endregion

#region ── ISO Download and Conversion ───────────────────────────────────────

function Get-ConvertWindowsImageScript {
    <#
    .SYNOPSIS
        Ensures Convert-WindowsImage.ps1 is available locally, downloading it if needed.
    .DESCRIPTION
        Convert-WindowsImage.ps1 is a Microsoft tool (maintained in MSLab) that converts
        a Windows ISO to a bootable VHD/VHDX. This function caches it to avoid repeat downloads.
    .OUTPUTS
        [string] Path to Convert-WindowsImage.ps1, or $null on failure.
    #>
    param(
        [string]$LocalPath = "$env:TEMP\Convert-WindowsImage.ps1"
    )

    if (Test-Path $LocalPath) {
        Write-TestInfo "Convert-WindowsImage.ps1 cached at: $LocalPath"
        return $LocalPath
    }

    $url = 'https://raw.githubusercontent.com/microsoft/MSLab/master/Tools/Convert-WindowsImage.ps1'
    Write-TestInfo "Downloading Convert-WindowsImage.ps1 from MSLab..."
    try {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $LocalPath -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $prev
        Write-TestInfo "Downloaded to: $LocalPath"
        return $LocalPath
    } catch {
        $ProgressPreference = $prev
        Write-TestFail "Could not download Convert-WindowsImage.ps1: $_"
        Write-TestFail "Download manually from: $url"
        return $null
    }
}

function Convert-IsoToVhdx {
    <#
    .SYNOPSIS
        Converts a Windows Server ISO to a bootable VHDX using Convert-WindowsImage.ps1.
    .DESCRIPTION
        Gen2 output: GPT/UEFI partition scheme  — attach to Hyper-V Generation 2 VM.
        Gen1 output: MBR/BIOS partition scheme  — attach to Hyper-V Generation 1 VM.
        Both produce a Dynamic VHDX. Reuses an existing output file if already present.
    .OUTPUTS
        [string] Path to the created VHDX, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)] [string]$IsoPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [ValidateSet(1, 2)]    [int]$Generation    = 2,
        [string]$Edition   = 'Windows Server 2022 Datacenter',
        [int64]$SizeBytes   = 60GB,
        [string]$ConvertScriptPath
    )

    if (-not (Test-Path $IsoPath)) {
        Write-TestFail "ISO not found: $IsoPath"
        return $null
    }

    if (Test-Path $OutputPath) {
        $mb = [math]::Round((Get-Item $OutputPath).Length / 1MB)
        Write-TestInfo "VHDX already exists (${mb} MB) — reusing: $OutputPath"
        return $OutputPath
    }

    if (-not $ConvertScriptPath) {
        $ConvertScriptPath = Get-ConvertWindowsImageScript
    }
    if (-not $ConvertScriptPath) { return $null }

    Write-TestInfo "Converting ISO → VHDX (Generation $Generation, $([math]::Round($SizeBytes/1GB)) GB)"
    Write-TestInfo "  ISO     : $IsoPath"
    Write-TestInfo "  Output  : $OutputPath"
    Write-TestInfo "  Edition : $Edition"
    Write-TestWarn "This may take 5–15 minutes depending on disk speed."

    try {
        # Dot-source to bring Convert-WindowsImage into scope
        . $ConvertScriptPath

        $cwParams = @{
            SourcePath = $IsoPath
            VHDPath    = $OutputPath
            VHDFormat  = 'VHDX'
            Edition    = $Edition
            SizeBytes  = $SizeBytes
            VHDType    = 'Dynamic'
        }

        # Gen1 → MBR/BIOS partition scheme; Gen2 → GPT/UEFI (default)
        if ($Generation -eq 1) {
            $cwParams['BCDinVHD'] = 'NativeBoot'
        }

        Convert-WindowsImage @cwParams

        if (Test-Path $OutputPath) {
            $mb = [math]::Round((Get-Item $OutputPath).Length / 1MB)
            Write-TestInfo "VHDX created (${mb} MB): $OutputPath"
            return $OutputPath
        }

        Write-TestFail "Convert-WindowsImage completed but output file not found: $OutputPath"
        return $null
    } catch {
        Write-TestFail "ISO-to-VHDX conversion failed: $_"
        return $null
    }
}

function Invoke-EvalIsoDownload {
    <#
    .SYNOPSIS
        Downloads the Windows Server evaluation ISO from Microsoft.
    .DESCRIPTION
        Uses the Microsoft Evaluation Center redirect URL. The file is ~5 GB.
        If the ISO already exists at DestinationPath it is reused without re-downloading.

        Note: Microsoft periodically changes evaluation download URLs. If the default URL
        fails, visit https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
        to get a current direct-download link and pass it via -DownloadUrl.
    .OUTPUTS
        [string] Path to the downloaded ISO, or $null on failure.
    #>
    param(
        [string]$DestinationPath = "$env:TEMP\WS2022_eval.iso",
        # Default URL = Microsoft Eval Center redirect for WS2022 ISO (en-us, x64)
        [string]$DownloadUrl = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
    )

    if (Test-Path $DestinationPath) {
        $mb = [math]::Round((Get-Item $DestinationPath).Length / 1MB)
        Write-TestInfo "Eval ISO already present (${mb} MB) — reusing: $DestinationPath"
        return $DestinationPath
    }

    $dir = Split-Path $DestinationPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    Write-TestInfo "Downloading Windows Server 2022 Evaluation ISO (~5 GB)..."
    Write-TestInfo "URL         : $DownloadUrl"
    Write-TestInfo "Destination : $DestinationPath"
    Write-TestWarn "This download may take 10–30 minutes on a typical connection."

    try {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $prev

        $mb = [math]::Round((Get-Item $DestinationPath).Length / 1MB)
        Write-TestInfo "Download complete (${mb} MB): $DestinationPath"
        return $DestinationPath
    } catch {
        $ProgressPreference = $prev
        Write-TestFail "Eval ISO download failed: $_"
        Write-TestFail "Download manually from:"
        Write-TestFail "  https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022"
        Write-TestFail "Then pass the path with: -IsoPath '<path-to-iso>'"
        return $null
    }
}

#endregion

#region ── Gallery Image Resolution ──────────────────────────────────────────

function Get-GalleryImagePath {
    <#
    .SYNOPSIS
        Resolves the local VHDX path of an Azure Local gallery (marketplace) image.
    .DESCRIPTION
        Queries the gallery image resource for its storage container, then locates
        the VHDX file on the cluster storage volume. Falls back to a broad search
        of StorageRootPath if the container-based lookup does not find the file.
    .OUTPUTS
        [string] Absolute local path to the VHDX, or $null if not found.
    #>
    param(
        [Parameter(Mandatory)] [string]$ImageName,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [string]$StorageRootPath
    )

    Write-TestInfo "Resolving local path for gallery image '$ImageName'"

    $imageJson = & az stack-hci-vm image show `
        --name $ImageName `
        --resource-group $ResourceGroup `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-TestWarn "Gallery image '$ImageName' not found in resource group '$ResourceGroup'."
        Write-TestWarn "List available images:  az stack-hci-vm image list -g $ResourceGroup --output table"
        return $null
    }

    $image = $imageJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $image) {
        Write-TestWarn "Could not parse gallery image response."
        return $null
    }

    # Some custom/local images have imagePath set directly
    if ($image.properties.imagePath -and (Test-Path $image.properties.imagePath)) {
        Write-TestInfo "Resolved via imagePath: $($image.properties.imagePath)"
        return $image.properties.imagePath
    }

    # Marketplace images: resolve through the linked storage container's local path
    $containerId = $image.properties.containerId
    if ($containerId) {
        $containerJson = & az stack-hci-vm storagepath show --ids $containerId --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $container  = $containerJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            $localPath  = $container.properties.path
            if ($localPath -and (Test-Path $localPath)) {
                $vhdx = Get-ChildItem -Path $localPath -Filter '*.vhdx' -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.FullName     -match [regex]::Escape($ImageName) -or
                        $_.Directory.Name -match [regex]::Escape($ImageName)
                    } |
                    Select-Object -First 1
                if ($vhdx) {
                    Write-TestInfo "Resolved via storage container: $($vhdx.FullName)"
                    return $vhdx.FullName
                }
                Write-TestWarn "Storage container found at '$localPath' but no VHDX matched '$ImageName'."
                Write-TestWarn "Files found:"
                Get-ChildItem -Path $localPath -Filter '*.vhdx' -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 10 | ForEach-Object { Write-TestWarn "  $($_.FullName)" }
            }
        }
    }

    # Fallback: search entire storage root
    if ($StorageRootPath -and (Test-Path $StorageRootPath)) {
        Write-TestInfo "Falling back to broad search of '$StorageRootPath' for '$ImageName'..."
        $vhdx = Get-ChildItem -Path $StorageRootPath -Filter '*.vhdx' -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName       -match [regex]::Escape($ImageName) -or
                $_.Directory.Name -match [regex]::Escape($ImageName)
            } |
            Select-Object -First 1
        if ($vhdx) {
            Write-TestInfo "Resolved via storage root search: $($vhdx.FullName)"
            return $vhdx.FullName
        }
    }

    Write-TestWarn "Could not locate a local VHDX for gallery image '$ImageName'."
    Write-TestWarn "Specify the path directly:  -SourceVhdPath 'C:\ClusterStorage\...\image.vhdx'"
    return $null
}

#endregion

#region ── GUID Folder Helpers ────────────────────────────────────────────────

function Get-ClusterStorageGuidPath {
    <#
    .SYNOPSIS
        Returns the GUID folder path for a given Azure Local storage path (cluster volume root).
        Creates one if it does not exist.
    .PARAMETER StorageRootPath
        Root path of the cluster shared volume, e.g. C:\ClusterStorage\Volume1
    .PARAMETER VMName
        Used as the subfolder name under the GUID folder.
    #>
    param(
        [Parameter(Mandatory)] [string]$StorageRootPath,
        [Parameter(Mandatory)] [string]$VMName
    )

    # Look for an existing GUID folder (13+ hex chars)
    $guidFolder = Get-ChildItem -Path $StorageRootPath -Directory |
        Where-Object { $_.Name -match '^[0-9a-f]{13,}$' } |
        Select-Object -First 1

    if (-not $guidFolder) {
        # No GUID folder exists yet — this shouldn't happen on a configured cluster,
        # but create one for isolated test environments
        $guid = ([guid]::NewGuid().ToString('N')).Substring(0, 15)
        $guidFolder = New-Item -Path (Join-Path $StorageRootPath $guid) -ItemType Directory -Force
        Write-TestInfo "Created GUID folder: $($guidFolder.FullName)"
    } else {
        Write-TestInfo "Using existing GUID folder: $($guidFolder.FullName)"
    }

    $vmFolder = Join-Path $guidFolder.FullName $VMName
    if (-not (Test-Path $vmFolder)) {
        New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null
    }

    return $vmFolder
}

#endregion

#region ── Test Result Summary ────────────────────────────────────────────────

function Write-TestSummary {
    param(
        [string]$TestName,
        [int]$Passed,
        [int]$Failed,
        [string[]]$Failures = @()
    )
    $border = '═' * 72
    $total = $Passed + $Failed
    $color = if ($Failed -eq 0) { 'Green' } else { 'Red' }

    Write-Host "`n$border" -ForegroundColor $color
    Write-Host ("  {0}  —  {1}/{2} checks passed" -f $TestName, $Passed, $total) -ForegroundColor White
    Write-Host $border -ForegroundColor $color

    if ($Failures.Count -gt 0) {
        Write-Host ""
        foreach ($f in $Failures) { Write-Host "  ✗ $f" -ForegroundColor Red }
    }
    Write-Host ""

    return ($Failed -eq 0)
}

#endregion
