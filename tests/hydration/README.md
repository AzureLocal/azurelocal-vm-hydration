# Hydration Integration Tests

End-to-end integration tests for `Invoke-VMHydration.ps1` and the `Invoke-VMHydration` module cmdlet. These tests run on an Azure Local cluster node and validate the full hydration pipeline — from creating a plain unmanaged Hyper-V VM through to verifying the resulting Azure resource.

---

## How It Works

The hydration test simulates the real-world "unmanaged VM on a cluster" scenario:

```
New-HydrationTestVM.ps1
  └─ Creates a plain Hyper-V VM with no Azure registration
       • VHD under the cluster storage GUID folder
       • KVP + Guest Service Interface integration services enabled
       • Configured as Highly Available in Failover Cluster Manager
       • Started

Invoke-HydrationTest.ps1
  └─ Runs the full test:
       1. (Optionally) calls New-HydrationTestVM.ps1
       2. Runs Invoke-VMHydration.ps1 against the test VM
       3. Waits for provisioningState: Succeeded (up to 300s)
       4. Validates Azure VM resource, OS disk, and NIC exist
       5. Reports pass/fail counts and a summary

Remove-HydrationTestResources.ps1
  └─ Cleans up everything:
       • Azure VM resource
       • Azure OS disk (and any data disks)
       • Azure NIC
       • Hyper-V VM (stopped, removed from cluster, deleted)
       • VHD files from cluster storage
```

---

## Scripts

| Script | Purpose |
|---|---|
| `New-HydrationTestVM.ps1` | Creates a plain, never-Azure-managed Hyper-V VM ready for hydration |
| `Invoke-HydrationTest.ps1` | Orchestrates the full end-to-end test |
| `Remove-HydrationTestResources.ps1` | Tears down all Azure and Hyper-V resources after the test |

---

## VHD Source Options

The test VM needs a disk to attach. Four options are supported, in priority order:

### 1. Marketplace gallery image (recommended)

Use an image already downloaded to the cluster from the Azure marketplace:

```powershell
# List images available on the cluster
az stack-hci-vm image list --resource-group <rg> --output table

# Run the test with that image
.\Invoke-HydrationTest.ps1 ... -GalleryImageName 'windows-server-2022-datacenter'
```

The script resolves the local VHDX path automatically from the Azure resource.

### 2. Local ISO on cluster storage

Point at a Windows Server ISO already present on the cluster. The script downloads `Convert-WindowsImage.ps1` from Microsoft's MSLab repository and converts the ISO to a bootable VHDX automatically:

```powershell
.\Invoke-HydrationTest.ps1 ... -IsoPath 'C:\ClusterStorage\csv-01\ISOs\WS2022.iso'
```

### 3. Download Windows Server 2022 Evaluation ISO automatically

The script downloads the evaluation ISO (~5 GB) directly from Microsoft, then converts it:

```powershell
.\Invoke-HydrationTest.ps1 ... -DownloadEvalIso
```

If the default Microsoft download URL has changed, provide an updated one:

```powershell
.\Invoke-HydrationTest.ps1 ... -DownloadEvalIso -EvalIsoUrl 'https://...'
```

> Get a current direct download link from:
> https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022

### 4. Explicit VHD/VHDX path

Provide a path to any existing VHD or VHDX on the cluster storage:

```powershell
.\Invoke-HydrationTest.ps1 ... -SourceVhdPath 'C:\ClusterStorage\csv-01\templates\WS2022.vhdx'
```

### 5. Empty VHD (no OS)

Omit all VHD source options. An empty dynamically-allocated VHD is created. The VM starts in Hyper-V but does not boot into Windows.

**Use this when:** you only need to validate Azure resource registration (disk, NIC, VM resources created and reach `provisioningState: Succeeded`). Arc agent, Guest Management, and KVP exchange require a real OS.

---

## Gen1 and Gen2 VMs

The `-Generation` parameter controls both the Hyper-V VM generation and (when converting from ISO) the disk partition scheme:

| Generation | Firmware | Partition | Azure hydration path |
|---|---|---|---|
| `2` (default) | UEFI | GPT | Azure CLI (`az stack-hci-vm disk create-from-local`) |
| `1` | BIOS | MBR | ARM REST API (CLI lacks `hyperVGeneration` support) |

Gen1 testing exercises the ARM REST API code path in `Invoke-VMHydration.ps1` — important to validate separately.

```powershell
# Test Gen2 hydration (default)
.\Invoke-HydrationTest.ps1 ... -DownloadEvalIso -Generation 2

# Test Gen1 hydration (ARM REST API path)
.\Invoke-HydrationTest.ps1 ... -DownloadEvalIso -Generation 1
```

---

## Quick Start

Run on an Azure Local cluster node as Administrator. Azure CLI must be authenticated (`az login`).

### Step 1 — Run the test (all-in-one)

```powershell
.\tests\hydration\Invoke-HydrationTest.ps1 `
    -ResourceGroup   'rg-azlocal-test' `
    -CustomLocation  '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<cl-name>' `
    -StoragePathId   '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/storageContainers/<name>' `
    -StorageRootPath 'C:\ClusterStorage\csv-01' `
    -SubnetId        'lnet-test-vlan10' `
    -Location        'eastus' `
    -GalleryImageName 'windows-server-2022-datacenter'
