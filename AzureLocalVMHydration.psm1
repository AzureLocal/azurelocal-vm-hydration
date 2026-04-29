# AzureLocalVMHydration root module

$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($folder in @('Modules\Private', 'Modules\Public')) {
    $path = Join-Path $moduleRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object { . $_.FullName }
    }
}

Export-ModuleMember -Function @(
    'Invoke-VMHydration',
    'Invoke-VMReconnect',
    'Test-VMHydrationPrerequisites'
)
