@{
    RootModule           = 'AzureLocalVMHydration.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Core')
    GUID                 = '83e5c34f-9da7-4130-b695-b7741e59446f'
    Author               = 'Azure Local Cloud'
    CompanyName          = 'Azure Local Cloud'
    Copyright            = '(c) 2026 Azure Local Cloud. All rights reserved.'
    Description          = 'AzureLocalVMHydration provides PowerShell cmdlets for adopting existing Hyper-V VMs into Azure Local management without re-imaging or Sysprepping. Supports VM Hydration (in-place onboarding) and VM Reconnect (cross-cluster restore recovery) for both Gen1 and Gen2 VMs.'
    PowerShellVersion    = '7.0'

    FunctionsToExport    = @(
        'Invoke-VMHydration',
        'Invoke-VMReconnect',
        'Test-VMHydrationPrerequisites'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'AzureLocal', 'AzureStackHCI', 'HCI', 'Arc', 'HyperV',
                'VMHydration', 'VMReconnect', 'Migration', 'PowerShell'
            )
            LicenseUri   = 'https://github.com/AzureLocal/azurelocal-vm-hydration/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/AzureLocal/azurelocal-vm-hydration'
            IconUri      = 'https://azurelocal.github.io/azurelocal-vm-hydration/assets/images/azurelocal-vm-hydration-icon.svg'
            ReleaseNotes = 'Initial release. Provides Invoke-VMHydration, Invoke-VMReconnect, and Test-VMHydrationPrerequisites.'
        }
    }
}
