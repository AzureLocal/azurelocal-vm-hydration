# Getting Started

## Prerequisites

All operations require the following before running any script or cmdlet:

### Azure Local Cluster

- Azure Local **version 2602 or above** on all cluster nodes
- Arc Resource Bridge deployed and healthy
- Custom Location configured for the cluster
- Azure CLI authenticated on the cluster node (`az login`)

### Azure CLI Extension

The `stack-hci-vm` extension must be at version **1.11.9 or above**:

```powershell
az extension add --upgrade --name stack-hci-vm --version 1.11.9
```

Verify:

```powershell
az extension show --name stack-hci-vm --query version
```

### VM Requirements

Before running either operation, confirm the target VM:

- Is in **Running** state in Hyper-V (required for reconnect; hydration can run on stopped VMs)
- Is configured as a **Highly Available VM** in Failover Cluster Manager
- Has the **Hyper-V Data Exchange Service (KVP)** integration service enabled
- Has the **Hyper-V Guest Service Interface** integration service enabled
- Has **no GPU devices** attached (DDA or GPU-P)
- Is **not** a Trusted Launch VM
- Has all VM files located inside the cluster storage **GUID folder**

```powershell
# Verify the GUID folder — path must contain a 13+ hex character segment
Get-VM -Name <VMName> | Select-Object Name, ConfigurationLocation
```

Run a pre-flight check at any time:

```powershell
# Module
Test-VMHydrationPrerequisites -VMName 'WEBSRV01'

# Script
.\scripts\Test-VMHydrationPrerequisites.ps1 -VMName 'WEBSRV01'
```

---

## Which Operation to Use

| Scenario | Module cmdlet | Script |
| --- | --- | --- |
| VM is on this cluster, never registered with Azure | `Invoke-VMHydration` | `scripts/Invoke-VMHydration.ps1` |
| VM was registered with Azure but restored to a different cluster | `Invoke-VMReconnect` | `scripts/Invoke-VMReconnect.ps1` |

---

## Using the PowerShell Module

Install once from PSGallery:

```powershell
Install-Module AzureLocalVMHydration -Scope CurrentUser
```

See [Module Reference](module.md) for complete parameter documentation and examples for all three exported cmdlets.

---

## Using the Standalone Scripts

Run directly on a cluster node — no install required.

### VM Hydration

```powershell
.\scripts\Invoke-VMHydration.ps1 `
    -VMName        'WEBSRV01' `
    -ResourceGroup 'rg-azlocal-prod' `
    -CustomLocation '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<cl-name>' `
    -StoragePathId  '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/storageContainers/<name>' `
    -NicName       'WEBSRV01-nic1' `
    -SubnetId      'lnet-prod-vlan10' `
    -Location      'eastus'
```

**Dry run first:**

```powershell
.\scripts\Invoke-VMHydration.ps1 -VMName 'WEBSRV01' ... -WhatIf
```

#### Gen1 VMs

Add `-HyperVGeneration V1`. This uses the ARM REST API directly (the Azure CLI does not expose `hyperVGeneration`), and automatically disables vTPM and Secure Boot which are incompatible with Gen1:

```powershell
.\scripts\Invoke-VMHydration.ps1 -VMName 'LEGACYAPP' -HyperVGeneration V1 `
    -ResourceGroup 'rg-azlocal-prod' `
    -CustomLocation '...' -StoragePathId '...' `
    -NicName 'LEGACYAPP-nic1' -SubnetId 'lnet-prod-vlan10' -Location 'eastus'
```

---

### VM Reconnect

Run on a node of the **destination** cluster:

```powershell
.\scripts\Invoke-VMReconnect.ps1 `
    -VMName        'APPSRV01' `
    -LocalVMName   'APPSRV01_restored' `
    -ResourceGroup 'rg-azlocal-prod' `
    -CustomLocation '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<dest-cl-name>' `
    -NicName       'APPSRV01-nic2' `
    -SubnetId      'lnet-prod-vlan10' `
    -Location      'eastus' `
    -DataDiskLocalPaths @('C:\ClusterStorage\Volume1\<guid>\APPSRV01\data1.vhdx') `
    -DataDiskNames  @('APPSRV01-data1') `
    -RemoveSourceVM
```

!!! danger "If Reconnect Fails"
    **Do NOT delete the VM resource from the Azure portal or CLI.**
    A VM resource may be created in a failed state. Deleting it can destroy the original VM.
    Fix the root cause, then re-run `Invoke-VMReconnect` to repair it.

#### After Reconnect — NIC IP Configuration

- **SDN-enabled clusters:** The guest OS IP is configured automatically.
- **Non-SDN clusters:** Manually configure the IP inside the guest OS via RDP or VM Connect:

```powershell
New-NetIPAddress -InterfaceIndex <idx> -IPAddress <IP> -PrefixLength <len> -DefaultGateway <gw>
Set-DnsClientServerAddress -InterfaceIndex <idx> -ServerAddresses ('<dns>')
```

---

## Finding Your Custom Location and Storage Path IDs

**Custom Location ID:**

```powershell
az customlocation list --output table
# Copy the full 'id' value for your cluster's custom location
```

**Storage Path ID:**

```powershell
az stack-hci-vm storagepath list --resource-group <rg> --output table
# Copy the full 'id' value for the storage container you want to use
```
