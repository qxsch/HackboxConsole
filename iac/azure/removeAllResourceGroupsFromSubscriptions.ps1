<#
.SYNOPSIS
Removes every resource group from Azure subscriptions matching the provided prefix, optionally scoped to a management group.
.PARAMETER managementGroupId
Limits the cleanup to subscriptions inside the specified management group; when omitted, all tenant subscriptions are considered.
.PARAMETER subscriptionPrefix
Prefix used to select target subscriptions (defaults to 'traininglab-').
.PARAMETER parallelization
Maximum number of concurrent subscription cleanup jobs to run in parallel.
Valid range: 1-100
Default: 10
.DESCRIPTION
Iterates through subscriptions whose names start with the provided prefix, sets context to each one, and deletes every resource group found using the Az PowerShell module. Runs subscription cleanups in parallel using PowerShell jobs for improved performance. Useful for quickly resetting training or lab environments.
.EXAMPLE
.\removeAllResourceGroupsFromSubscriptions.ps1 -managementGroupId "labsubscriptions"
Deletes all resource groups from enabled subscriptions under the specified management group whose names start with the default prefix.
.EXAMPLE
.\removeAllResourceGroupsFromSubscriptions.ps1 -managementGroupId "labsubscriptions" -parallelization 20
Deletes all resource groups with up to 20 concurrent subscription cleanup jobs.
#>
param(
    [string]$managementGroupId = "",
    [string]$subscriptionPrefix = "traininglab-",
    [ValidateRange(1, 100)]
    [int]$parallelization = 10
)

# az module
foreach($module in @(
    'Az.Accounts',
    'Az.Resources'
)) {
    if( -not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module"
        Install-Module -Name $module -AllowClobber -Force
    }
    Write-Host "Importing module: $module"
    Import-Module $module
}
if(-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -UseDeviceAuthentication
}


$subscriptionIdFilter = $null
if($managementGroupId -ne "") {
    $subscriptionIdFilter = @{}
    foreach($mg in (Get-AzManagementGroup -GroupName $managementGroupId -Recurse -Expand -ErrorAction Stop | Select-Object -ExpandProperty Children )) {
        if($mg.Type -eq "/subscriptions") {
            $subscriptionIdFilter[$mg.Name.ToLower()] = $true
        }
    }
}

# Collect qualified subscriptions
$qualifiedSubscriptions = @()
foreach($sub in (Get-AzSubscription  | Where-Object { $_.Name.ToLower().StartsWith($subscriptionPrefix.ToLower()) -and $_.State -eq "Enabled"})) {
    if($null -ne $subscriptionIdFilter) {
        if(-not $subscriptionIdFilter.ContainsKey($sub.Id.ToLower())) {
            continue
        }
    }
    $qualifiedSubscriptions += $sub
}

Write-Host "Found $($qualifiedSubscriptions.Count) qualified subscriptions to clean up."
Write-Host "Starting parallel cleanup with max $parallelization concurrent jobs..."

# Run subscription cleanups in parallel using jobs
$runningJobs = @()
$taskIndex = 0
$completedCount = 0

