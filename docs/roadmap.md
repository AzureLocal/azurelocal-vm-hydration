# Roadmap

## Completed

- [x] Initial repository scaffold and CI/CD
- [x] MkDocs documentation site
- [x] `scripts/helpers/Common-Functions.ps1` — shared logging, `Invoke-AzCli`, `Invoke-ArmRestApi`
- [x] `scripts/helpers/Test-HydrationPrerequisites.ps1` — pre-flight validation (all Step 1 checks from Private Preview doc)
- [x] `scripts/Invoke-VMHydration.ps1` — hydrate unmanaged Hyper-V VM into Azure Local (Gen1 + Gen2)
- [x] `scripts/Invoke-VMReconnect.ps1` — reconnect Azure Local VM after cross-cluster restore

## In Progress

- [ ] Field validation of `Invoke-VMHydration.ps1` against a live Azure Local 2602 cluster
- [ ] Field validation of `Invoke-VMReconnect.ps1` against the Private Preview environment

## Planned

- [ ] Pester test coverage for helper functions (mocked az CLI responses)
- [ ] Bulk hydration support — accept a CSV/JSON VM inventory and hydrate multiple VMs in sequence
- [ ] `AzureLocal.Hydration` PowerShell module — consolidate scripts into a publishable PSGallery module
- [ ] Pipeline integration — GitHub Actions workflow for running Pester tests
- [ ] Linux VM support validation
- [ ] Gen1 field validation (ARM REST API path for `hyperVGeneration: V1`)
- [ ] Guest Management enablement automation post-hydration

## Known Gaps

- Gen1 VM hydration uses the ARM REST API directly — the Azure CLI `stack-hci-vm disk create-from-local` command does not expose `hyperVGeneration`. This path has not yet been field-validated.
- The `az stack-hci-vm reconnect-to-azure` command is Private Preview as of February 2026. Availability may vary by cluster version and extension version.
