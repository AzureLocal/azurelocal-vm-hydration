<#
.SYNOPSIS
    Shared helper functions for AzureLocalVMHydration module.
.NOTES
    Loaded automatically by AzureLocalVMHydration.psm1. Do not dot-source directly.
#>

#region ── Console Output Helpers ─────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n[*] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [INFO] $Message" -ForegroundColor Gray
}

#endregion

#region ── Banner ─────────────────────────────────────────────────────────────

function Write-HydrationBanner {
    param(
        [string]$Title,
        [hashtable]$Parameters
    )
    $width  = 72
    $border = '═' * $width
    Write-Host "`n$border" -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Title) -ForegroundColor White
    Write-Host $border -ForegroundColor Cyan
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            if ($null -ne $Parameters[$key] -and $Parameters[$key] -ne '') {
                Write-Host ("  {0,-30} {1}" -f "$key :", $Parameters[$key]) -ForegroundColor Gray
            }
        }
    }
    Write-Host "$border`n" -ForegroundColor Cyan
}

#endregion

#region ── Admin Elevation Check ──────────────────────────────────────────────

function Assert-AdminElevation {
    param([string]$FunctionName)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        throw "$FunctionName requires elevation. Run PowerShell as Administrator."
    }
}

#endregion

#region ── Azure CLI Wrapper ──────────────────────────────────────────────────

function Invoke-AzCli {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [string]$StepName = 'az command',
        [switch]$AllowEmpty
    )

    $cmdDisplay = "az $($Arguments -join ' ')"

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] $cmdDisplay" -ForegroundColor DarkGray
        return $null
    }

    Write-Info $cmdDisplay

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$StepName failed (exit $LASTEXITCODE)."
        Write-Fail ($output | Out-String).Trim()
        throw "$StepName failed."
    }

    if (-not $output -and -not $AllowEmpty) { return $null }

    $json = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    return $json ?? $output
}

#endregion

#region ── ARM REST API Wrapper ───────────────────────────────────────────────

function Invoke-ArmRestApi {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory)]
        [string]$Uri,
        [object]$Body,
        [string]$StepName = 'ARM REST call'
    )

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] az rest --method $Method --uri <$Uri>" -ForegroundColor DarkGray
        return $null
    }

    $azArgs = @('rest', '--method', $Method, '--uri', $Uri, '--output', 'json')
    if ($Body) { $azArgs += @('--body', ($Body | ConvertTo-Json -Depth 10 -Compress)) }

    Write-Info "az rest --method $Method --uri $Uri"

    $output = & az @azArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$StepName failed (exit $LASTEXITCODE)."
        Write-Fail ($output | Out-String).Trim()
        throw "$StepName failed."
    }

    return $output | ConvertFrom-Json -ErrorAction SilentlyContinue
}

#endregion

#region ── Azure CLI Extension Check ──────────────────────────────────────────

function Test-AzCliExtensionVersion {
    param([string]$MinVersion = '1.11.9')

    $output = & az extension show --name stack-hci-vm --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    $ext = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $ext) { return $false }

    return ([Version]$ext.version) -ge ([Version]$MinVersion)
}

#endregion

#region ── GUID Folder Validation ─────────────────────────────────────────────

function Test-GuidFolderPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    return $Path -match '\\[0-9a-f]{13,}\\'
}

#endregion
