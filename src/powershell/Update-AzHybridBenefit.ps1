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
$jobs = foreach ($sub in $subscriptions) {
    Start-Job -ScriptBlock {
        param($subId)
        Import-Module Az.Accounts, Az.Compute
        Set-AzContext -SubscriptionId $subId | Out-Null
        Get-AzVM -Status | Where-Object { $_.StorageProfile.OSDisk.OSType -eq 'Windows' }
    } -ArgumentList $sub.Id
}

$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

# Add all VMs to a collection
$allVMs = [System.Collections.Generic.List[object]]::new()
foreach ($vm in $results) {
    if ($vm) {
        $allVMs.Add($vm)
    }
}

Write-Host "Total Windows VMs: $($allVMs.Count)" -ForegroundColor Cyan

# Process each VM in parallel - check and update license type
$jobs = foreach ($vm in $allVMs) {
    Start-Job -ScriptBlock {
        param($vm)
        Import-Module Az.Accounts, Az.Compute, Az.SqlVirtualMachine

        # Set the context to the VM's subscription
        $subscriptionId = $vm.Id.Split('/')[2]
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null

        # Check to see if the OS license type is not 'Windows_Server'
        $licenseType = $vm.LicenseType
        if ($licenseType -ne 'Windows_Server') {
            # Get the full VM object for update
            $fullVm = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
            $fullVm.LicenseType = 'Windows_Server'
            $null = Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $fullVm
        }
        
        # Check to see if the VM also has SQL Server installed
        $sqlVm = Get-AzSqlVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction SilentlyContinue
        if ($sqlVm) {
            $sqlLicense = $sqlVm.SqlServerLicenseType
                
            # Only update if not already AHUB or DR
            if ($sqlLicense -ne 'DR' -and $sqlLicense -ne 'AHUB') {
                $sqlVm.SqlServerLicenseType = 'AHUB'
                $null = Update-AzSqlVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -LicenseType 'AHUB'
            }
        }
    } -ArgumentList $vm
}

$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
