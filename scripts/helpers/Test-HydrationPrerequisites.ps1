<#
.SYNOPSIS
    Validates all prerequisites for Azure Local VM hydration and reconnect operations.
.NOTES
    Dot-sourced by Invoke-VMHydration.ps1 and Invoke-VMReconnect.ps1.
    Requires Common-Functions.ps1 to already be dot-sourced (for Write-* helpers).

    Prerequisites are sourced from the Microsoft Private Preview doc:
    reference/AzureLocalVMReconnectPrivatePreview_02232026.md — Step 1.
#>

function Test-HydrationPrerequisites {
    <#
    .SYNOPSIS
        Runs all pre-flight checks and returns a list of failures.
    .PARAMETER VMName
        Hyper-V VM name to validate.
    .PARAMETER RequireRunning
        If set, the VM must be in a Running state (required for reconnect; optional for hydration).
    .PARAMETER SkipClusterCheck
        Skip the HA/cluster check (use when running outside a cluster environment for testing).
    .OUTPUTS
        [System.Collections.Generic.List[string]] — list of failure messages. Empty = all passed.
    .EXAMPLE
        $failures = Test-HydrationPrerequisites -VMName 'MyVM' -RequireRunning
        if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Fail $_ }; exit 1 }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,
        [switch]$RequireRunning,
        [switch]$SkipClusterCheck
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    #region ── 1. stack-hci-vm Extension Version ──────────────────────────────

    Write-Step "Checking stack-hci-vm CLI extension version (>= 1.11.9)"

    if (-not (Test-AzCliExtensionVersion -MinVersion '1.11.9')) {
        $failures.Add("stack-hci-vm extension is missing or below version 1.11.9. Upgrade with: az extension add --upgrade --name stack-hci-vm --version 1.11.9")
    } else {
        Write-OK "stack-hci-vm extension >= 1.11.9"
    }

    #endregion

    #region ── 2. VM Exists in Hyper-V ───────────────────────────────────────

    Write-Step "Checking VM '$VMName' exists in Hyper-V"

    $vm = $null
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        Write-OK "VM found (State: $($vm.State), Generation: $($vm.Generation))"
    } catch {
        $failures.Add("VM '$VMName' not found in Hyper-V on this node. Ensure you are running on the correct cluster node.")
        return $failures  # Cannot continue without a VM object
    }

    #endregion

    #region ── 3. VM Running State ────────────────────────────────────────────

    if ($RequireRunning) {
        Write-Step "Checking VM is in Running state"
        if ($vm.State -ne 'Running') {
            $failures.Add("VM '$VMName' must be in Running state before reconnect. Current state: $($vm.State). Start the VM and try again.")
        } else {
            Write-OK "VM is Running"
        }
    }

    #endregion

    #region ── 4. VM is Highly Available ─────────────────────────────────────

    if (-not $SkipClusterCheck) {
        Write-Step "Checking VM is configured as a Highly Available (HA) VM"
        try {
            $clusterResource = Get-ClusterResource -ErrorAction Stop |
                Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.Name -like "*$VMName*" }
            if (-not $clusterResource) {
                $failures.Add("VM '$VMName' is not configured as an HA VM in Failover Cluster Manager. Most backup tools restore as standard Hyper-V VMs — configure HA before proceeding.")
            } else {
                Write-OK "VM is HA-configured (cluster resource: $($clusterResource.Name))"
            }
        } catch {
            Write-Warn "Could not check cluster state (FailoverClusters module unavailable or not running on a cluster node). Skipping HA check."
        }
    }

    #endregion

    #region ── 5. No GPU Attached ────────────────────────────────────────────

    Write-Step "Checking VM has no GPU attached (DDA or GPU-P)"

    try {
        $gpuDevices = Get-VMAssignableDevice -VMName $VMName -ErrorAction SilentlyContinue
        if ($gpuDevices) {
            $failures.Add("VM '$VMName' has $($gpuDevices.Count) DDA device(s) attached. Remove all GPUs before hydration/reconnect.")
        } else {
            Write-OK "No DDA GPU devices attached"
        }
    } catch {
        Write-Warn "Could not enumerate assignable devices. If this VM has a GPU, remove it before proceeding."
    }

    #endregion

    #region ── 6. Not a Trusted Launch VM ────────────────────────────────────

    Write-Step "Checking VM is not a Trusted Launch VM (TVM)"

    # TVM detection: check for vTPM + Secure Boot both enabled on a VM that is NOT Gen2-native
    # TVMs are identified by specific firmware settings; Hyper-V doesn't expose a direct TVM flag
    # Best approximation: warn if both vTPM and Secure Boot are enabled AND VM was imported/restored
    $secureBootEnabled = (Get-VMFirmware -VMName $VMName -ErrorAction SilentlyContinue).SecureBoot -eq 'On'
    $vtpmEnabled       = (Get-VMSecurity -VMName $VMName -ErrorAction SilentlyContinue).TpmEnabled

    if ($secureBootEnabled -and $vtpmEnabled) {
        Write-Warn "VM has both Secure Boot and vTPM enabled. If this is a Trusted Launch VM (TVM), reconnect is not supported. Verify this is a standard Gen2 VM before proceeding."
    } else {
        Write-OK "VM does not appear to be a Trusted Launch VM"
    }

    #endregion

    #region ── 7. KVP (Data Exchange) Integration Service Enabled ────────────

    Write-Step "Checking Hyper-V Data Exchange (KVP) integration service is enabled"

    try {
        $kvp = Get-VMIntegrationService -VMName $VMName -Name 'Key-Value Pair Exchange' -ErrorAction Stop
        if (-not $kvp.Enabled) {
            $failures.Add("Hyper-V Data Exchange Service (KVP) is disabled on VM '$VMName'. Enable it in Hyper-V Manager under VM Settings > Integration Services > Data Exchange.")
        } else {
            Write-OK "Data Exchange (KVP) integration service is enabled"
        }
    } catch {
        $failures.Add("Could not check KVP integration service on VM '$VMName': $_")
    }

    #endregion

    #region ── 8. Guest Service Interface Enabled ────────────────────────────

    Write-Step "Checking Hyper-V Guest Service Interface is enabled"

    try {
        $gsi = Get-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction Stop
        if (-not $gsi.Enabled) {
            $failures.Add("Hyper-V Guest Service Interface is disabled on VM '$VMName'. Enable it in Hyper-V Manager under VM Settings > Integration Services > Guest Service Interface.")
        } else {
            Write-OK "Guest Service Interface is enabled"
        }
    } catch {
        $failures.Add("Could not check Guest Service Interface on VM '$VMName': $_")
    }

    #endregion

    #region ── 9. VM Files in GUID Folder ────────────────────────────────────

    Write-Step "Checking VM configuration path is under a GUID folder"

    $configLocation = $vm.ConfigurationLocation
    if (-not (Test-GuidFolderPath -Path $configLocation)) {
        $failures.Add("VM '$VMName' configuration location '$configLocation' is not under a GUID folder (e.g. C:\ClusterStorage\Volume1\e21794969177373\). Move all VM files into the correct GUID subfolder before proceeding. See: reference/AzureLocalVMReconnectPrivatePreview_02232026.md — Step 1, item 7.")
    } else {
        Write-OK "Configuration path is under a GUID folder: $configLocation"
    }

    #endregion

    #region ── 10. No Backup Service Running (Warn Only) ─────────────────────

    Write-Step "Checking for backup services running on cluster nodes (advisory)"

    $backupServices = @('VeeamBackupSvc', 'ArcasAgent', 'MSBackup', 'wbengine')
    $running = $backupServices | Where-Object {
        (Get-Service -Name $_ -ErrorAction SilentlyContinue)?.Status -eq 'Running'
    }

    if ($running) {
        Write-Warn "Backup service(s) detected as running: $($running -join ', '). Microsoft recommends no backup services run on cluster nodes during VM reconnect."
    } else {
        Write-OK "No known backup services detected"
    }

    #endregion

    return $failures
}
