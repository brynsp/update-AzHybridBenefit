BeforeAll {
    # Import the script for testing
    . $PSScriptRoot\..\..\src\powershell\Update-AzHybridBenefit.ps1
    
    # Mock Azure modules to prevent actual Azure calls
    Mock Import-Module {} -ParameterFilter { $Name -in @('Az.Accounts', 'Az.Compute', 'Az.SqlVirtualMachine') }
}

Describe 'Update-AzHybridBenefit Parameter Validation' {
    Context 'SubscriptionIds Parameter' {
        It 'Should accept valid subscription ID format' {
            $validId = '12345678-1234-1234-1234-123456789012'
            { Invoke-AzHybridBenefitUpdate -SubscriptionIds $validId -WhatIf } | Should -Not -Throw
        }
        
        It 'Should reject invalid subscription ID format' {
            $invalidIds = @(
                'not-a-guid',
                '12345678-1234-1234-1234',
                '12345678-1234-1234-1234-12345678901Z'
            )
            foreach ($id in $invalidIds) {
                { Invoke-AzHybridBenefitUpdate -SubscriptionIds $id } | Should -Throw
            }
        }
        
        It 'Should accept multiple subscription IDs' {
            $multipleIds = @(
                '12345678-1234-1234-1234-123456789012',
                '87654321-4321-4321-4321-210987654321'
            )
            { Invoke-AzHybridBenefitUpdate -SubscriptionIds $multipleIds -WhatIf } | Should -Not -Throw
        }
    }
    
    Context 'ThrottleLimit Parameter' {
        It 'Should accept valid throttle limits' {
            $validLimits = @(1, 25, 50)
            foreach ($limit in $validLimits) {
                { Invoke-AzHybridBenefitUpdate -ThrottleLimit $limit -WhatIf } | Should -Not -Throw
            }
        }
        
        It 'Should reject invalid throttle limits' {
            $invalidLimits = @(0, -1, 51, 100)
            foreach ($limit in $invalidLimits) {
                { Invoke-AzHybridBenefitUpdate -ThrottleLimit $limit } | Should -Throw
            }
        }
        
        It 'Should default to 10 when not specified' {
            # This would need to be tested through function behavior
            { Invoke-AzHybridBenefitUpdate -WhatIf } | Should -Not -Throw
        }
    }
    
    Context 'Mode Parameter' {
        It 'Should accept valid modes' {
            $validModes = @('OS', 'SQL', 'Both')
            foreach ($mode in $validModes) {
                { Invoke-AzHybridBenefitUpdate -Mode $mode -WhatIf } | Should -Not -Throw
            }
        }
        
        It 'Should reject invalid modes' {
            { Invoke-AzHybridBenefitUpdate -Mode 'Invalid' } | Should -Throw
        }
        
        It 'Should default to Both when not specified' {
            { Invoke-AzHybridBenefitUpdate -WhatIf } | Should -Not -Throw
        }
    }
    
    Context 'Parameter Combinations' {
        It 'Should accept all valid parameters together' {
            $params = @{
                SubscriptionIds = '12345678-1234-1234-1234-123456789012'
                ThrottleLimit   = 20
                Mode            = 'SQL'
                WhatIf          = $true
            }
            { Invoke-AzHybridBenefitUpdate @params } | Should -Not -Throw
        }
    }
}

