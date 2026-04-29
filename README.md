# azurelocal-vm-hydration

![Azure Local VM Hydration — Revive. Reconnect. Reclaim.](docs/assets/images/azurelocal-vm-hydration-banner.svg)

[![Azure Local](https://img.shields.io/badge/Azure%20Local-azurelocal.cloud-0078D4?logo=microsoft-azure)](https://azurelocal.cloud)
[![PSGallery](https://img.shields.io/badge/PSGallery-AzureLocalVMHydration-3b82f6?logo=powershell)](https://www.powershellgallery.com/packages/AzureLocalVMHydration)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Docs: MkDocs Material](https://img.shields.io/badge/docs-MkDocs%20Material-0f766e)](https://azurelocal.github.io/azurelocal-vm-hydration/)
[![PowerShell: 7.x](https://img.shields.io/badge/PowerShell-7.x-3b82f6)](https://github.com/PowerShell/PowerShell)

Documentation: [azurelocal.github.io/azurelocal-vm-hydration](https://azurelocal.github.io/azurelocal-vm-hydration/) | Solutions: [azurelocal.cloud](https://azurelocal.cloud)

> *Revive. Reconnect. Reclaim.*

PowerShell automation for adopting existing Hyper-V VMs into **Azure Local** management — without re-imaging or Sysprepping.

Covers two scenarios:

- **VM Hydration** — onboard an unmanaged Hyper-V VM *in place* using `az stack-hci-vm disk create-from-local`, registering it as a `Microsoft.AzureStackHCI/virtualMachineInstances` resource in Azure.
- **VM Reconnect** — restore a VM to a *different* Azure Local cluster and re-project it into Azure using `az stack-hci-vm reconnect-to-azure`.

> **Private Preview**
>
> These scripts implement the Microsoft Azure Local VM Reconnect Private Preview procedure. Requirements and CLI commands may change before general availability. Use in production at your own risk.

---

## Prerequisites

- Azure Local cluster running **2602 or later**
- `az stack-hci-vm` extension **≥ 1.11.9**
- VMs must reside in a storage path **GUID subfolder** (e.g., `C:\ClusterStorage\Volume1\<guid>\`)
- VMs must be configured as **Highly Available** in Failover Cluster Manager
- **Hyper-V Data Exchange Service (KVP)** and **Guest Service Interface** enabled on the VM
- Run as **Administrator** on a cluster node

---

## PowerShell Module (recommended)

Install from PSGallery — works anywhere PowerShell 7 is available:

```powershell
Install-Module AzureLocalVMHydration -Scope CurrentUser
```

### VM Hydration

```powershell
Invoke-VMHydration `
    -VMName        'WEBSRV01' `
    -ResourceGroup 'rg-azlocal-prod' `
    -CustomLocation '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<cl-name>' `
    -StoragePathId  '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/storageContainers/<name>' `
    -NicName       'WEBSRV01-nic1' `
    -SubnetId      'lnet-prod-vlan10' `
    -Location      'eastus'
```

### VM Reconnect

```powershell
Invoke-VMReconnect `
    -VMName        'APPSRV01' `
    -LocalVMName   'APPSRV01_restored' `
    -ResourceGroup 'rg-azlocal-prod' `
    -CustomLocation '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<dest-cl-name>' `
    -NicName       'APPSRV01-nic2' `
    -SubnetId      'lnet-prod-vlan10' `
    -Location      'eastus' `
    -RemoveSourceVM
```

### Pre-flight Check Only

```powershell
Test-VMHydrationPrerequisites -VMName 'WEBSRV01'
# Returns $true if all checks pass, $false if any fail
```

---

## Standalone Scripts

No install required — run directly on a cluster node:

```text
scripts/
├── helpers/
│   ├── Common-Functions.ps1             # Shared logging and Azure CLI wrappers
│   └── Test-HydrationPrerequisites.ps1  # Pre-flight checks (dot-sourced by both scripts)
├── Invoke-VMHydration.ps1               # Hydrate an unmanaged VM in-place
└── Invoke-VMReconnect.ps1               # Reconnect a VM after cross-cluster restore
```

Both scripts support `-WhatIf` for dry runs. See [Getting Started](https://azurelocal.github.io/azurelocal-vm-hydration/getting-started/) for full parameter reference and examples.

---

## Configuration

Copy `config/variables.example.yml` to `config/variables.yml` and fill in your environment values. `variables.yml` is gitignored — never commit it.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for details.

---

## License

See [LICENSE](./LICENSE) for details.
