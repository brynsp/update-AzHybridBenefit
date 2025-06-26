<#
.SYNOPSIS
    Applies Azure Hybrid Use Benefit (AHUB) to Windows and SQL Server VMs across subscriptions.

.PARAMETER SubscriptionIds
    Array of subscription IDs to process. If not specified, processes all enabled subscriptions.
#>

#requires -Modules Az.Accounts, Az.Compute, Az.SqlVirtualMachine
#requires -Version 7.5

[CmdletBinding()]
param(
    [string[]]$SubscriptionIds
)

# Get subscriptions
Write-Host 'Getting subscriptions…' -ForegroundColor Yellow
if ($SubscriptionIds) {
    $subscriptions = $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
}
else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}

Write-Host "Found $($subscriptions.Count) subscriptions" -ForegroundColor Green


# Get all Windows VMs from all subscriptions
Write-Host 'Discovering Windows VMs…' -ForegroundColor Yellow
$allVMs = [System.Collections.Generic.List[object]]::new()

$jobs = foreach ($sub in $subscriptions) {
    Start-Job -ScriptBlock {
        param($subId)
        Import-Module Az.Accounts, Az.Compute
        Set-AzContext -SubscriptionId $subId | Out-Null
        Get-AzVM | Where-Object { $_.StorageProfile.OSDisk.OSType -eq 'Windows' }
    } -ArgumentList $sub.Id
}

$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

# Add all VMs to the collection
foreach ($vm in $results) {
    if ($vm) {
        $allVMs.Add($vm)
    }
}

Write-Host "Total Windows VMs: $($allVMs.Count)" -ForegroundColor Cyan
