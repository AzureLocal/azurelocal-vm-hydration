<#
.SYNOPSIS
    Shared helper functions for Azure Local VM hydration and reconnect scripts.
.NOTES
    Dot-source this file at the top of Invoke-VMHydration.ps1 and Invoke-VMReconnect.ps1.
    Do not run this file directly.
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
    $width = 72
    $border = '═' * $width
    Write-Host "`n$border" -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Title) -ForegroundColor White
    Write-Host $border -ForegroundColor Cyan
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            if ($Parameters[$key]) {
                Write-Host ("  {0,-30} {1}" -f "$key :", $Parameters[$key]) -ForegroundColor Gray
            }
        }
    }
    Write-Host "$border`n" -ForegroundColor Cyan
}

#endregion

#region ── Azure CLI Wrapper ──────────────────────────────────────────────────

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Wraps az CLI calls with error handling, WhatIf support, and JSON parsing.
    .PARAMETER Arguments
        Array of arguments to pass to az (e.g. @('stack-hci-vm','disk','create-from-local',...))
    .PARAMETER StepName
        Human-readable name used in error messages.
    .PARAMETER AllowEmpty
        If set, an empty result is not treated as an error.
    #>
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

    if (-not $output -and -not $AllowEmpty) {
        return $null
    }

    $json = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    return $json ?? $output
}

#endregion

#region ── ARM REST API Wrapper ───────────────────────────────────────────────

function Invoke-ArmRestApi {
    <#
    .SYNOPSIS
        Calls the Azure ARM REST API via 'az rest'. Used for operations the CLI
        doesn't expose directly (e.g. Gen1 disk creation with hyperVGeneration).
    .PARAMETER Method
        HTTP method: GET, PUT, POST, PATCH, DELETE
    .PARAMETER Uri
        Full ARM URI including api-version query parameter.
    .PARAMETER Body
        Hashtable or PSCustomObject to send as JSON body.
    .PARAMETER StepName
        Human-readable name for error messages.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET','PUT','POST','PATCH','DELETE')]
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

    $args = @('rest', '--method', $Method, '--uri', $Uri, '--output', 'json')

    if ($Body) {
        $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress
        $args += @('--body', $bodyJson)
    }

    Write-Info "az rest --method $Method --uri $Uri"

    $output = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$StepName failed (exit $LASTEXITCODE)."
        Write-Fail ($output | Out-String).Trim()
        throw "$StepName failed."
    }

    return $output | ConvertFrom-Json -ErrorAction SilentlyContinue
}

#endregion

#region ── Azure CLI Extension Check ─────────────────────────────────────────

function Test-AzCliExtensionVersion {
    <#
    .SYNOPSIS
        Verifies the stack-hci-vm CLI extension is installed at a minimum version.
    .PARAMETER MinVersion
        Minimum required version string (e.g. '1.11.9').
    .OUTPUTS
        Returns $true if requirement met, $false otherwise.
    #>
    param(
        [string]$MinVersion = '1.11.9'
    )

    $output = & az extension show --name stack-hci-vm --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $ext = $output | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $ext) { return $false }

    $installed = [Version]$ext.version
    $required  = [Version]$MinVersion

    return $installed -ge $required
}

#endregion

#region ── GUID Folder Validation ─────────────────────────────────────────────

function Test-GuidFolderPath {
    <#
    .SYNOPSIS
        Returns $true if the given path contains a GUID-style folder segment
        (13+ hex characters), as required by Arc Resource Bridge storage layout.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    # GUID folders are 13+ lowercase hex characters (e.g. e21794969177373)
    return $Path -match '\\[0-9a-f]{13,}\\'
}

#endregion
