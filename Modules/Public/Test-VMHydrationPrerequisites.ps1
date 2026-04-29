function Test-VMHydrationPrerequisites {
    <#
    .SYNOPSIS
        Validates all prerequisites for Azure Local VM hydration or reconnect operations.

    .DESCRIPTION
        Runs the full pre-flight checklist against a Hyper-V VM and reports pass/fail for
        each requirement. Returns $true if all checks pass, $false if any fail.

        Checks performed:
          1.  stack-hci-vm CLI extension >= 1.11.9
          2.  VM exists in Hyper-V on this node
          3.  VM is Running (if -RequireRunning)
          4.  VM is Highly Available in Failover Cluster Manager
          5.  No DDA GPU attached
          6.  Not a Trusted Launch VM
          7.  KVP (Data Exchange) integration service enabled
          8.  Guest Service Interface enabled
          9.  VM files are under a GUID folder
          10. No backup services running (advisory)

    .PARAMETER VMName
        Hyper-V VM name to validate.

    .PARAMETER RequireRunning
        If set, the VM must be in Running state. Required for reconnect operations.

    .PARAMETER SkipClusterCheck
        Skip the HA/Failover Cluster check for non-clustered test environments.

    .OUTPUTS
        [bool] — $true if all checks pass, $false if any fail.

    .EXAMPLE
        Test-VMHydrationPrerequisites -VMName 'WEBSRV01'

    .EXAMPLE
        Test-VMHydrationPrerequisites -VMName 'APPSRV01' -RequireRunning

    .NOTES
        Must be run as Administrator on one of the Azure Local cluster nodes.

        Install from PSGallery:
            Install-Module AzureLocalVMHydration -Scope CurrentUser
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [switch]$RequireRunning,

        [switch]$SkipClusterCheck
    )

    Assert-AdminElevation -FunctionName 'Test-VMHydrationPrerequisites'

    $failures = Test-HydrationPrerequisites -VMName $VMName -RequireRunning:$RequireRunning -SkipClusterCheck:$SkipClusterCheck

    if ($failures.Count -gt 0) {
        Write-Host "`n  Pre-flight check failed with $($failures.Count) issue(s):`n" -ForegroundColor Red
        foreach ($f in $failures) { Write-Fail $f }
        Write-Host ""
        return $false
    }

    Write-OK "All pre-flight checks passed for VM '$VMName'"
    return $true
}
