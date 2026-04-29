# Roadmap

## Completed

- [x] Initial repository scaffold and CI/CD
- [x] MkDocs documentation site with branding (icon, banner, favicon)
- [x] `scripts/helpers/Common-Functions.ps1` — shared logging, `Invoke-AzCli`, `Invoke-ArmRestApi`
- [x] `scripts/helpers/Test-HydrationPrerequisites.ps1` — pre-flight validation (all 10 checks from Private Preview doc)
- [x] `scripts/Invoke-VMHydration.ps1` — hydrate unmanaged Hyper-V VM into Azure Local (Gen1 + Gen2)
- [x] `scripts/Invoke-VMReconnect.ps1` — reconnect Azure Local VM after cross-cluster restore
- [x] `AzureLocalVMHydration` PowerShell module — PSGallery-publishable module (v0.1.0)
  - `Invoke-VMHydration` — hydrate cmdlet with `-WhatIf` support
  - `Invoke-VMReconnect` — reconnect cmdlet with `-WhatIf` support
  - `Test-VMHydrationPrerequisites` — bool-returning pre-flight cmdlet

## In Progress

- [ ] Field validation of `Invoke-VMHydration` against a live Azure Local 2602 cluster
- [ ] Field validation of `Invoke-VMReconnect` against the Private Preview environment
- [ ] PSGallery publish of `AzureLocalVMHydration` v0.1.0

## Planned

- [ ] Pester test coverage for module functions (mocked az CLI responses)
- [ ] Bulk hydration support — accept a CSV/JSON VM inventory and hydrate multiple VMs in sequence
- [ ] Pipeline integration — GitHub Actions workflow for running Pester tests
- [ ] Linux VM support validation
- [ ] Gen1 field validation (ARM REST API path for `hyperVGeneration: V1`)
- [ ] Guest Management enablement automation post-hydration

## Known Gaps

- Gen1 VM hydration uses the ARM REST API directly — the Azure CLI `stack-hci-vm disk create-from-local` command does not expose `hyperVGeneration`. This path has not yet been field-validated.
- The `az stack-hci-vm reconnect-to-azure` command is Private Preview as of February 2026. Availability may vary by cluster version and extension version.
