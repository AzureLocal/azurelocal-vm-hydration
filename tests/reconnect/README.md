# Reconnect Integration Tests

End-to-end integration tests for `Invoke-VMReconnect.ps1` and the `Invoke-VMReconnect` module cmdlet. These tests run on an Azure Local cluster node and validate the full reconnect pipeline — from simulating a cross-cluster restore that orphans a VM's Azure resource, through to verifying the VM is successfully re-projected back into Azure.

---

## How It Works

The reconnect test simulates the real-world "VM restored to a different cluster" scenario. On a single cluster this is achieved in two phases.

### Phase A — Create and hydrate a test VM

```
New-ReconnectTestScenario.ps1 (Phase A)
  └─ Calls New-HydrationTestVM.ps1 to create a plain Hyper-V VM
  └─ Calls Invoke-VMHydration.ps1 to register it with Azure
  └─ Waits for provisioningState: Succeeded
  └─ Result: a running VM with a valid Azure resource
```

### Phase B — Simulate a backup restore that orphans the Azure resource

```
New-ReconnectTestScenario.ps1 (Phase B)
  └─ Stops the VM
  └─ Exports the VM to a temporary path (simulating a Veeam/MABS backup)
  └─ Deletes the Azure VM resource  ← this is the "orphan" step
  └─ Removes the original Hyper-V VM
  └─ Imports the VM into a NEW GUID folder  ← simulates restore to different storage path
  └─ Re-enables integration services, adds to Failover Cluster, starts VM
  └─ Cleans up the export temp files
  └─ Result: VM running in Hyper-V with NO Azure resource (orphan state)
```

### The actual test

```
Invoke-ReconnectTest.ps1
  └─ (Optionally) calls New-ReconnectTestScenario.ps1
  └─ Confirms orphan state (Azure resource absent, Hyper-V VM present)
  └─ Runs Invoke-VMReconnect.ps1 against the orphaned VM
  └─ Waits for provisioningState: Succeeded (up to 300s)
  └─ Validates VM is re-projected at the destination custom location
  └─ Validates new NIC exists in Azure
  └─ Reports pass/fail counts and a summary

Remove-ReconnectTestResources.ps1
  └─ Deletes Azure VM resource, all NICs (nic1 + nic2), OS disk
  └─ Removes both Hyper-V VMs (original + restored) from cluster and Hyper-V
  └─ Deletes VHD files from cluster storage
```

---

## Scripts

| Script | Purpose |
|---|---|
| `New-ReconnectTestScenario.ps1` | Builds the complete orphaned VM scenario (both phases) |
| `Invoke-ReconnectTest.ps1` | Orchestrates the full end-to-end reconnect test |
| `Remove-ReconnectTestResources.ps1` | Tears down all Azure and Hyper-V resources after the test |

---

## VHD Source Options

The same four source options from the hydration tests apply here. The VHD is used in Phase A when creating the initial test VM.

### 1. Marketplace gallery image (recommended)

```powershell
# List images available on the cluster
az stack-hci-vm image list --resource-group <rg> --output table

.\Invoke-ReconnectTest.ps1 ... -GalleryImageName 'windows-server-2022-datacenter'
```

### 2. Local ISO on cluster storage

```powershell
.\Invoke-ReconnectTest.ps1 ... -IsoPath 'C:\ClusterStorage\csv-01\ISOs\WS2022.iso'
```

`Convert-WindowsImage.ps1` is downloaded from MSLab automatically and the ISO is converted to a VHDX.

### 3. Download Windows Server 2022 Evaluation ISO automatically

```powershell
.\Invoke-ReconnectTest.ps1 ... -DownloadEvalIso
```

Downloads ~5 GB from Microsoft then converts. ISO is cached in `$env:TEMP` for re-use. Override the URL with `-EvalIsoUrl` if the default has expired.

> Get a current direct link from: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022

### 4. Explicit VHD/VHDX path

```powershell
.\Invoke-ReconnectTest.ps1 ... -SourceVhdPath 'C:\ClusterStorage\csv-01\templates\WS2022.vhdx'
```

### 5. Empty VHD (no OS)

