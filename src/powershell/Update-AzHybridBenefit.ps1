<#
.SYNOPSIS
    Applies Azure Hybrid Use Benefit (AHUB) to Windows and SQL Server VMs across subscriptions.

.DESCRIPTION
    This script applies Azure Hybrid Use Benefit licensing to Windows OS and SQL Server VMs across one or more Azure subscriptions. It processes VMs in parallel for efficiency and logs all operations to a CSV file.

.PARAMETER SubscriptionIds
    Array of subscription IDs to process. If not specified, processes all enabled subscriptions.

.EXAMPLE
    .\Update-AzHybridBenefit.ps1
    Processes all Windows VMs in all enabled subscriptions.

.EXAMPLE
    .\Update-AzHybridBenefit.ps1 -SubscriptionIds "00000000-0000-0000-0000-000000000000","11111111-1111-1111-1111-111111111111"
    Processes only Windows VMs in the specified subscriptions.

.NOTES
    Author: YourName
    Last Updated: June 27, 2025
    Requires PowerShell 7+ and Az PowerShell modules (Az.Accounts, Az.Compute, Az.SqlVirtualMachine)
#>

#requires -Modules Az.Accounts, Az.Compute, Az.SqlVirtualMachine
#requires -Version 7.5

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = 'Array of subscription IDs to process')]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string[]]
    $SubscriptionIds,

    [Parameter(Mandatory = $false, HelpMessage = 'Parallel throttle limit for VM operations')]
    [ValidateRange(1, 50)]
    [int]
    $ThrottleLimit = 10,

    [Parameter(Mandatory = $false, HelpMessage = 'Which license(s) to update: OS, SQL, or Both')]
    [ValidateSet('OS', 'SQL', 'Both')]
    [string]
    $Mode = 'Both'
)

#region Constants
Set-StrictMode -Version 3.0
$WINDOWS_LICENSE_TYPE = 'Windows_Server'
$SQL_LICENSE_TYPE = 'AHUB'
$DR_LICENSE_TYPE = 'DR'
#endregion

function Get-TargetSubscriptions {
    param([string[]]$SubscriptionIds)

    if ($SubscriptionIds) {
        $allRequestedSubs = @()
        $enabledSubs = @()
        
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                $allRequestedSubs += $sub
                
                if ($sub.State -eq 'Enabled') {
                    $enabledSubs += $sub
                }
                else {
                    Write-Warning "Subscription '$($sub.Name)' (ID: $subId) is in state '$($sub.State)' and will be skipped"
                }
            }
            catch {
                Write-Warning "Failed to get subscription with ID '$subId': $($_.Exception.Message)"
            }
        }
        
        if ($enabledSubs.Count -eq 0) {
            Write-Warning 'No enabled subscriptions found among the specified IDs'
        }
        elseif ($enabledSubs.Count -lt $allRequestedSubs.Count) {
            Write-Host "Processing $($enabledSubs.Count) of $($allRequestedSubs.Count) requested subscriptions" -ForegroundColor Yellow
        }
        
        return $enabledSubs
    }
    else {
        return Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    }
}

function Get-WindowsVMInventory {
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions,
        [Parameter(Mandatory = $false)]
        [int]$ThrottleLimit = 10
    )
    $syncedResults = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $Subscriptions | ForEach-Object -Parallel {
        Import-Module Az.Accounts, Az.Compute -Force
        $sub = $_
        $results = $using:syncedResults
        try {
            $null = Set-AzContext -SubscriptionId $sub.Id
            $vms = Get-AzVM -Status | Where-Object { $_.StorageProfile.OSDisk.OSType -eq 'Windows' }
            foreach ($vm in $vms) {
                $null = $vm | Add-Member -NotePropertyName 'SubscriptionName' -NotePropertyValue $sub.Name -Force
                $null = $vm | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $sub.Id -Force
                $results.Add($vm)
            }
        }
        catch {
            $errorObj = [PSCustomObject]@{
                Error            = $true
                Message          = $PSItem.Exception.Message
                SubscriptionName = $sub.Name
                SubscriptionId   = $sub.Id
            }
            $results.Add($errorObj)
        }
    } -ThrottleLimit $ThrottleLimit
    return $syncedResults
}

