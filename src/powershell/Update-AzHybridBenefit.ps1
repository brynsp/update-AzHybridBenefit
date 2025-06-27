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

# Initialize logging
$logPath = Join-Path -Path $PSScriptRoot -ChildPath "AzHybridBenefit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$logEntries = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# Function to add log entry
function Add-LogEntry {
    param(
        [string]$VMName,
        [string]$ResourceGroup,
        [string]$Subscription,
        [string]$SubscriptionId,
        [string]$Applied,
        [string]$Status,
        [string]$Message
    )
    
    $entry = [PSCustomObject]@{
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        VMName         = $VMName
        ResourceGroup  = $ResourceGroup
        Subscription   = $Subscription
        SubscriptionId = $SubscriptionId
        Applied        = $Applied
        Status         = $Status
        Message        = $Message
    }
    
    $null = $logEntries.Add($entry)
}

# Get subscriptions
Write-Host "`n=== Starting Azure Hybrid Benefit Update Process ===" -ForegroundColor Cyan
Write-Host "Log file: $logPath" -ForegroundColor Gray
Write-Host "`nGetting subscriptions..." -ForegroundColor Yellow

try {
    if ($SubscriptionIds) {
        $subscriptions = $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
    }
    else {
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    }
    Write-Host "Found $($subscriptions.Count) subscriptions" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to get subscriptions - $_" -ForegroundColor Red
    Add-LogEntry -VMName "N/A" -ResourceGroup "N/A" -Subscription "N/A" -SubscriptionId "N/A" `
        -Applied "N/A" -Status "Error" -Message "Failed to get subscriptions: $_"
    throw
}

# Get all Windows VMs from all subscriptions
Write-Host "`nDiscovering Windows VMs across all subscriptions..." -ForegroundColor Yellow
$jobs = foreach ($sub in $subscriptions) {
    Write-Host "  - Scanning subscription: $($sub.Name)" -ForegroundColor Gray
    Start-Job -ScriptBlock {
        param($subId, $subName)
        Import-Module Az.Accounts, Az.Compute
        try {
            Set-AzContext -SubscriptionId $subId | Out-Null
            $vms = Get-AzVM -Status | Where-Object { $_.StorageProfile.OSDisk.OSType -eq 'Windows' }
            # Add subscription info to each VM object
            $vms | ForEach-Object {
                $_ | Add-Member -NotePropertyName 'SubscriptionName' -NotePropertyValue $subName -Force
                $_ | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $subId -Force
            }
            return $vms
        }
        catch {
            return [PSCustomObject]@{
                Error            = $true
                Message          = $_.Exception.Message
                SubscriptionName = $subName
                SubscriptionId   = $subId
            }
        }
    } -ArgumentList $sub.Id, $sub.Name
}

$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

# Add all VMs to a collection
$allVMs = [System.Collections.Generic.List[object]]::new()
foreach ($result in $results) {
    if ($result.Error) {
        Write-Host "  ERROR in subscription $($result.SubscriptionName): $($result.Message)" -ForegroundColor Red
        Add-LogEntry -VMName "N/A" -ResourceGroup "N/A" -Subscription $result.SubscriptionName `
            -SubscriptionId $result.SubscriptionId -Applied "N/A" -Status "Error" `
            -Message "Failed to get VMs: $($result.Message)"
    }
    elseif ($result) {
        $allVMs.Add($result)
    }
}

Write-Host "`nTotal Windows VMs found: $($allVMs.Count)" -ForegroundColor Cyan

# Process each VM in parallel - check and update license type
Write-Host "`nProcessing VMs for license updates..." -ForegroundColor Yellow
$jobCounter = 0
$jobs = foreach ($vm in $allVMs) {
    $jobCounter++
    Write-Host "  [$jobCounter/$($allVMs.Count)] Processing: $($vm.Name)" -ForegroundColor Gray
    
    Start-Job -ScriptBlock {
        param($vm, $logEntries)
        Import-Module Az.Accounts, Az.Compute, Az.SqlVirtualMachine

        # Set the context to the VM's subscription
        $subscriptionId = $vm.SubscriptionId
        $subscriptionName = $vm.SubscriptionName
        
        try {
            Set-AzContext -SubscriptionId $subscriptionId | Out-Null
            
            $appliedChanges = @()
            $statusMessages = @()
            $overallStatus = "Success"
            
            # Check to see if the OS license type is not 'Windows_Server'
            $licenseType = $vm.LicenseType
            if ($licenseType -ne 'Windows_Server') {
                try {
                    # Get the full VM object for update
                    $fullVm = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
                    $fullVm.LicenseType = 'Windows_Server'
                    $null = Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $fullVm
                    $appliedChanges += "OS"
                    $statusMessages += "OS license updated from '$licenseType' to 'Windows_Server'"
                }
                catch {
                    $overallStatus = "Partial Error"
                    $statusMessages += "Failed to update OS license: $_"
                }
            }
            else {
                $statusMessages += "OS license already set to 'Windows_Server'"
            }
            
            # Check to see if the VM also has SQL Server installed
            try {
                $sqlVm = Get-AzSqlVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop
                $sqlLicense = $sqlVm.SqlServerLicenseType
                    
                # Only update if not already AHUB or DR
                if ($sqlLicense -ne 'DR' -and $sqlLicense -ne 'AHUB') {
                    try {
                        $sqlVm.SqlServerLicenseType = 'AHUB'
                        $null = Update-AzSqlVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -LicenseType 'AHUB'
                        $appliedChanges += "SQL"
                        $statusMessages += "SQL license updated from '$sqlLicense' to 'AHUB'"
                    }
                    catch {
                        $overallStatus = "Partial Error"
                        $statusMessages += "Failed to update SQL license: $_"
                    }
                }
                else {
                    $statusMessages += "SQL license already set to '$sqlLicense'"
                }
            }
            catch {
                # SQL VM not found or error accessing - this is OK
                $statusMessages += "No SQL Server VM extension found"
            }
            
            # Prepare applied string
            $applied = if ($appliedChanges.Count -eq 0) { "None" } else { $appliedChanges -join "+" }
            
            # Create log entry
            $entry = [PSCustomObject]@{
                Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                VMName         = $vm.Name
                ResourceGroup  = $vm.ResourceGroupName
                Subscription   = $subscriptionName
                SubscriptionId = $subscriptionId
                Applied        = $applied
                Status         = $overallStatus
                Message        = $statusMessages -join "; "
            }
            
            return $entry
        }
        catch {
            # General error
            $entry = [PSCustomObject]@{
                Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                VMName         = $vm.Name
                ResourceGroup  = $vm.ResourceGroupName
                Subscription   = $subscriptionName
                SubscriptionId = $subscriptionId
                Applied        = "Error"
                Status         = "Error"
                Message        = "General error processing VM: $_"
            }
            
            return $entry
        }
    } -ArgumentList $vm, $logEntries
}

# Collect results
$processedCount = 0
$results = foreach ($job in $jobs) {
    $result = $job | Wait-Job | Receive-Job
    $job | Remove-Job
    
    if ($result) {
        $null = $logEntries.Add($result)
        $processedCount++
        
        # Display progress
        $color = switch ($result.Status) {
            "Success" { "Green" }
            "Partial Error" { "Yellow" }
            "Error" { "Red" }
            default { "Gray" }
        }
        Write-Host "  [$processedCount/$($allVMs.Count)] $($result.VMName): $($result.Applied) - $($result.Status)" -ForegroundColor $color
    }
}

# Export log to CSV
Write-Host "`nExporting results to CSV..." -ForegroundColor Yellow
try {
    # Select only the expected columns to ensure no extra data is included
    $logEntries | 
    Sort-Object Timestamp, VMName | 
    Select-Object Timestamp, VMName, ResourceGroup, Subscription, SubscriptionId, Applied, Status, Message | 
    Export-Csv -Path $logPath -NoTypeInformation
    Write-Host "Log file created: $logPath" -ForegroundColor Green
    
    # Summary statistics
    $summary = $logEntries | Group-Object Status
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    foreach ($group in $summary) {
        $color = switch ($group.Name) {
            "Success" { "Green" }
            "Partial Error" { "Yellow" }
            "Error" { "Red" }
            default { "Gray" }
        }
        Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
    }
    
    $appliedSummary = $logEntries | Where-Object { $_.Applied -ne "None" -and $_.Applied -ne "Error" } | Group-Object Applied
    if ($appliedSummary) {
        Write-Host "`n=== Changes Applied ===" -ForegroundColor Cyan
        foreach ($group in $appliedSummary) {
            Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "ERROR: Failed to export log file - $_" -ForegroundColor Red
}

Write-Host "`n=== Process Complete ===" -ForegroundColor Cyan