Omit all VHD source options. An empty VHD is created. The VM starts in Hyper-V but does not boot into Windows. Sufficient for validating Azure resource re-projection but not for Arc agent or Guest Management testing.

---

## Quick Start

Run on an Azure Local cluster node as Administrator. Azure CLI must be authenticated (`az login`).

### Step 1 — Run the full test (all-in-one)

```powershell
.\tests\reconnect\Invoke-ReconnectTest.ps1 `
    -ResourceGroup   'rg-azlocal-test' `
    -CustomLocation  '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<cl-name>' `
    -StoragePathId   '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/storageContainers/<name>' `
    -StorageRootPath 'C:\ClusterStorage\csv-01' `
    -SubnetId        'lnet-test-vlan10' `
    -Location        'eastus' `
    -GalleryImageName 'windows-server-2022-datacenter'
```

The test auto-generates VM names (`test-reconnect-<timestamp>` and `test-reconnect-<timestamp>-restored`). Note both names from the output — you need them for cleanup.

### Step 2 — Clean up

```powershell
.\tests\reconnect\Remove-ReconnectTestResources.ps1 `
    -VMName        'test-reconnect-20260428120000' `
    -ResourceGroup 'rg-azlocal-test'
```

The cleanup script removes both the original and restored VMs automatically.

---

## Running Steps Separately

Breaking the test into steps is useful when debugging a specific phase or re-running after a partial failure.

### Set up the orphaned scenario only

```powershell
$ctx = .\tests\reconnect\New-ReconnectTestScenario.ps1 `
    -ResourceGroup   'rg-azlocal-test' `
    -CustomLocation  '...' `
    -StoragePathId   '...' `
    -StorageRootPath 'C:\ClusterStorage\csv-01' `
    -SubnetId        'lnet-test-vlan10' `
    -Location        'eastus' `
    -GalleryImageName 'windows-server-2022-datacenter'

# $ctx contains:
#   OriginalVMName   — the Azure resource name (now orphaned)
#   RestoredVMName   — the Hyper-V name of the restored VM
#   NewVhdPath, NewVmFolder, GuidFolderPath, etc.
```

### Run the reconnect test against an existing scenario

```powershell
.\tests\reconnect\Invoke-ReconnectTest.ps1 `
    -VMName         'test-reconnect-20260428120000' `
    -RestoredVMName 'test-reconnect-20260428120000-restored' `
    -ResourceGroup  'rg-azlocal-test' `
    -CustomLocation '...' `
    -StoragePathId  '...' `
    -StorageRootPath 'C:\ClusterStorage\csv-01' `
    -SubnetId       'lnet-test-vlan10' `
    -Location       'eastus' `
    -SkipSetup