function Set-HybridBenefitOnVM {
    param(
        [Parameter(Mandatory)]
        [object]$VM,
        [Parameter(Mandatory = $false)]
        [ValidateSet('OS', 'SQL', 'Both')]
        [string]$Mode = 'Both'
    )
    Import-Module Az.Accounts, Az.Compute, Az.SqlVirtualMachine -Force
    $subscriptionId = $VM.SubscriptionId
    $subscriptionName = $VM.SubscriptionName
    $appliedChanges = [System.Collections.Generic.List[string]]::new()
    $statusMessages = [System.Collections.Generic.List[string]]::new()
    $overallStatus = 'Success'
    try {
        $null = Set-AzContext -SubscriptionId $subscriptionId
        # OS License
        if ($Mode -eq 'OS' -or $Mode -eq 'Both') {
            $licenseType = $VM.LicenseType
            if ($licenseType -ne $WINDOWS_LICENSE_TYPE) {
                try {
                    $fullVm = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name
                    $fullVm.LicenseType = $WINDOWS_LICENSE_TYPE
                    $null = Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $fullVm
                    $appliedChanges.Add('OS')
                    $statusMessages.Add("OS license updated from '$licenseType' to '$WINDOWS_LICENSE_TYPE'")
                }
                catch {
                    $overallStatus = 'Partial Error'
                    $statusMessages.Add("Failed to update OS license: $($PSItem.Exception.Message)")
                }
            }
            else {
                $statusMessages.Add("OS license already set to '$WINDOWS_LICENSE_TYPE'")
            }
        }
        # SQL License
        if ($Mode -eq 'SQL' -or $Mode -eq 'Both') {
            try {
                $sqlVm = Get-AzSqlVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ErrorAction Stop
                $sqlLicense = $sqlVm.SqlServerLicenseType
                if ($sqlLicense -ne $DR_LICENSE_TYPE -and $sqlLicense -ne $SQL_LICENSE_TYPE) {
                    try {
                        $sqlVm.SqlServerLicenseType = $SQL_LICENSE_TYPE
                        $updateAzSqlVMParams = @{
                            ResourceGroupName = $VM.ResourceGroupName
                            Name              = $VM.Name
                            LicenseType       = $SQL_LICENSE_TYPE
                        }
                        $null = Update-AzSqlVM @updateAzSqlVMParams
                        $appliedChanges.Add('SQL')
                        $statusMessages.Add("SQL license updated from '$sqlLicense' to '$SQL_LICENSE_TYPE'")
                    }
                    catch {
                        $overallStatus = 'Partial Error'
                        $statusMessages.Add("Failed to update SQL license: $($PSItem.Exception.Message)")
                    }
                }
                else {
                    $statusMessages.Add("SQL license already set to '$sqlLicense'")
                }
            }
            catch {
                $statusMessages.Add('No SQL Server VM extension found')
            }
        }
        $applied = if ($appliedChanges.Count -eq 0) { 'None' } else { $appliedChanges -join "+" }
        return [PSCustomObject]@{
            Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            VMName         = $VM.Name
            ResourceGroup  = $VM.ResourceGroupName
            Subscription   = $subscriptionName
            SubscriptionId = $subscriptionId
            Applied        = $applied
            Status         = $overallStatus
            Message        = $statusMessages -join "; "
        }
    }
    catch {
        return [PSCustomObject]@{
            Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            VMName         = $VM.Name
            ResourceGroup  = $VM.ResourceGroupName
            Subscription   = $subscriptionName
            SubscriptionId = $subscriptionId
            Applied        = 'Error'
            Status         = 'Error'
            Message        = "General error processing VM: $($PSItem.Exception.Message)"
        }
    }
}

