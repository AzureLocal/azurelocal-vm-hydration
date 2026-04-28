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
