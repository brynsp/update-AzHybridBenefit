# Update-AzHybridBenefit

A PowerShell script to automatically apply Azure Hybrid Use Benefit (AHUB) licensing to Windows Server and SQL Server VMs across Azure subscriptions.

## Overview

This script helps organizations that have existing Microsoft license agreements (Enterprise Agreement, MPSA, or other volume licensing) to convert their Azure VMs from Pay-As-You-Go (PAYG) licensing to Azure Hybrid Use Benefit (AHUB), potentially saving significant costs on their Azure bills.

### What is Azure Hybrid Use Benefit?

Azure Hybrid Use Benefit allows customers with Software Assurance or qualifying subscriptions to use their on-premises Windows Server and SQL Server licenses in Azure, effectively removing the licensing cost from the VM pricing and paying only for the base compute rate.

## Features

- **Bulk Processing**: Automatically processes multiple VMs across multiple subscriptions
- **Parallel Execution**: Uses PowerShell parallel processing for efficient handling of large environments
- **Selective Updates**: Can update OS licenses, SQL licenses, or both
- **Safe Operation**:
  - Skips VMs already configured with AHUB
  - Preserves SQL Server DR (Disaster Recovery) licensing
  - Only affects Windows VMs
- **Comprehensive Logging**: Exports detailed CSV logs of all operations
- **Error Handling**: Robust error handling with retry logic for transient issues

## Prerequisites

- **PowerShell 7.5** or higher
- **Azure PowerShell Modules**:
  - Az.Accounts
  - Az.Compute
  - Az.SqlVirtualMachine
- **Azure Permissions**: Contributor or Owner role on target subscriptions
- **Valid Licenses**: Appropriate Microsoft licensing agreements that qualify for Azure Hybrid Use Benefit

## Installation

1. Clone or download this repository:

```bash
git clone https://github.com/brynsp/update-AzHybridBenefit.git
```

2. Ensure you have the required PowerShell modules installed:

```powershell
Install-Module -Name Az.Accounts, Az.Compute, Az.SqlVirtualMachine -Scope CurrentUser
```

3. Connect to Azure:

```powershell
Connect-AzAccount
```

## Usage

### Basic Usage

Process all Windows VMs in all accessible subscriptions:

```powershell
.\src\powershell\Update-AzHybridBenefit.ps1
```

### Process Specific Subscriptions

```powershell
.\src\powershell\Update-AzHybridBenefit.ps1 -SubscriptionIds @("00000000-0000-0000-0000-000000000000", "11111111-1111-1111-1111-111111111111")
```

### Update Only OS Licenses

```powershell
.\src\powershell\Update-AzHybridBenefit.ps1 -Mode OS
```

### Update Only SQL Server Licenses

```powershell
.\src\powershell\Update-AzHybridBenefit.ps1 -Mode SQL
```

### Increase Parallel Processing

```powershell
.\src\powershell\Update-AzHybridBenefit.ps1 -ThrottleLimit 20
```

## Parameters

| Parameter | Description | Default | Valid Values |
|-----------|-------------|---------|--------------|
| **SubscriptionIds** | Array of subscription IDs to process | All enabled subscriptions | Valid Azure subscription GUIDs |
| **Mode** | Which licenses to update | Both | OS, SQL, Both |
| **ThrottleLimit** | Maximum parallel operations | 10 | 1-50 |

## What the Script Does

1. **Discovery Phase**:
   - Identifies all enabled Azure subscriptions (or uses specified ones)
   - Discovers all Windows VMs in those subscriptions
   - Retrieves current licensing status

2. **Processing Phase**:
   - For each Windows VM:
     - **OS License**: Updates from PAYG to "Windows_Server" AHUB if not already set
     - **SQL License**: Updates from PAYG to "AHUB" if SQL Server is installed and not using DR licensing

3. **Logging Phase**:
   - Creates a timestamped CSV file with detailed results
   - Shows summary statistics of changes applied

## Important Notes

### License Compliance

⚠️ **WARNING**: Before running this script, ensure you have:

- Valid Windows Server licenses with Software Assurance for the number of cores you're licensing
- Valid SQL Server licenses with Software Assurance for SQL VMs
- Reviewed and understand Microsoft's licensing terms for Azure Hybrid Use Benefit

### What Gets Skipped

- Non-Windows VMs (Linux VMs are not affected)
- Disabled subscriptions
- VMs already configured with AHUB
- SQL Server VMs configured with DR (Disaster Recovery) licensing
- VMs without SQL Server when running in SQL-only mode

### Cost Savings

Applying Azure Hybrid Use Benefit can save:

- Up to 40% on Windows Server VMs
- Up to 55% on SQL Server VMs

## Output

The script creates a CSV log file with the following information:

- **Timestamp**: When the VM was processed
- **VMName**: Name of the virtual machine
- **ResourceGroup**: Resource group containing the VM
- **Subscription**: Subscription name
- **SubscriptionId**: Subscription GUID
- **Applied**: What changes were applied (None, OS, SQL, OS+SQL)
- **Status**: Success, Partial Error, or Error
- **Message**: Detailed status messages

Example output:

```text
=== Starting Azure Hybrid Benefit Update Process ===
Log file: C:\Scripts\AzHybridBenefit_20240115_143022.csv

Getting subscriptions…
Found 3 subscriptions

Discovering Windows VMs across all subscriptions…
Total Windows VMs found: 15

Processing VMs for license updates…
  [1/15] WebServer01: OS - Success
  [2/15] SQLServer01: OS+SQL - Success
  [3/15] AppServer01: None - Success
  ...

=== Summary ===
  Success: 12
  Partial Error: 2
  Error: 1

=== Changes Applied ===
  OS: 5
  SQL: 3
  OS+SQL: 4

=== Process Complete ===
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**
   - Ensure you're logged into Azure: `Connect-AzAccount`
   - Verify you have appropriate permissions on the subscriptions

2. **Module Not Found**
   - Install required modules: `Install-Module -Name Az.Accounts, Az.Compute, Az.SqlVirtualMachine`

3. **VMs Not Found**
   - Check that subscriptions are enabled
   - Verify you have access to the subscriptions
   - Ensure VMs are Windows-based

4. **SQL License Not Applied**
   - VM might not have SQL Server installed
   - SQL VM extension might not be installed
   - VM might be powered off

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Disclaimer

This script is provided as-is. Always test in a non-production environment first. Ensure you comply with Microsoft licensing terms and have valid licenses before applying Azure Hybrid Use Benefit.

## Author

**Bryn Spears**  
<bryn.spears@hotmail.com>

Last Updated: July 2025