```

---

## Parameter Reference

### `Invoke-ReconnectTest.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-ResourceGroup` | Yes | Azure resource group |
| `-CustomLocation` | Yes | Full ARM URI of the cluster's custom location |
| `-StoragePathId` | Yes | ARM resource ID of the storage container |
| `-StorageRootPath` | Yes | Local filesystem root of the cluster CSV |
| `-SubnetId` | Yes | Logical network name or ARM ID for the new NIC |
| `-Location` | Yes | Azure region (e.g. `eastus`) |
| `-VMName` | No | Azure VM name (original resource name). Auto-generated if omitted |
| `-RestoredVMName` | No | Hyper-V name of the restored VM. Defaults to `<VMName>-restored`. Required with `-SkipSetup` |
| `-NewNicName` | No | Name for the new Azure NIC. Defaults to `<VMName>-nic2` |
| `-SkipSetup` | No | Skip scenario setup — use an existing orphaned VM. Requires `-VMName` and `-RestoredVMName` |
| `-SkipClusterCheck` | No | Skip HA/cluster validation (single-node environments) |

### `New-ReconnectTestScenario.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-ResourceGroup` | Yes | Azure resource group for Phase A hydration |
| `-CustomLocation` | Yes | Full ARM URI of the cluster's custom location |
| `-StoragePathId` | Yes | ARM resource ID of the storage container |
| `-StorageRootPath` | Yes | Local filesystem root of the cluster CSV |
| `-SubnetId` | Yes | Logical network for the initial Phase A NIC |
| `-Location` | Yes | Azure region |
| `-VMName` | No | Base name for the test VMs. Defaults to `test-reconnect-<timestamp>` |
| `-GalleryImageName` | No | Marketplace image name on this cluster |
| `-SourceVhdPath` | No | Explicit local VHDX path |
| `-IsoPath` | No | Local ISO path — converted to VHDX automatically |
| `-DownloadEvalIso` | No | Download WS2022 evaluation ISO from Microsoft |
| `-EvalIsoUrl` | No | Override the evaluation ISO download URL |
| `-IsoEdition` | No | Windows edition. Default: `Windows Server 2022 Datacenter` |
| `-ExportPath` | No | Temporary path for VM export. Default: `C:\Temp\HydrationTestExport` |
| `-SkipClusterCheck` | No | Skip HA/cluster validation |

### `Remove-ReconnectTestResources.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-VMName` | Yes | Original Azure VM name (base name) |
| `-ResourceGroup` | Yes | Azure resource group |
| `-RestoredVMName` | No | Restored VM name. Defaults to `<VMName>-restored` |
| `-KeepVhd` | No | Leave VHD files on disk |
| `-Force` | No | Skip confirmation prompts |

---

## What the Test Validates

### Pre-reconnect (orphan state verification)

| Check | Pass condition |
|---|---|
| Azure resource is absent | `az stack-hci-vm show` returns nothing for `$VMName` |
| Hyper-V VM is present | `Get-VM -Name $RestoredVMName` returns the VM |

### Post-reconnect

| Check | Pass condition |
|---|---|
| Reconnect script exits cleanly | No exception thrown, exit code 0 |
| Azure VM resource re-created | `az stack-hci-vm show` returns the resource |
| `provisioningState` | `Succeeded` within 300 seconds |
| VM registered at destination | `extendedLocation.name` matches the `-CustomLocation` value |
| New NIC exists | `<VMName>-nic2` (or specified NicName) found in resource group |

> **Not validated:** network connectivity inside the guest, Arc agent re-registration, Guest Management re-activation. These require a real OS and manual follow-up.

---

## Resource Naming Convention

The test creates resources with predictable names so cleanup is reliable:

| Resource | Name pattern |
|---|---|
| Azure VM | `<VMName>` (same as original) |
| Original NIC (Phase A) | `<VMName>-nic1` |
| New NIC (reconnect) | `<VMName>-nic2` |
| OS disk | `<VMName>-osdisk` |
| Original Hyper-V VM | `<VMName>` (removed during Phase B) |
| Restored Hyper-V VM | `<VMName>-restored` |

---

## Troubleshooting

**Phase A fails (hydration step)**
Check that Azure CLI is authenticated (`az login`), the resource group exists, and the `stack-hci-vm` extension is ≥ 1.11.9. See the [hydration test README](../hydration/README.md) for hydration-specific troubleshooting.

**Phase B fails (export step)**
Ensure the cluster node has write access to the `-ExportPath` directory and there is enough disk space for the VM export (~equal to the VHD size + VM config).

**Pre-reconnect check shows Azure VM still exists**
The orphan step (`az stack-hci-vm delete`) may have failed silently. The test will warn you but continue — `Invoke-VMReconnect.ps1` can repair an existing VM resource in a failed state.

**`provisioningState` stuck or reconnect fails**
Do **not** delete the Azure VM resource from the portal or CLI. The reconnect command can repair a VM resource in a failed state. Fix the root cause (extension version, GUID folder, KVP service) and re-run `Invoke-ReconnectTest.ps1 -SkipSetup`.

**Cleanup leaves orphaned resources**
`Remove-ReconnectTestResources.ps1` is idempotent — resources that don't exist are skipped with a warning. Run it multiple times if needed. For Azure resources you can also use:
```powershell
az stack-hci-vm delete --name <VMName> --resource-group <rg> --yes
az stack-hci-vm network nic delete --name <VMName>-nic1 --resource-group <rg> --yes
az stack-hci-vm network nic delete --name <VMName>-nic2 --resource-group <rg> --yes
az stack-hci-vm disk delete --name <VMName>-osdisk --resource-group <rg> --yes
```
