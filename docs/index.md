# Azure Local VM Hydration & Reconnect

![Azure Local VM Hydration — Revive. Reconnect. Reclaim.](assets/images/azurelocal-vm-hydration-banner.svg)

> *Revive. Reconnect. Reclaim.*

!!! warning "Private Preview"
    This tooling is based on Microsoft's Private Preview VM Reconnection feature for Azure Local.
    Scripts and procedures are subject to change as the feature moves toward general availability.

PowerShell automation for two related Azure Local VM operations:

## VM Hydration

Takes an existing, unmanaged Hyper-V VM running on an Azure Local cluster and brings it under Azure Local management — without re-imaging, Sysprepping, or disrupting the workload.

The VM becomes a `Microsoft.AzureStackHCI/virtualMachineInstances` resource, fully manageable from the Azure portal, with lifecycle operations (start/stop, disk attach, extensions, policy).

- **Module cmdlet:** `Invoke-VMHydration`
- **Standalone script:** `scripts/Invoke-VMHydration.ps1`

## VM Reconnect

Reconnects an Azure Local VM to its Azure resource after the VM has been restored to a *different* Azure Local cluster (e.g. via Veeam backup restore, export/import). The Azure resource becomes orphaned after such a restore; this tooling re-projects it onto the destination cluster.

- **Module cmdlet:** `Invoke-VMReconnect`
- **Standalone script:** `scripts/Invoke-VMReconnect.ps1`

---

## Two Ways to Use This Repo

### PowerShell Module (recommended)

Install from PSGallery — works anywhere PowerShell 7 is available:

```powershell
Install-Module AzureLocalVMHydration -Scope CurrentUser
```

Full module reference, parameters, and examples: [Module Reference](module.md)

### Standalone Scripts

No install required — dot-source helpers and run directly on a cluster node.
Full usage: [Getting Started](getting-started.md)

---

## What "Hydration" Means

In this context, **hydration** refers to registering a locally-hosted VHD/VHDX file as an Azure-managed disk resource — making it visible and manageable in Azure without moving the data. This is the core operation that underpins both scenarios above.

The term comes from Microsoft's own naming of the underlying CLI command: `az stack-hci-vm disk create-from-local`.

---

## Related

- [Getting Started](getting-started.md)
- [Module Reference](module.md)
- [Roadmap](roadmap.md)
- [AzureLocal Solutions](https://azurelocal.cloud)
- [GitHub Repository](https://github.com/AzureLocal/azurelocal-vm-hydration)