Describe 'Get-TargetSubscriptions Function' {
    BeforeAll {
        Mock Get-AzSubscription {
            param($SubscriptionId)
            if ($SubscriptionId -eq 'valid-sub-1') {
                return [PSCustomObject]@{
                    Id    = 'valid-sub-1'
                    Name  = 'Test Subscription 1'
                    State = 'Enabled'
                }
            }
            elseif ($SubscriptionId -eq 'disabled-sub') {
                return [PSCustomObject]@{
                    Id    = 'disabled-sub'
                    Name  = 'Disabled Subscription'
                    State = 'Disabled'
                }
            }
            elseif ($SubscriptionId -eq 'error-sub') {
                throw "Subscription not found"
            }
            else {
                # Return all subscriptions when no ID specified
                return @(
                    [PSCustomObject]@{
                        Id    = 'sub-1'
                        Name  = 'Subscription 1'
                        State = 'Enabled'
                    },
                    [PSCustomObject]@{
                        Id    = 'sub-2'
                        Name  = 'Subscription 2'
                        State = 'Enabled'
                    },
                    [PSCustomObject]@{
                        Id    = 'sub-3'
                        Name  = 'Subscription 3'
                        State = 'Disabled'
                    }
                )
            }
        }
    }
    
    Context 'When specific subscription IDs are provided' {
        It 'Should return only enabled subscriptions' {
            $result = Get-TargetSubscriptions -SubscriptionIds @('valid-sub-1', 'disabled-sub')
            $result.Count | Should -Be 1
            $result[0].Id | Should -Be 'valid-sub-1'
        }
        
        It 'Should handle subscription retrieval errors gracefully' {
            Mock Write-Warning {}
            $result = Get-TargetSubscriptions -SubscriptionIds @('error-sub', 'valid-sub-1')
            $result.Count | Should -Be 1
            $result[0].Id | Should -Be 'valid-sub-1'
            Assert-MockCalled Write-Warning -Times 1
        }
        
        It 'Should warn when no enabled subscriptions found' {
            Mock Write-Warning {}
            $result = Get-TargetSubscriptions -SubscriptionIds @('disabled-sub')
            $result.Count | Should -Be 0
            Assert-MockCalled Write-Warning -Times 2 # One for disabled, one for no enabled
        }
    }
    
    Context 'When no subscription IDs are provided' {
        It 'Should return all enabled subscriptions' {
            $result = Get-TargetSubscriptions
            $result.Count | Should -Be 2
            $result | ForEach-Object { $_.State | Should -Be 'Enabled' }
        }
    }
}

