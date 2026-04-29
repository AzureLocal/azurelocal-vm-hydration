# Module Reference

The `AzureLocalVMHydration` PowerShell module wraps all hydration and reconnect logic into proper cmdlets for `Install-Module` workflows. It exports three functions.

## Installation

```powershell
Install-Module AzureLocalVMHydration -Scope CurrentUser
```

Requires:

- PowerShell 7.0 or later
- Administrator elevation on a cluster node
- Azure CLI authenticated (`az login`)
- `stack-hci-vm` extension ≥ 1.11.9

---

## Invoke-VMHydration

Hydrates an unmanaged Hyper-V VM on an Azure Local cluster into Azure Local management.

Takes an existing VM and brings it under Azure Local management as a `Microsoft.AzureStackHCI/virtualMachineInstances` resource — without re-imaging, Sysprepping, or disrupting the workload.

### Steps performed

1. Pre-flight validation (prerequisites, Azure login, resource group)
2. VM disk inventory from Hyper-V
3. Create Azure NIC resource
4. Hydrate OS disk (Gen2 via CLI; Gen1 via ARM REST API)
5. Hydrate any additional data disks
6. Create Azure Local VM resource
7. Attach data disks

### Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `-VMName` | Yes | VM name in Hyper-V Manager |
| `-ResourceGroup` | Yes | Azure resource group for all new resources |
| `-CustomLocation` | Yes | Full ARM URI of the custom location for this cluster |
| `-StoragePathId` | Yes | ARM resource ID of the Azure Local storage container |
| `-NicName` | Yes | Name for the new Azure NIC resource |
| `-SubnetId` | Yes | Name or ARM resource ID of the logical network (lnet) |
| `-Location` | Yes | Azure region (e.g. `eastus`) |
| `-AzureVMName` | No | Azure resource name for the VM. Defaults to `-VMName` |
| `-IpAddress` | No | Static IP for the NIC. Omit to use DHCP |
| `-OsType` | No | `windows` or `linux`. Default: `windows` |
| `-HyperVGeneration` | No | `V1` or `V2`. Default: `V2` |
| `-SkipClusterCheck` | No | Skip HA/Failover Cluster check for non-clustered test environments |
| `-WhatIf` | No | Dry run — shows what would happen without making changes |

### Examples

**Gen2 VM (standard):**

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

**Gen1 VM (ARM REST API path):**

```powershell
Invoke-VMHydration `
    -VMName           'LEGACYAPP' `
    -HyperVGeneration V1 `
    -ResourceGroup    'rg-azlocal-prod' `
    -CustomLocation   '...' `
    -StoragePathId    '...' `
    -NicName          'LEGACYAPP-nic1' `
    -SubnetId         'lnet-prod-vlan10' `
    -Location         'eastus'
```

**Dry run:**

```powershell
Invoke-VMHydration -VMName 'WEBSRV01' ... -WhatIf
```

---

## Invoke-VMReconnect

Reconnects an Azure Local VM to its Azure resource after restore to a different cluster.

Use when a VM has been restored (via Veeam, export/import, or other backup tool) to a different Azure Local cluster and its Azure resource is now orphaned or disconnected.

### Steps performed

1. Pre-flight validation
2. Remove NICs from the restored VM (optional)
3. Hydrate data disks via `az stack-hci-vm disk create-from-local`
4. Reconnect the VM via `az stack-hci-vm reconnect-to-azure`
5. Create and attach a new NIC on the destination cluster

### Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `-VMName` | Yes | VM name as it exists in Azure (original Azure resource name) |
| `-ResourceGroup` | Yes | Original Azure resource group |
| `-CustomLocation` | Yes | Full ARM URI of the custom location for the **destination** cluster |
| `-NicName` | Yes | Name for the new Azure NIC resource on the destination cluster |
| `-SubnetId` | Yes | Name or ARM resource ID of the logical network (lnet) on the destination cluster |
| `-Location` | Yes | Azure region (e.g. `eastus`) |
| `-LocalVMName` | No | VM name in Hyper-V on the destination cluster. Defaults to `-VMName` |
| `-DataDiskLocalPaths` | No | Array of local file paths for data disks to hydrate before reconnecting |
| `-DataDiskNames` | No | Parallel array of Azure resource names for the hydrated data disks |
| `-IpAddress` | No | Static IP for the new NIC. Omit to use DHCP |
| `-RemoveSourceVM` | No | Passes `--yes` to `az stack-hci-vm reconnect-to-azure`, removing the VM from the source cluster on success. **Not reversible.** |
| `-SkipNicRemoval` | No | Skip Step 2 (removing old NICs). Use if NICs were already removed manually |
| `-SkipClusterCheck` | No | Skip HA/Failover Cluster check for non-clustered test environments |
| `-WhatIf` | No | Dry run |

### Examples

**Simple reconnect (no data disks):**

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

**With data disks:**

```powershell
Invoke-VMReconnect `
    -VMName             'APPSRV01' `
    -LocalVMName        'APPSRV01_restored' `
    -ResourceGroup      'rg-azlocal-prod' `
    -CustomLocation     '...' `
    -NicName            'APPSRV01-nic2' `
    -SubnetId           'lnet-prod-vlan10' `
    -Location           'eastus' `
    -DataDiskLocalPaths @('C:\ClusterStorage\csv-01\<guid>\APPSRV01\data1.vhdx',
                          'C:\ClusterStorage\csv-01\<guid>\APPSRV01\data2.vhdx') `
    -DataDiskNames      @('APPSRV01-data1', 'APPSRV01-data2') `
    -RemoveSourceVM
```

!!! danger "If Reconnect Fails"
    **Do NOT delete the VM resource from the Azure portal or CLI.**
    A VM resource may be created in a failed state. Deleting it can destroy the original VM.
    Fix the root cause, then re-run `Invoke-VMReconnect` to repair it.

---

## Test-VMHydrationPrerequisites

Validates all prerequisites for Azure Local VM hydration or reconnect operations and returns `$true` / `$false`.

### Checks performed

1. `stack-hci-vm` CLI extension ≥ 1.11.9
2. VM exists in Hyper-V on this node
3. VM is Running (if `-RequireRunning`)
4. VM is Highly Available in Failover Cluster Manager
5. No DDA GPU attached
6. Not a Trusted Launch VM
7. KVP (Data Exchange) integration service enabled
8. Guest Service Interface enabled
9. VM files are under a GUID folder
10. No backup services running (advisory warning)

### Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `-VMName` | Yes | Hyper-V VM name to validate |
| `-RequireRunning` | No | If set, the VM must be in Running state. Required for reconnect operations |
| `-SkipClusterCheck` | No | Skip the HA/Failover Cluster check for non-clustered test environments |

### Examples

```powershell
# Basic pre-flight check
Test-VMHydrationPrerequisites -VMName 'WEBSRV01'

# Reconnect pre-flight (VM must be Running)
Test-VMHydrationPrerequisites -VMName 'APPSRV01' -RequireRunning

# Use in a script
if (-not (Test-VMHydrationPrerequisites -VMName 'WEBSRV01')) {
    Write-Error 'Pre-flight failed — resolve issues before proceeding.'
    return
}
```

Returns `$true` if all checks pass, `$false` if any fail. Failures are written to the console with details.