```

The test auto-generates a VM name (`test-hydration-<timestamp>`). Note the name from the output — you need it for cleanup.

### Step 2 — Clean up

```powershell
.\tests\hydration\Remove-HydrationTestResources.ps1 `
    -VMName        'test-hydration-20260428120000' `
    -ResourceGroup 'rg-azlocal-test'
```

---

## Running Steps Separately

You can break the test into individual steps, which is useful when debugging or re-running after a partial failure.

### Create the test VM only

```powershell
$ctx = .\tests\hydration\New-HydrationTestVM.ps1 `
    -StorageRootPath  'C:\ClusterStorage\csv-01' `
    -SourceVhdPath    'C:\ClusterStorage\csv-01\templates\WS2022.vhdx'

# $ctx contains VMName, VhdPath, GuidFolderPath, HasRealOS, etc.
```

### Run the test against an existing VM

```powershell
.\tests\hydration\Invoke-HydrationTest.ps1 `
    -VMName        'test-hydration-20260428120000' `
    -ResourceGroup 'rg-azlocal-test' `
    -CustomLocation '...' `
    -StoragePathId  '...' `
    -StorageRootPath 'C:\ClusterStorage\csv-01' `
    -SubnetId       'lnet-test-vlan10' `
    -Location       'eastus' `
    -SkipSetup
```

---

## Parameter Reference

### `Invoke-HydrationTest.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-ResourceGroup` | Yes | Azure resource group for test resources |
| `-CustomLocation` | Yes | Full ARM URI of the cluster's custom location |
| `-StoragePathId` | Yes | ARM resource ID of the storage container |
| `-StorageRootPath` | Yes | Local filesystem root of the cluster CSV (e.g. `C:\ClusterStorage\csv-01`) |
| `-SubnetId` | Yes | Logical network name or ARM ID for the test NIC |
| `-Location` | Yes | Azure region (e.g. `eastus`) |
| `-VMName` | No | Reuse a specific VM name. Auto-generated if omitted |
| `-NicName` | No | Azure NIC name. Defaults to `<VMName>-test-nic` |
| `-Generation` | No | `1` or `2`. Default: `2` |
| `-GalleryImageName` | No | Marketplace image name on this cluster |
| `-SourceVhdPath` | No | Explicit local VHDX path |
| `-IsoPath` | No | Local ISO path — converted to VHDX automatically |
| `-DownloadEvalIso` | No | Download WS2022 evaluation ISO from Microsoft |
| `-EvalIsoUrl` | No | Override the evaluation ISO download URL |
| `-IsoEdition` | No | Windows edition to install from ISO. Default: `Windows Server 2022 Datacenter` |
| `-SkipClusterCheck` | No | Skip HA/cluster validation (single-node environments) |
| `-SkipSetup` | No | Skip VM creation — test against an existing VM |

### `New-HydrationTestVM.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-StorageRootPath` | Yes | Cluster CSV root path |
| `-VMName` | No | VM name. Defaults to `test-hydration-<timestamp>` |
| `-VhdSizeGB` | No | Size of the empty VHD in GB when no source is provided. Default: `8` |
| `-Generation` | No | `1` or `2`. Default: `2` |
| `-SourceVhdPath` | No | Copy this VHD/VHDX into the test folder instead of creating empty |
| `-SwitchName` | No | Hyper-V virtual switch. Omit to leave VM with no NIC (hydration adds it) |

### `Remove-HydrationTestResources.ps1`

| Parameter | Required | Description |
|---|---|---|
| `-VMName` | Yes | Test VM name to remove |
| `-ResourceGroup` | Yes | Azure resource group |
| `-NicName` | No | NIC name. Defaults to `<VMName>-test-nic` |
| `-OsDiskName` | No | OS disk name. Defaults to `<VMName>-osdisk` |
| `-KeepVhd` | No | Leave VHD files on disk (useful to re-run without re-creating) |
| `-Force` | No | Skip confirmation prompts |

---

## What the Test Validates

| Check | Pass condition |
|---|---|
| Hydration script exits cleanly | No exception thrown, exit code 0 |
| Azure VM resource created | `az stack-hci-vm show` returns the resource |
| `provisioningState` | `Succeeded` within 300 seconds |
| OS disk resource exists | `<VMName>-osdisk` found in resource group |
| NIC resource exists | `<VMName>-test-nic` (or specified NicName) found |

> **Not validated by the test:** Arc agent install, Guest Management activation, KVP key exchange, network connectivity inside the guest. These require a real OS and manual follow-up after the test.

---

## Troubleshooting

**Pre-flight check fails (KVP / HA / GUID folder)**
The test VM was not created correctly. Delete it with `Remove-HydrationTestResources.ps1` and re-run `New-HydrationTestVM.ps1`. On single-node environments, pass `-SkipClusterCheck`.

**`az stack-hci-vm disk create-from-local` fails**
Check that the VHD path is accessible from the node running the test, that the storage container ARM ID is correct, and that the `stack-hci-vm` extension is ≥ 1.11.9 (`az extension show --name stack-hci-vm --query version`).

**`provisioningState` stuck at `Updating` / times out**
Check the VM resource in the Azure portal for error details. Do **not** delete the Azure resource — run `Remove-HydrationTestResources.ps1` which handles partial states safely.

**ISO download fails**
Visit https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022, download the ISO manually, and use `-IsoPath` instead of `-DownloadEvalIso`.