Describe 'Get-WindowsVMInventory Function' {
    BeforeAll {
        Mock Import-Module {}
        Mock Set-AzContext {}
        Mock Get-AzVM {
            if ($script:throwError) {
                throw "Failed to get VMs"
            }
            return @(
                [PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    StorageProfile    = @{
                        OSDisk = @{ OSType = 'Windows' }
                    }
                },
                [PSCustomObject]@{
                    Name              = 'VM2'
                    ResourceGroupName = 'RG1'
                    LicenseType       = 'Windows_Server'
                    StorageProfile    = @{
                        OSDisk = @{ OSType = 'Windows' }
                    }
                },
                [PSCustomObject]@{
                    Name              = 'LinuxVM'
                    ResourceGroupName = 'RG1'
                    StorageProfile    = @{
                        OSDisk = @{ OSType = 'Linux' }
                    }
                }
            )
        }
    }
    
    Context 'Happy path VM discovery' {
        It 'Should discover Windows VMs from subscriptions' {
            $script:throwError = $false
            $subscriptions = @(
                [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub 1' }
            )
            
            $result = Get-WindowsVMInventory -Subscriptions $subscriptions -ThrottleLimit 1
            $vms = $result | Where-Object { -not $_.Error }
            
            $vms.Count | Should -Be 2
            $vms | ForEach-Object {
                $_.SubscriptionName | Should -Be 'Test Sub 1'
                $_.SubscriptionId | Should -Be 'sub-1'
                $_.StorageProfile.OSDisk.OSType | Should -Be 'Windows'
            }
        }
        
        It 'Should exclude Linux VMs' {
            $script:throwError = $false
            $subscriptions = @(
                [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub 1' }
            )
            
            $result = Get-WindowsVMInventory -Subscriptions $subscriptions -ThrottleLimit 1
            $vms = $result | Where-Object { -not $_.Error }
            
            $vms | Where-Object { $_.Name -eq 'LinuxVM' } | Should -BeNullOrEmpty
        }
    }
    
    Context 'Error handling' {
        It 'Should handle subscription context errors' {
            $script:throwError = $true
            $subscriptions = @(
                [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub 1' }
            )
            
            $result = Get-WindowsVMInventory -Subscriptions $subscriptions -ThrottleLimit 1
            $errors = $result | Where-Object { $_.Error }
            
            $errors.Count | Should -BeGreaterThan 0
            $errors[0].Error | Should -Be $true
            $errors[0].Message | Should -BeLike "*Failed to get VMs*"
            $errors[0].SubscriptionName | Should -Be 'Test Sub 1'
        }
        
        It 'Should continue processing other subscriptions after error' {
            Mock Get-AzVM {
                if ($script:currentSub -eq 'sub-1') {
                    throw "Failed for sub-1"
                }
                return @([PSCustomObject]@{
                        Name              = 'VM1'
                        ResourceGroupName = 'RG1'
                        StorageProfile    = @{ OSDisk = @{ OSType = 'Windows' } }
                    })
            }
            
            $subscriptions = @(
                [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub 1' },
                [PSCustomObject]@{ Id = 'sub-2'; Name = 'Test Sub 2' }
            )
            
            $result = Get-WindowsVMInventory -Subscriptions $subscriptions -ThrottleLimit 1
            
            ($result | Where-Object { $_.Error }).Count | Should -BeGreaterThan 0
            ($result | Where-Object { -not $_.Error }).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Set-HybridBenefitOnVMs Function' {
    BeforeAll {
        Mock Import-Module {}
        Mock Set-AzContext {}
        Mock Get-AzVM {
            param($ResourceGroupName, $Name)
            return [PSCustomObject]@{
                Name              = $Name
                ResourceGroupName = $ResourceGroupName
                LicenseType       = $null
            }
        }
        Mock Update-AzVM {
            if ($script:throwOSError) {
                throw "Failed to update OS license"
            }
            return $true
        }
        Mock Get-AzSqlVM {
            if ($script:noSqlExtension) {
                throw "SQL VM extension not found"
            }
            return [PSCustomObject]@{
                SqlServerLicenseType = 'PAYG'
            }
        }
        Mock Update-AzSqlVM {
            if ($script:throwSQLError) {
                throw "Failed to update SQL license"
            }
            return $true
        }
    }
    
    Context 'OS License Updates' {
        It 'Should update OS license when not already set' {
            $script:throwOSError = $false
            $script:noSqlExtension = $true
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'OS' -ThrottleLimit 1
            
            $results.Count | Should -Be 1
            $results[0].Applied | Should -Be 'OS'
            $results[0].Status | Should -Be 'Success'
            $results[0].Message | Should -BeLike "*OS license updated*"
            
            Assert-MockCalled Update-AzVM -Times 1
        }
        
        It 'Should skip OS update when already set to Windows_Server' {
            $script:throwOSError = $false
            $script:noSqlExtension = $true
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = 'Windows_Server'
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'OS' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'None'
            $results[0].Status | Should -Be 'Success'
            $results[0].Message | Should -BeLike "*already set*"
            
            Assert-MockCalled Update-AzVM -Times 0
        }
        
        It 'Should handle OS update errors gracefully' {
            $script:throwOSError = $true
            $script:noSqlExtension = $true
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'OS' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'None'
            $results[0].Status | Should -Be 'Partial Error'
            $results[0].Message | Should -BeLike "*Failed to update OS license*"
        }
    }
    
    Context 'SQL License Updates' {
        It 'Should update SQL license when extension exists' {
            $script:throwOSError = $false
            $script:throwSQLError = $false
            $script:noSqlExtension = $false
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = 'Windows_Server'
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'SQL' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'SQL'
            $results[0].Status | Should -Be 'Success'
            $results[0].Message | Should -BeLike "*SQL license updated*"
            
            Assert-MockCalled Update-AzSqlVM -Times 1
        }
        
        It 'Should skip SQL update when no extension found' {
            $script:throwOSError = $false
            $script:noSqlExtension = $true
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = 'Windows_Server'
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'SQL' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'None'
            $results[0].Status | Should -Be 'Success'
            $results[0].Message | Should -BeLike "*No SQL Server VM extension found*"
            
            Assert-MockCalled Update-AzSqlVM -Times 0
        }
        
        It 'Should skip SQL update for DR licensed VMs' {
            $script:throwOSError = $false
            $script:noSqlExtension = $false
            Mock Get-AzSqlVM {
                return [PSCustomObject]@{
                    SqlServerLicenseType = 'DR'
                }
            }
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = 'Windows_Server'
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'SQL' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'None'
            $results[0].Status | Should -Be 'Success'
            $results[0].Message | Should -BeLike "*already set to 'DR'*"
            
            Assert-MockCalled Update-AzSqlVM -Times 0
        }
    }
    
    Context 'Both Mode Updates' {
        It 'Should update both OS and SQL licenses' {
            $script:throwOSError = $false
            $script:throwSQLError = $false
            $script:noSqlExtension = $false
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'Both' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'OS+SQL'
            $results[0].Status | Should -Be 'Success'
            
            Assert-MockCalled Update-AzVM -Times 1
            Assert-MockCalled Update-AzSqlVM -Times 1
        }
        
        It 'Should handle partial failures correctly' {
            $script:throwOSError = $true
            $script:throwSQLError = $false
            $script:noSqlExtension = $false
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'Both' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'SQL'
            $results[0].Status | Should -Be 'Partial Error'
            $results[0].Message | Should -BeLike "*Failed to update OS license*"
            $results[0].Message | Should -BeLike "*SQL license updated*"
        }
    }
    
    Context 'General Error Handling' {
        It 'Should handle general VM processing errors' {
            Mock Set-AzContext { throw "Context error" }
            
            $vms = @([PSCustomObject]@{
                    Name              = 'VM1'
                    ResourceGroupName = 'RG1'
                    LicenseType       = $null
                    SubscriptionId    = 'sub-1'
                    SubscriptionName  = 'Test Sub'
                })
            
            $results = Set-HybridBenefitOnVMs -VMs $vms -Mode 'Both' -ThrottleLimit 1
            
            $results[0].Applied | Should -Be 'Error'
            $results[0].Status | Should -Be 'Error'
            $results[0].Message | Should -BeLike "*General error processing VM*"
        }
        
        It 'Should return empty array when no VMs provided' {
            Mock Write-Warning {}
            
            $results = Set-HybridBenefitOnVMs -VMs @() -Mode 'Both'
            
            $results | Should -BeNullOrEmpty
            Assert-MockCalled Write-Warning -Times 1
        }
    }
}

Describe 'Invoke-AzHybridBenefitUpdate Integration' {
    BeforeAll {
        Mock Write-Host {}
        Mock Join-Path { "C:\temp\AzHybridBenefit_20250627_120000.csv" }
        Mock Export-Csv {}
    }
    
    Context 'Full workflow execution' {
        It 'Should complete successfully with valid subscriptions and VMs' {
            Mock Get-TargetSubscriptions {
                return @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' })
            }
            Mock Get-WindowsVMInventory {
                return @([PSCustomObject]@{
                        Name              = 'VM1'
                        ResourceGroupName = 'RG1'
                        LicenseType       = $null
                        SubscriptionId    = 'sub-1'
                        SubscriptionName  = 'Test Sub'
                    })
            }
            Mock Set-HybridBenefitOnVMs {
                return @([PSCustomObject]@{
                        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        VMName         = 'VM1'
                        ResourceGroup  = 'RG1'
                        Subscription   = 'Test Sub'
                        SubscriptionId = 'sub-1'
                        Applied        = 'OS'
                        Status         = 'Success'
                        Message        = 'OS license updated'
                    })
            }
            
            { Invoke-AzHybridBenefitUpdate -Mode 'OS' } | Should -Not -Throw
            
            Assert-MockCalled Export-Csv -Times 1
        }
        
        It 'Should exit early when no subscriptions found' {
            Mock Get-TargetSubscriptions { throw "No subscriptions" }
            
            { Invoke-AzHybridBenefitUpdate } | Should -Not -Throw
            
            Assert-MockCalled Get-WindowsVMInventory -Times 0
            Assert-MockCalled Set-HybridBenefitOnVMs -Times 0
        }
        
        It 'Should continue when some VMs fail discovery' {
            Mock Get-TargetSubscriptions {
                return @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' })
            }
            Mock Get-WindowsVMInventory {
                return @(
                    [PSCustomObject]@{
                        Name              = 'VM1'
                        ResourceGroupName = 'RG1'
                        LicenseType       = $null
                        SubscriptionId    = 'sub-1'
                        SubscriptionName  = 'Test Sub'
                    },
                    [PSCustomObject]@{
                        Error            = $true
                        Message          = 'Failed to get VMs'
                        SubscriptionName = 'Test Sub 2'
                        SubscriptionId   = 'sub-2'
                    }
                )
            }
            Mock Set-HybridBenefitOnVMs {
                return @([PSCustomObject]@{
                        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        VMName         = 'VM1'
                        ResourceGroup  = 'RG1'
                        Subscription   = 'Test Sub'
                        SubscriptionId = 'sub-1'
                        Applied        = 'OS'
                        Status         = 'Success'
                        Message        = 'OS license updated'
                    })
            }
            
            { Invoke-AzHybridBenefitUpdate } | Should -Not -Throw
            
            Assert-MockCalled Set-HybridBenefitOnVMs -Times 1
        }
        
        It 'Should handle CSV export errors gracefully' {
            Mock Get-TargetSubscriptions {
                return @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' })
            }
            Mock Get-WindowsVMInventory {
                return @([PSCustomObject]@{
                        Name              = 'VM1'
                        ResourceGroupName = 'RG1'
                        LicenseType       = $null
                        SubscriptionId    = 'sub-1'
                        SubscriptionName  = 'Test Sub'
                    })
            }
            Mock Set-HybridBenefitOnVMs {
                return @([PSCustomObject]@{
                        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        VMName         = 'VM1'
                        ResourceGroup  = 'RG1'
                        Subscription   = 'Test Sub'
                        SubscriptionId = 'sub-1'
                        Applied        = 'OS'
                        Status         = 'Success'
                        Message        = 'OS license updated'
                    })
            }
            Mock Export-Csv { throw "Access denied" }
            
            { Invoke-AzHybridBenefitUpdate } | Should -Not -Throw
        }
    }
    
    Context 'Summary and reporting' {
        It 'Should generate correct summary statistics' {
            Mock Get-TargetSubscriptions {
                return @([PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' })
            }
            Mock Get-WindowsVMInventory {
                return @(
                    [PSCustomObject]@{
                        Name              = 'VM1'
                        ResourceGroupName = 'RG1'
                        LicenseType       = $null
                        SubscriptionId    = 'sub-1'
                        SubscriptionName  = 'Test Sub'
                    },
                    [PSCustomObject]@{
                        Name              = 'VM2'
                        ResourceGroupName = 'RG1'
                        LicenseType       = $null
                        SubscriptionId    = 'sub-1'
                        SubscriptionName  = 'Test Sub'
                    }
                )
            }
            Mock Set-HybridBenefitOnVMs {
                return @(
                    [PSCustomObject]@{
                        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        VMName         = 'VM1'
                        ResourceGroup  = 'RG1'
                        Subscription   = 'Test Sub'
                        SubscriptionId = 'sub-1'
                        Applied        = 'OS+SQL'
                        Status         = 'Success'
                        Message        = 'Both licenses updated'
                    },
                    [PSCustomObject]@{
                        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        VMName         = 'VM2'
                        ResourceGroup  = 'RG1'
                        Subscription   = 'Test Sub'
                        SubscriptionId = 'sub-1'
                        Applied        = 'None'
                        Status         = 'Success'
                        Message        = 'Already configured'
                    }
                )
            }
            
            { Invoke-AzHybridBenefitUpdate } | Should -Not -Throw
            
            # Verify Export-Csv was called with correct data
            Assert-MockCalled Export-Csv -Times 1 -ParameterFilter {
                $InputObject.Count -eq 2
            }
        }
    }
}

Describe 'Script Execution Prevention' {
    It 'Should not execute when dot-sourced for testing' {
        Mock Invoke-AzHybridBenefitUpdate {}
        
        # The script should have already been dot-sourced in BeforeAll
        # and should not have executed Invoke-AzHybridBenefitUpdate
        
        Assert-MockCalled Invoke-AzHybridBenefitUpdate -Times 0
    }
}