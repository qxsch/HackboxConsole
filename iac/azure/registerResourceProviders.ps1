<#
.SYNOPSIS
    Registers required Azure resource providers across multiple subscriptions in parallel.

.DESCRIPTION
    This script identifies Azure subscriptions by prefix (and optionally within a management group),
    then registers the specified resource providers on each subscription using parallel PowerShell jobs.

    After all registration jobs complete, it waits for providers that were newly initiated to finish
    registering, then reports a summary.

.PARAMETER managementGroupId
    Limits the operation to subscriptions within the specified Azure Management Group.
    When omitted, all tenant subscriptions matching the prefix are considered.

.PARAMETER subscriptionPrefix
    Prefix used to filter and select target Azure subscriptions.
    Default: 'traininglab-'

.PARAMETER parallelization
    Maximum number of concurrent registration jobs to run in parallel.
    Valid range: 1-100
    Default: 10

.PARAMETER requiredProviders
    Array of Azure resource provider namespaces to register on each subscription.

.EXAMPLE
    .\registerResourceProviders.ps1

    Registers default providers on all subscriptions prefixed with 'traininglab-'.

.EXAMPLE
    .\registerResourceProviders.ps1 -managementGroupId "labsubscriptions" -subscriptionPrefix "workshop-" -parallelization 20

    Registers providers on subscriptions starting with 'workshop-' within the 'labsubscriptions'
    management group, with up to 20 concurrent jobs.

.EXAMPLE
    .\registerResourceProviders.ps1 -requiredProviders @("Microsoft.Compute", "Microsoft.Network")

    Registers only the specified providers.

.NOTES
    Prerequisites:
    - Azure PowerShell (Az module) must be installed or will be auto-installed
    - An authenticated Azure session is required
#>
param(
    [string]$managementGroupId = "",
    [string]$subscriptionPrefix = "traininglab-",
    [ValidateRange(1, 100)]
    [int]$parallelization = 10,
    [string[]]$requiredProviders = @(
        "Microsoft.Compute",
        "Microsoft.Network",
        "Microsoft.Storage",
        "Microsoft.RecoveryServices",
        "Microsoft.DataProtection",
        "Microsoft.Automation",
        "Microsoft.OperationalInsights",
        "Microsoft.KeyVault",
        "Microsoft.SqlVirtualMachine",
        "Microsoft.Resources",
        "Microsoft.Web",
        "Microsoft.ContainerService",
        "Microsoft.App",
        "Microsoft.AppPlatform",
        "Microsoft.ContainerRegistry",
        "Microsoft.ManagedIdentity",
        "Microsoft.Advisor",
        "Microsoft.AlertsManagement",
        "Microsoft.Kubernetes",
        "Microsoft.KubernetesConfiguration"
    )
)

# Ensure Az modules are available
foreach ($module in @('Az.Accounts', 'Az.Resources')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module"
        Install-Module -Name $module -AllowClobber -Force
    }
    Write-Host "Importing module: $module"
    Import-Module $module
}
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -UseDeviceAuthentication
}

# Discover qualified subscriptions
$subscriptionIdFilter = $null
if ($managementGroupId -ne "") {
    $subscriptionIdFilter = @{}
    foreach ($mg in (Get-AzManagementGroup -GroupName $managementGroupId -Recurse -Expand -ErrorAction Stop | Select-Object -ExpandProperty Children)) {
        if ($mg.Type -eq "/subscriptions") {
            $subscriptionIdFilter[$mg.Name.ToLower()] = $true
        }
    }
}

$qualifiedSubscriptions = @()
foreach ($sub in (Get-AzSubscription | Where-Object { $_.Name.ToLower().StartsWith($subscriptionPrefix.ToLower()) -and $_.State -eq "Enabled" })) {
    if ($null -ne $subscriptionIdFilter) {
        if (-not $subscriptionIdFilter.ContainsKey($sub.Id.ToLower())) {
            continue
        }
    }
    $qualifiedSubscriptions += $sub
}
$qualifiedSubscriptions = $qualifiedSubscriptions | Sort-Object -Property Name, Id

Write-Host "Found $($qualifiedSubscriptions.Count) qualified subscription(s)."
Write-Host "Providers to register: $($requiredProviders -join ', ')"
Write-Host ""

if ($qualifiedSubscriptions.Count -eq 0) {
    Write-Warning "No qualified subscriptions found. Nothing to do."
    return
}

# Build task list: one task per subscription
$registrationTasks = @()
foreach ($sub in $qualifiedSubscriptions) {
    $registrationTasks += @{
        SubscriptionId   = $sub.Id
        SubscriptionName = $sub.Name
    }
}

# Run registrations in parallel using jobs (same pattern as deployLabEnvironments.ps1)
Write-Host "Starting parallel provider registration for $($registrationTasks.Count) subscription(s) (max $parallelization concurrent jobs)..."

$runningJobs = @()
$taskIndex = 0
$completedCount = 0
$failedCount = 0

