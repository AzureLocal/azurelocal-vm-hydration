function Test-HydrationPrerequisites {
    <#
    .SYNOPSIS
        Runs all pre-flight checks and returns a list of failure messages.
    .PARAMETER VMName
        Hyper-V VM name to validate.
    .PARAMETER RequireRunning
        If set, the VM must be in Running state (required for reconnect).
    .PARAMETER SkipClusterCheck
        Skip the HA/cluster check for non-clustered test environments.
    .OUTPUTS
        [System.Collections.Generic.List[string]] — empty means all passed.
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
        $failures.Add("stack-hci-vm extension is missing or below 1.11.9. Upgrade: az extension add --upgrade --name stack-hci-vm --version 1.11.9")
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
        $failures.Add("VM '$VMName' not found in Hyper-V on this node.")
        return $failures
    }
    #endregion

    #region ── 3. VM Running State ────────────────────────────────────────────
    if ($RequireRunning) {
        Write-Step "Checking VM is in Running state"
        if ($vm.State -ne 'Running') {
            $failures.Add("VM '$VMName' must be Running before reconnect. Current state: $($vm.State).")
        } else {
            Write-OK "VM is Running"
        }
    }
    #endregion

    #region ── 4. Highly Available ───────────────────────────────────────────
    if (-not $SkipClusterCheck) {
        Write-Step "Checking VM is configured as Highly Available"
        try {
            $cr = Get-ClusterResource -ErrorAction Stop |
                Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.Name -like "*$VMName*" }
            if (-not $cr) {
                $failures.Add("VM '$VMName' is not HA in Failover Cluster Manager. Configure HA before proceeding.")
            } else {
                Write-OK "VM is HA-configured (cluster resource: $($cr.Name))"
            }
        } catch {
            Write-Warn "Could not check cluster state. Skipping HA check."
        }
    }
    #endregion

    #region ── 5. No GPU Attached ────────────────────────────────────────────
    Write-Step "Checking VM has no GPU attached (DDA or GPU-P)"
    try {
        $gpuDevices = Get-VMAssignableDevice -VMName $VMName -ErrorAction SilentlyContinue
        if ($gpuDevices) {
            $failures.Add("VM '$VMName' has $($gpuDevices.Count) DDA device(s) attached. Remove all GPUs before proceeding.")
        } else {
            Write-OK "No DDA GPU devices attached"
        }
    } catch {
        Write-Warn "Could not enumerate assignable devices. Verify no GPU is attached."
    }
    #endregion

    #region ── 6. Not a Trusted Launch VM ────────────────────────────────────
    Write-Step "Checking VM is not a Trusted Launch VM"
    $secureBootEnabled = (Get-VMFirmware -VMName $VMName -ErrorAction SilentlyContinue).SecureBoot -eq 'On'
    $vtpmEnabled       = (Get-VMSecurity -VMName $VMName -ErrorAction SilentlyContinue).TpmEnabled
    if ($secureBootEnabled -and $vtpmEnabled) {
        Write-Warn "VM has both Secure Boot and vTPM enabled. If this is a Trusted Launch VM, reconnect is not supported."
    } else {
        Write-OK "VM does not appear to be a Trusted Launch VM"
    }
    #endregion

    #region ── 7. KVP Integration Service ────────────────────────────────────
    Write-Step "Checking Hyper-V Data Exchange (KVP) integration service"
    try {
        $kvp = Get-VMIntegrationService -VMName $VMName -Name 'Key-Value Pair Exchange' -ErrorAction Stop
        if (-not $kvp.Enabled) {
            $failures.Add("KVP (Data Exchange) integration service is disabled on '$VMName'. Enable it in Hyper-V Manager > Integration Services.")
        } else {
            Write-OK "Data Exchange (KVP) integration service is enabled"
        }
    } catch {
        $failures.Add("Could not check KVP integration service on '$VMName': $_")
    }
    #endregion

    #region ── 8. Guest Service Interface ────────────────────────────────────
    Write-Step "Checking Hyper-V Guest Service Interface"
    try {
        $gsi = Get-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction Stop
        if (-not $gsi.Enabled) {
            $failures.Add("Guest Service Interface is disabled on '$VMName'. Enable it in Hyper-V Manager > Integration Services.")
        } else {
            Write-OK "Guest Service Interface is enabled"
        }
    } catch {
        $failures.Add("Could not check Guest Service Interface on '$VMName': $_")
    }
    #endregion

    #region ── 9. GUID Folder ─────────────────────────────────────────────────
    Write-Step "Checking VM configuration path is under a GUID folder"
    if (-not (Test-GuidFolderPath -Path $vm.ConfigurationLocation)) {
        $failures.Add("VM '$VMName' config path '$($vm.ConfigurationLocation)' is not under a GUID folder. Move VM files into the correct GUID subfolder.")
    } else {
        Write-OK "Configuration path is under a GUID folder: $($vm.ConfigurationLocation)"
    }
    #endregion

    #region ── 10. Backup Services (advisory) ────────────────────────────────
    Write-Step "Checking for backup services (advisory)"
    $running = @('VeeamBackupSvc', 'ArcasAgent', 'MSBackup', 'wbengine') | Where-Object {
        (Get-Service -Name $_ -ErrorAction SilentlyContinue)?.Status -eq 'Running'
    }
    if ($running) {
        Write-Warn "Backup service(s) detected: $($running -join ', '). Microsoft recommends no backup services run during reconnect."
    } else {
        Write-OK "No known backup services detected"
    }
    #endregion

    return $failures
}