while($taskIndex -lt $qualifiedSubscriptions.Count -or $runningJobs.Count -gt 0) {
    # Start new jobs up to the parallelization limit
    while($runningJobs.Count -lt $parallelization -and $taskIndex -lt $qualifiedSubscriptions.Count) {
        $sub = $qualifiedSubscriptions[$taskIndex]
        Write-Host "[Job $($taskIndex + 1)/$($qualifiedSubscriptions.Count)] Starting cleanup for subscription $($sub.Name) ($($sub.Id))..." -ForegroundColor Yellow
        
        $job = Start-Job -ScriptBlock {
            param($subscriptionId, $subscriptionName)
            
            # Import Az modules
            foreach($mod in @("Az.Accounts","Az.Resources", "Az.RecoveryServices", "Az.DataProtection")) {
                Import-Module $mod -ErrorAction Stop
            }
            # Set context
            Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop -Scope Process | Out-Null

            $result = @{
                SubscriptionName = $subscriptionName
                SubscriptionId = $subscriptionId
                LocksRemoved = 0
                ResourceGroupsDeleted = 0
                Errors = @()
            }


            # Remove locks first
            try {
                foreach($lock in (Get-AzResourceLock -ErrorAction SilentlyContinue | Sort-Object ResourceId)) {
                    Write-Output "  Removing lock from Resource: $($lock.ResourceId)"
                    $lock | Remove-AzResourceLock -ErrorAction Continue -Force -Confirm:$false | Out-Null
                    $result.LocksRemoved++
                    Start-Sleep -Seconds 1
                }
                if($result.LocksRemoved -gt 0) {
                    Write-Output "  Waiting 10 seconds for locks to be fully removed..."
                    Start-Sleep -Seconds 10
                }
            }
            catch {
                $result.Errors += "Lock removal error: $_"
            }

            # remove all disk exports
            foreach ($disk in (Get-AzDisk)) {
                # DiskState of 'ActiveSAS' indicates the disk has an active export
                if ($disk.DiskState -eq 'ActiveSAS') {
                    try {
                        # Revoke access to disable the export
                        Write-Host "    Revoking access for disk: $($disk.Name)..." -ForegroundColor White
                        Revoke-AzDiskAccess -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -ErrorAction Stop | Out-Null
                    }
                    catch {
                        Write-Host "    Failed to revoke access for disk: $($disk.Name). Error: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }

            # Disable soft delete for Microsoft.RecoveryServices/vaults
            Write-Host "  Checking Recovery Services Vaults..." -ForegroundColor Yellow
            foreach ($vault in (Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue)) {
                try {
                    # Set vault context
                    Set-AzRecoveryServicesVaultContext -Vault $vault
                    # Disable soft delete for the vault
                    Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -SoftDeleteFeatureState Disable -ErrorAction Stop | Out-Null
                    Write-Host "      Soft delete disabled for Recovery Services Vault: $($vault.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Host "      Error disabling soft delete for $($vault.Name): $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # Disable soft delete for Microsoft.DataProtection/backupVaults
            Write-Host "  Checking Data Protection Backup Vaults..." -ForegroundColor Yellow
            foreach ($backupVault in (Get-AzDataProtectionBackupVault -ErrorAction SilentlyContinue)) {
                try {
                    # Update backup vault to disable soft delete
                    $resourceGroupName = $backupVault.Id -replace '.*resourceGroups/([^/]+)/.*', '$1'
                    Update-AzDataProtectionBackupVault `
                        -ResourceGroupName $resourceGroupName `
                        -VaultName $backupVault.Name `
                        -SoftDeleteState Off -ErrorAction Stop | Out-Null  
                    Write-Host "      Soft delete disabled for Backup Vault: $($backupVault.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Host "      Error disabling soft delete for $($backupVault.Name): $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # Remove resource groups
            try {
                Write-Host "  Removing Resource Groups..." -ForegroundColor Yellow
                foreach($rg in (Get-AzResourceGroup)) {
                    Write-Output "  Deleting Resource Group: $($rg.ResourceGroupName)"
                    Remove-AzResourceGroup -Name $rg.ResourceGroupName -Force -Confirm:$false -ErrorAction Continue | Out-Null
                    $result.ResourceGroupsDeleted++
                    Start-Sleep -Milliseconds 500
                }
            }
            catch {
                $result.Errors += "Resource group deletion error: $_"
            }

            # Remove policy assignments at subscription level
            try {
                Write-Host "  Removing Policy Assignments at subscription scope..." -ForegroundColor Yellow
                $subscriptionScope = "/subscriptions/$subscriptionId"
                $policyAssignments = Get-AzPolicyAssignment -Scope $subscriptionScope -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $subscriptionScope }
                foreach ($pa in $policyAssignments) {
                    Write-Output "  Deleting Policy Assignment: $($pa.Name)"
                    Remove-AzPolicyAssignment -Id $pa.PolicyAssignmentId -ErrorAction Continue | Out-Null
                }
            }
            catch {
                $result.Errors += "Policy assignment removal error: $_"
            }

            # Remove custom policy definitions at subscription level
            try {
                Write-Host "  Removing Custom Policy Definitions at subscription scope..." -ForegroundColor Yellow
                $policyDefinitions = Get-AzPolicyDefinition -Custom -ErrorAction SilentlyContinue | Where-Object { $_.PolicyDefinitionId -like "/subscriptions/$subscriptionId/*" }
                foreach ($pd in $policyDefinitions) {
                    Write-Output "  Deleting Policy Definition: $($pd.Name)"
                    Remove-AzPolicyDefinition -Id $pd.PolicyDefinitionId -Force -ErrorAction Continue | Out-Null
                }
            }
            catch {
                $result.Errors += "Policy definition removal error: $_"
            }

            return $result
        } -ArgumentList $sub.Id, $sub.Name
        
        $runningJobs += @{ Job = $job; Subscription = $sub; Index = $taskIndex }
        $taskIndex++
    }
    
    # Check for completed jobs
    if($runningJobs.Count -gt 0) {
        $completed = $runningJobs | Where-Object { $_.Job.State -eq 'Completed' -or $_.Job.State -eq 'Failed' }
        
        foreach($item in $completed) {
            $completedCount++
            if($item.Job.State -eq 'Failed') {
                Write-Warning "[Job $($item.Index + 1)] Cleanup FAILED for subscription $($item.Subscription.Name): $($item.Job.ChildJobs[0].JobStateInfo.Reason)"
            }
            else {
                $jobResult = Receive-Job -Job $item.Job
                if($jobResult -is [hashtable] -or $jobResult -is [PSCustomObject]) {
                    Write-Host "[Job $($item.Index + 1)] Cleanup completed for subscription $($item.Subscription.Name) - Locks removed: $($jobResult.LocksRemoved), Resource groups deleted: $($jobResult.ResourceGroupsDeleted) ($completedCount/$($qualifiedSubscriptions.Count))" -ForegroundColor Green
                    if($jobResult.Errors.Count -gt 0) {
                        foreach($err in $jobResult.Errors) {
                            Write-Warning "  Error: $err"
                        }
                    }
                }
                else {
                    Write-Host "[Job $($item.Index + 1)] Cleanup completed for subscription $($item.Subscription.Name) ($completedCount/$($qualifiedSubscriptions.Count))" -ForegroundColor Green
                }
            }
            Remove-Job -Job $item.Job -Force
        }
        
        $runningJobs = @($runningJobs | Where-Object { $_.Job.State -eq 'Running' })
        
        if($runningJobs.Count -ge $parallelization -or ($taskIndex -ge $qualifiedSubscriptions.Count -and $runningJobs.Count -gt 0)) {
            Start-Sleep -Milliseconds 500
        }
    }
}

Write-Host "Parallel cleanup completed. Total subscriptions processed: $completedCount" -ForegroundColor Green