while ($taskIndex -lt $registrationTasks.Count -or $runningJobs.Count -gt 0) {
    # Start new jobs up to the parallelization limit
    while ($runningJobs.Count -lt $parallelization -and $taskIndex -lt $registrationTasks.Count) {
        $task = $registrationTasks[$taskIndex]
        Write-Host "[Job $($taskIndex + 1)/$($registrationTasks.Count)] Starting provider registration for subscription $($task.SubscriptionName) ($($task.SubscriptionId))..."

        $job = Start-Job -ScriptBlock {
            param($subscriptionId, $subscriptionName, $providers)

            # Import Az modules in the job process
            foreach ($mod in @("Az.Accounts", "Az.Resources")) {
                Import-Module $mod -ErrorAction Stop
            }
            Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop -Scope Process | Out-Null

            $errors = 0
            $initiatedRegistrations = 0
            $results = @()

            foreach ($provider in $providers) {
                try {
                    $providerInfo = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop

                    if ($providerInfo.RegistrationState -eq "Registered") {
                        $results += "[${subscriptionName}] $provider is already registered"
                    }
                    else {
                        $results += "[${subscriptionName}] $provider not registered (attempting registration...)"
                        try {
                            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
                            $results += "[${subscriptionName}] $provider registration initiated"
                            $initiatedRegistrations++
                        }
                        catch {
                            $results += "[${subscriptionName}] Failed to register ${provider}: $_"
                            $errors++
                        }
                    }
                }
                catch {
                    $results += "[${subscriptionName}] Could not check ${provider}: $_"
                    $errors++
                }
            }

            # Wait for completion if any registrations were initiated
            if ($initiatedRegistrations -gt 0) {
                $results += "[${subscriptionName}] Waiting for $initiatedRegistrations provider registration(s) to complete..."
                $maxWaitSeconds = 300
                $pollIntervalSeconds = 15
                $elapsed = 0

                while ($elapsed -lt $maxWaitSeconds) {
                    Start-Sleep -Seconds $pollIntervalSeconds
                    $elapsed += $pollIntervalSeconds

                    $allRegistered = $true
                    foreach ($provider in $providers) {
                        try {
                            $providerInfo = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
                            if ($providerInfo.RegistrationState -ne "Registered") {
                                $allRegistered = $false
                                break
                            }
                        }
                        catch {
                            $allRegistered = $false
                            break
                        }
                    }

                    if ($allRegistered) {
                        $results += "[${subscriptionName}] All provider registrations confirmed after ${elapsed}s"
                        break
                    }
                }

                if (-not $allRegistered) {
                    $results += "[${subscriptionName}] WARNING: Not all providers confirmed registered after ${maxWaitSeconds}s"
                }
            }

            # Return structured output
            @{
                SubscriptionName       = $subscriptionName
                SubscriptionId         = $subscriptionId
                Errors                 = $errors
                InitiatedRegistrations = $initiatedRegistrations
                Messages               = $results
            }
        } -ArgumentList $task.SubscriptionId, $task.SubscriptionName, $requiredProviders

        $runningJobs += @{ Job = $job; Task = $task; Index = $taskIndex }
        $taskIndex++
    }

    # Poll for completed jobs
    if ($runningJobs.Count -gt 0) {
        $completed = $runningJobs | Where-Object { $_.Job.State -eq 'Completed' -or $_.Job.State -eq 'Failed' }

        foreach ($item in $completed) {
            $completedCount++
            if ($item.Job.State -eq 'Failed') {
                $failedCount++
                Write-Warning "[Job $($item.Index + 1)] Registration FAILED for subscription $($item.Task.SubscriptionName): $($item.Job.ChildJobs[0].JobStateInfo.Reason)"
                Receive-Job -Job $item.Job -ErrorAction SilentlyContinue | Out-Null
            }
            else {
                $output = Receive-Job -Job $item.Job
                if ($output -is [System.Collections.IDictionary] -or $output -is [System.Collections.Hashtable]) {
                    foreach ($msg in $output.Messages) {
                        Write-Host $msg
                    }
                    if ($output.Errors -gt 0) {
                        $failedCount++
                        Write-Warning "[Job $($item.Index + 1)] Completed with $($output.Errors) error(s) for subscription $($item.Task.SubscriptionName)"
                    }
                    else {
                        Write-Host "[Job $($item.Index + 1)] Registration completed for subscription $($item.Task.SubscriptionName) ($completedCount/$($registrationTasks.Count))"
                    }
                }
                else {
                    # Fallback: print raw output
                    $output | ForEach-Object { Write-Host $_ }
                    Write-Host "[Job $($item.Index + 1)] Registration completed for subscription $($item.Task.SubscriptionName) ($completedCount/$($registrationTasks.Count))"
                }
            }
            Remove-Job -Job $item.Job -Force
        }

        $runningJobs = @($runningJobs | Where-Object { $_.Job.State -eq 'Running' })

        if ($runningJobs.Count -ge $parallelization -or ($taskIndex -ge $registrationTasks.Count -and $runningJobs.Count -gt 0)) {
            Start-Sleep -Milliseconds 500
        }
    }
}

# Summary
Write-Host ""
Write-Host "=============================="
Write-Host "Provider Registration Summary"
Write-Host "=============================="
Write-Host "Total subscriptions processed: $completedCount"
Write-Host "Successful: $($completedCount - $failedCount)"
Write-Host "Failed: $failedCount"
Write-Host ""

if ($failedCount -eq 0) {
    Write-Host "All resource providers registered successfully across all subscriptions."
}
else {
    Write-Warning "Resource provider registration completed with $failedCount subscription(s) having errors."
}




