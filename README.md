# azurelocal-vm-hydration

![Azure Local VM Hydration](docs/assets/images/azurelocal-vm-hydration-banner.svg)

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
- `az stack-hci-vm` extension **≥ 1.11.9** (`az extension show --name stack-hci-vm --query version`)
- VMs must reside in a storage path GUID subfolder (e.g., `C:\ClusterStorage\Volume1\<guid>\`)
- VMs must be configured as **Highly Available** in Failover Cluster Manager
- **Hyper-V Data Exchange Service (KVP)** enabled inside the VM
- Run scripts as **Administrator** on a cluster node

---

## Scripts

```text
scripts/
├── helpers/
│   ├── Common-Functions.ps1             # Shared logging and Azure CLI wrappers
│   └── Test-HydrationPrerequisites.ps1  # Pre-flight checks (dot-sourced by both scripts)
├── Invoke-VMHydration.ps1               # Hydrate an unmanaged VM in-place
└── Invoke-VMReconnect.ps1               # Reconnect a VM after cross-cluster restore
```

Both scripts support `-WhatIf` for dry runs.

### VM Hydration (in-place onboarding)

```powershell
.\scripts\Invoke-VMHydration.ps1 `
    -VMName "MyVM" `
    -ResourceGroup "rg-azurelocal" `
    -CustomLocation "/subscriptions/.../resourceGroups/.../providers/Microsoft.ExtendedLocation/customLocations/cl-site1" `
    -LogicalNetwork "lnet-prod"
```

### VM Reconnect (cross-cluster restore)

```powershell
.\scripts\Invoke-VMReconnect.ps1 `
    -VMName "MyVM" `
    -ResourceGroup "rg-azurelocal" `
    -CustomLocation "/subscriptions/.../resourceGroups/.../providers/Microsoft.ExtendedLocation/customLocations/cl-site2" `
    -LogicalNetwork "lnet-prod"
```

---

## Configuration

Copy `config/variables.example.yml` to `config/variables.yml` and fill in your environment values. `variables.yml` is gitignored — never commit it.

---

## Documentation

Full documentation: [https://azurelocal.github.io/azurelocal-vm-hydration/](https://azurelocal.github.io/azurelocal-vm-hydration/)

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for details.

---

## License

See [LICENSE](./LICENSE) for details.