function Invoke-AzHybridBenefitUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        [Parameter(Mandatory = $false)]
        [int]$ThrottleLimit = 10,
        [Parameter(Mandatory = $false)]
        [ValidateSet('OS', 'SQL', 'Both')]
        [string]$Mode = 'Both'
    )

    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "AzHybridBenefit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    
    Write-Host '`n=== Starting Azure Hybrid Benefit Update Process ===' -ForegroundColor Cyan
    Write-Host "Log file: $logPath" -ForegroundColor Gray
    Write-Host '`nGetting subscriptions… ' -ForegroundColor Yellow
    
    try {
        $subscriptions = Get-TargetSubscriptions -SubscriptionIds $SubscriptionIds
        Write-Host "Found $($subscriptions.Count) subscriptions" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Failed to get subscriptions - $($PSItem.Exception.Message)" -ForegroundColor Red
        return
    }

    Write-Host '`nDiscovering Windows VMs across all subscriptions… ' -ForegroundColor Yellow
    
    $allVMs = Get-WindowsVMInventory -Subscriptions $subscriptions -ThrottleLimit $ThrottleLimit
    $vmErrors = $allVMs | Where-Object { $_.Error }
    foreach ($err in $vmErrors) {
        Write-Host "  ERROR in subscription $($err.SubscriptionName): $($err.Message)" -ForegroundColor Red
    }
    $targetVMs = $allVMs | Where-Object { -not $_.Error }
    Write-Host "`nTotal Windows VMs found: $($targetVMs.Count)" -ForegroundColor Cyan
    Write-Host '`nProcessing VMs for license updates… ' -ForegroundColor Yellow
    $results = $targetVMs | ForEach-Object -Parallel {
        Set-HybridBenefitOnVM -VM $_ -Mode $using:Mode
    } -ThrottleLimit $ThrottleLimit

    $processedCount = 0
    foreach ($result in $results) {
        $processedCount++
        $color = switch ($result.Status) {
            'Success' { 'Green' }
            'Partial Error' { 'Yellow' }
            'Error' { 'Red' }
            default { 'Gray' }
        }
        Write-Host "  [$processedCount/$($targetVMs.Count)] $($result.VMName): $($result.Applied) - $($result.Status)" -ForegroundColor $color
    }

    Write-Host '`nExporting results to CSV… ' -ForegroundColor Yellow
    
    try {
        $results | Sort-Object Timestamp, VMName |
        Select-Object Timestamp, VMName, ResourceGroup, Subscription, SubscriptionId, Applied, Status, Message |
        Export-Csv -Path $logPath -NoTypeInformation

        Write-Host "Log file created: $logPath" -ForegroundColor Green
        
        $summary = $results | Group-Object Status
        Write-Host '`n=== Summary ===' -ForegroundColor Cyan
        foreach ($group in $summary) {
            $color = switch ($group.Name) {
                'Success' { 'Green' }
                'Partial Error' { 'Yellow' }
                'Error' { 'Red' }
                default { 'Gray' }
            }
            Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
        }

        $appliedSummary = $results | Where-Object { $_.Applied -ne 'None' -and $_.Applied -ne 'Error' } | Group-Object Applied
        if ($appliedSummary) {
            Write-Host '`n=== Changes Applied ===' -ForegroundColor Cyan
            foreach ($group in $appliedSummary) {
                Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "ERROR: Failed to export log file - $($PSItem.Exception.Message)" -ForegroundColor Red
    }

    Write-Host '`n=== Process Complete ===' -ForegroundColor Cyan
}

# Entry point - only execute if script is run directly, not dot sourced
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AzHybridBenefitUpdate -SubscriptionIds $SubscriptionIds -ThrottleLimit $ThrottleLimit -Mode $Mode
}
