# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**azurelocal-vm-hydration** automates the process of reconnecting or adopting existing Hyper-V VMs into the Azure Local control plane — making unmanaged VMs visible and manageable as `Microsoft.AzureStackHCI/virtualMachineInstances` resources in Azure, without re-imaging or Sysprepping the VM.

Two operations are covered:

- **VM Hydration** — onboarding an existing unmanaged Hyper-V VM *in place* into Azure Local management using `az stack-hci-vm disk create-from-local`
- **VM Reconnect** — restoring a VM to a *different* Azure Local cluster and re-projecting it into Azure using `az stack-hci-vm reconnect-to-azure`

This is a **two-part repo**: standalone scripts that can be run directly on a cluster node, AND a PSGallery-publishable PowerShell module. Both parts implement the same logic; the module wraps everything in proper cmdlets for `Install-Module` workflows.

## PowerShell Module

```text
AzureLocalVMHydration.psm1            # Root module — dot-sources Private + Public
AzureLocalVMHydration.psd1            # Manifest (v0.1.0, GUID 83e5c34f, PS 7.0+, PSGallery-ready)
Modules/
├── Private/
│   ├── Common-Functions.ps1          # Write-Step/OK/Warn/Fail, Invoke-AzCli, Invoke-ArmRestApi,
│   │                                 #   Assert-AdminElevation
│   └── Test-HydrationPrerequisites.ps1  # Internal 10-check pre-flight (returns List[string])
└── Public/
    ├── Invoke-VMHydration.ps1        # Exported: hydrate unmanaged VM in-place (Gen1 + Gen2)
    ├── Invoke-VMReconnect.ps1        # Exported: reconnect VM after cross-cluster restore
    └── Test-VMHydrationPrerequisites.ps1  # Exported: bool-returning pre-flight wrapper
```

Exported functions: `Invoke-VMHydration`, `Invoke-VMReconnect`, `Test-VMHydrationPrerequisites`

Module uses `Assert-AdminElevation` (throws if not elevated) instead of `#Requires -RunAsAdministrator`.
Module uses `throw` instead of `exit 1` — appropriate for module error handling.
Both cmdlets support `-WhatIf` (`[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`).

## Scripts

```text
scripts/
├── helpers/
│   ├── Common-Functions.ps1           # Shared logging and Azure CLI wrappers
│   └── Test-HydrationPrerequisites.ps1  # Pre-flight checks (dot-sourced by both main scripts)
├── Invoke-VMHydration.ps1             # Hydrate unmanaged VM in-place (Gen1 + Gen2)
└── Invoke-VMReconnect.ps1             # Reconnect VM after cross-cluster restore
```

Both main scripts support `-WhatIf` for dry runs and `#Requires -RunAsAdministrator`.
Both dot-source the helpers at runtime — no module install required.

## Reference Materials (Read These First)

`reference/` contains two critical research documents — read them before writing any automation:

- **`reference/AzureLocalVMReconnectPrivatePreview_02232026.md`** — Microsoft's Private Preview runbook (converted from PDF). Defines the official 5-step procedure: prerequisites → remove NICs → hydrate data disks → reconnect VM → attach NIC. Key commands: `az stack-hci-vm disk create-from-local` and `az stack-hci-vm reconnect-to-azure --yes`.

- **`reference/hybridcore-vm-adoption-research.md`** — Community reverse-engineering of undocumented `stack-hci-vm` CLI subcommands. Covers Gen2 adoption, bulk automation scripting, and Gen1 adoption (which requires direct ARM REST API calls because the CLI lacks `hyperVGeneration` support). The Hybridcore "disk swap" technique is mechanically equivalent to Microsoft's `disk create-from-local` hydration.

## Key Technical Constraints

These are hard architectural requirements that apply to all scripts in this repo:

- **GUID folder** — all VM files must reside inside the storage path GUID subfolder (e.g., `C:\ClusterStorage\Volume1\e21794969177373\`). Azure Local will not adopt a VM whose files are outside this folder. Validate with `Get-VM | fl ConfigurationLocation`.
- **HA-VM requirement** — VMs must be configured as highly available in Failover Cluster Manager before reconnect. Most backup tools restore as standard Hyper-V VMs; HA configuration is a required pre-step.
- **Gen1 vs Gen2** — Gen2 uses the Azure CLI. Gen1 requires the ARM REST API directly (`hyperVGeneration: V1`, `diskFileFormat: vhd`, `enable-secure-boot false`, `enable-vtpm false`).
- **CLI version** — `stack-hci-vm` extension must be ≥ 1.11.9. Check with `az extension show --name stack-hci-vm --query version`.
- **Azure Local version** — nodes must be 2602+. On 2601, guest management must be enabled *before* reconnect (can't be added post-reconnect on that version).
- **KVP integration service** — Hyper-V Data Exchange Service (Key-Value Pair Exchange) must be enabled in the VM before reconnect.
- **Failed reconnect — do not delete** — if `reconnect-to-azure` fails, never delete the Azure resource. Fix the root cause and re-run the command to repair it. Deletion can destroy the original VM.

## Configuration

Copy `config/variables.example.yml` to `config/variables.yml` and fill in values. `variables.yml` is gitignored — never commit it. Secrets use `keyvault://` URIs resolved at deploy time.

Schema: `config/schema/variables.schema.json`

## Docs Site

Built with MkDocs Material. Deploys to GitHub Pages on push to `main` when `docs/` or `mkdocs.yml` changes.

```bash
pip install mkdocs-material
mkdocs serve          # local dev server at http://127.0.0.1:8000
mkdocs build --strict # same check CI runs
```

## Commit Conventions

Conventional Commits — release-please generates `CHANGELOG.md` and cuts releases automatically.

| Type | When |
|---|---|
| `feat` | New script, command, or capability |
| `fix` | Bug fix |
| `docs` | Docs only |
| `infra` | CI/CD, workflows, config |
| `chore` | Maintenance |
| `refactor` | Restructure, no behavior change |
| `test` | Tests only |

Branch names: `feat/<name>`, `fix/<name>`, `docs/<name>`

## CI Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `deploy-docs.yml` | Push to `main` (docs/** or mkdocs.yml) | Builds and deploys MkDocs site to GitHub Pages |
| `validate-repo-structure.yml` | PR to `main` | Checks required root files and directories exist |
| `release-please.yml` | Push to `main` | Opens/updates release PR; cuts tags on merge |
