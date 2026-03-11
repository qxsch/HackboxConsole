<#
.SYNOPSIS
    Deploys lab environments to Azure subscriptions for hackathon participants.

.DESCRIPTION
    This script automates the deployment of lab environments for hackathon or training events.
    It reads Entra ID user information from 'createdEntraIdUserSettings.json', identifies qualified
    Azure subscriptions based on a naming prefix, and deploys lab resources for each user.

    The script supports two deployment types:
    - 'subscription': Each user gets their own subscription with Owner role. One user per subscription.
    - 'resourcegroup': Multiple users share a subscription, each with their own resource group.
      Users get Reader role on the subscription and Owner role on their resource group.
    - 'resourcegroup-with-subscriptionowner': Similar to 'resourcegroup', but users also get Owner role on the subscription.

    The script runs lab deployments in parallel using PowerShell jobs for improved performance.
    Deployment credentials are collected and exported to 'createdLabUserSettings.json'.

.PARAMETER labDirectory
    Path to the directory containing the 'deploy-lab.ps1' script for lab resource deployment.
    If empty, only role assignments and resource group creation (for resourcegroup type) are performed.
    ( If empty, users must then deploy the labs manually. )

.PARAMETER managementGroupId
    Limits the deployment to subscriptions within the specified Azure Management Group.
    When omitted, all tenant subscriptions matching the prefix are considered.

.PARAMETER subscriptionPrefix
    Prefix used to filter and select target Azure subscriptions.
    Default: 'traininglab-'

.PARAMETER deploymentType
    Defines the deployment scope. Valid values:
    - 'subscription': One user per subscription with Owner role.
    - 'resourcegroup': Multiple users per subscription, each with their own resource group.
    Default: 'resourcegroup'

.PARAMETER teamsPerSubscription
    Number of users (teams) to accommodate per subscription.
    Only applicable when deploymentType is 'resourcegroup'.
    Default: 5

.PARAMETER preferredLocation
    Specifies the preferred Azure region for resource deployment (e.g., 'westeurope', 'eastus').
    If empty, defaults to 'swedencentral' for resource group creation.

.PARAMETER labDeploymentParallelization
    Maximum number of concurrent lab deployment jobs to run in parallel.
    Valid range: 1-100
    Default: 10

.PARAMETER skipResourceGroupCreation
    When specified, skips the creation of resource groups and Owner role assignments.
    Useful when resource groups already exist or are managed externally.
    Only applicable when deploymentType is 'resourcegroup'.

.EXAMPLE
    .\deployLabEnvironments.ps1

    Deploys lab environments using default settings. Creates resource groups for each user
    in subscriptions prefixed with 'traininglab-'.

.EXAMPLE
    .\deployLabEnvironments.ps1 -labDirectory "C:\Labs\AzureWorkshop" -deploymentType "subscription"

    Deploys lab resources from the specified directory, assigning one subscription per user
    with Owner permissions.

.EXAMPLE
    .\deployLabEnvironments.ps1 -managementGroupId "labsubscriptions" -labDirectory ".\iac\lab" -teamsPerSubscription 2 -preferredLocation "eastus"

    Deploys labs with 2 users per subscription in the East US region and just uses subscriptions under the 'labsubscriptions' management group.

.EXAMPLE
    .\deployLabEnvironments.ps1 -managementGroupId "labsubscriptions" -subscriptionPrefix "workshop-"

    Deploys to subscriptions starting with 'workshop-' that are within the 'labsubscriptions' management group.

.EXAMPLE
    .\deployLabEnvironments.ps1 -labDirectory ".\iac\lab" -labDeploymentParallelization 20 -skipResourceGroupCreation

    Deploys labs with up to 20 concurrent jobs, using existing resource groups.

.NOTES
    Prerequisites:
    - Run 'createEntraIdUsers.ps1' first to generate 'createdEntraIdUserSettings.json'
    - Azure PowerShell (Az module) must be installed or will be auto-installed
    - Microsoft Graph PowerShell SDK (Microsoft.Graph.Users) must be installed or will be auto-installed
    - Authenticated sessions to both Azure and Microsoft Graph are required

    Output:
    - Creates 'createdLabUserSettings.json' with deployment credentials in the console root directory
#>
param(
    [string]$labDirectory = "",
    [string]$managementGroupId = "",
    [string]$subscriptionPrefix = "traininglab-",
    [ValidateSet('subscription','resourcegroup','resourcegroup-with-subscriptionowner')]
    [string]$deploymentType = "resourcegroup",
    [int]$teamsPerSubscription = 5,
    [string]$preferredLocation = "",
    [ValidateRange(1, 100)]
    [int]$labDeploymentParallelization = 5,
    [ValidateRange(250, 1000000)]
    [int]$maxSleepDelayMilliseconds = 25000,
    [switch]$skipResourceGroupCreation,
    [switch]$autoDiscoveredLab
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$consoleRoot = Split-Path -Parent (Split-Path -Parent $scriptPath)

if($labDirectory -eq "" -and $autoDiscoveredLab) {
    $labDirectory = (Get-Item "$PSScriptRoot/../lab").FullName 
    if(-not (Test-Path -Path $labDirectory -PathType Container)) {
        throw "Auto-discovery of lab directory enabled but directory not found at expected location: $labDirectory"
    }
    Write-Host "Auto-discovered lab directory at: $labDirectory"
}
elseif($autoDiscoveredLab -and $labDirectory -ne "") {
    throw "Both auto-discovery and explicit lab directory path provided. Please specify only one method for locating the lab directory."
}

exit

if(-not(Test-Path (Join-Path $consoleRoot "createdEntraIdUserSettings.json"))) {
    throw "the file createdEntraIdUserSettings.json was not found in $consoleRoot. Please run the createEntraIdUsers.ps1 script first."
}
$entraIdUserSettings = Get-Content (Join-Path $consoleRoot "createdEntraIdUserSettings.json") | ConvertFrom-Json | Where-Object { $_.group -eq "Azure" -and $_.name -eq "EntraID Username" }
if($null -eq $entraIdUserSettings -or $entraIdUserSettings.Count -eq 0) {
    throw "the file createdEntraIdUserSettings.json does not contain an entry for Entra ID users in the Azure group. Please run the createEntraIdUsers.ps1 script first."
}

if($labDirectory -ne "") {
    $labDirectory = (Resolve-Path -Path $labDirectory -ErrorAction Stop).Path
    if(-not(Test-Path $labDirectory)) {
        throw "The specified lab directory '$labDirectory' does not exist."
    }
}

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

# Install required PowerShell modules
foreach ($module in @(
    'Microsoft.Graph.Users'
)) {
    if( -not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module"
        Install-PSResource -Name $module -Repository PSGallery -TrustRepository
    }
    Write-Host "Importing module: $module"
    Import-Module $module
}

# Connect to Microsoft Graph with required permissions
$mgctx = Get-MgContext
if($null -eq $mgctx -or $mgctx.Scopes -notcontains "User.ReadWrite.All") {
    Write-Host "Connecting to Microsoft Graph with required permissions..."
    Connect-MgGraph -Scopes "User.ReadWrite.All" -UseDeviceCode
    $mgctx = Get-MgContext
    if($null -eq $mgctx -or $mgctx.Scopes -notcontains "User.ReadWrite.All") {
        throw "Failed to connect to Microsoft Graph with required permissions."
    }
} 
else {
    Write-Host "Already connected to Microsoft Graph with required permissions."
}

class HackBoxCredentialsConsumer {
    hidden [PSCustomObject[]] $credentials = @()

    HackBoxCredentialsConsumer() {
    }

    [void] ConsumeJobOutput([object]$jobOutput, [string]$hackboxTenant) {
        $this.ConsumeJobOutput($jobOutput, $hackboxTenant, "Lab-Deployment")
    }
    [void] ConsumeJobOutput([object]$jobOutput, [string]$hackboxTenant, [string]$hackboxGroup) {
        # check if foreach works on $jobOutput
        if(-not ($jobOutput -is [System.Collections.IEnumerable])) {
            return
        }
        foreach($r in $jobOutput) {
            if($r -is [System.Collections.IDictionary] -or $r -is [System.Collections.Hashtable]) {
                if($r.ContainsKey("HackboxCredential")) {
                    if($r["HackboxCredential"] -is [System.Collections.IDictionary] -or $r["HackboxCredential"] -is [System.Collections.Hashtable]) {
                        if(
                            $r["HackboxCredential"].ContainsKey("name") -and $r["HackboxCredential"].ContainsKey("value") -and
                             $r["HackboxCredential"]["name"] -ne "" -and $r["HackboxCredential"]["value"] -ne ""
                        ) {
                            $consoleCredential = [PSCustomObject]@{
                                tenant = $hackboxTenant
                                group = $hackboxGroup
                                name = $r["HackboxCredential"]["name"]
                                value = $r["HackboxCredential"]["value"]
                                note = ""
                            }
                            if($r["HackboxCredential"].ContainsKey("note") -and $r["HackboxCredential"]["note"] -ne "") {
                                $consoleCredential.note = $r["HackboxCredential"]["note"]
                            }
                            $this.credentials += $consoleCredential
                        }
                    }
                }
            }
        }
    }

    [void]resetCredentials() {
        $this.credentials = @()
    }

    [PSCustomObject[]]getCredentials() {
        return $this.credentials
    }
    [string]jsonifyCredentials() {
        return ($this.credentials | ConvertTo-Json -Depth 5 -AsArray)
    }
}

$credentialConsumer = [HackBoxCredentialsConsumer]::new()


# get the user information
$users = @()
foreach($userSetting in $entraIdUserSettings) {
    $user = Get-MgUser -Filter "userPrincipalName eq '$($userSetting.value)'"
    if($null -eq $user) {
        throw "Failed to find Entra ID user with userPrincipalName: $($userSetting.value)"
    }
    $users += [PSCustomObject]@{
        UserPrincipalName = $user.UserPrincipalName
        Id = $user.Id
        DisplayName = $user.DisplayName
        Mail = $user.Mail
        HackboxTenantId = $userSetting.tenant
    }
}
$entraIdUserSettings = @()
# sort entraIdUserSettings by value (to ensure consistent order and idempotency)
$users = $users | Sort-Object -Property UserPrincipalName


# qualified subscriptions
$subscriptionIdFilter = $null
if($managementGroupId -ne "") {
    $subscriptionIdFilter = @{}
    foreach($mg in (Get-AzManagementGroup -GroupName $managementGroupId -Recurse -Expand -ErrorAction Stop | Select-Object -ExpandProperty Children )) {
        if($mg.Type -eq "/subscriptions") {
            $subscriptionIdFilter[$mg.Name.ToLower()] = $true
        }
    }
}
$qualifiedSubscriptions = @()
foreach($sub in (Get-AzSubscription  | Where-Object { $_.Name.ToLower().StartsWith($subscriptionPrefix.ToLower()) -and $_.State -eq "Enabled"})) {
    if($null -ne $subscriptionIdFilter) {
        if(-not $subscriptionIdFilter.ContainsKey($sub.Id.ToLower())) {
            continue
        }
    }
    $qualifiedSubscriptions += $sub
}
# sort subscriptions by name, id (to ensure consistent order and idempotency)
$qualifiedSubscriptions = $qualifiedSubscriptions | Sort-Object -Property Name, Id


# enough subscriptions found to accommodate the users?
Write-Host "Found $($users.Count) Entra ID users."
Write-Host "Found $($qualifiedSubscriptions.Count) qualified subscriptions."
if($deploymentType -eq "subscription") {
    $requiredSubscriptions = $users.Count
}
elseif($deploymentType -eq "resourcegroup") {
    $requiredSubscriptions = [math]::Ceiling($users.Count / $teamsPerSubscription)
}
Write-Host "Required subscriptions to accommodate all users: $requiredSubscriptions (vs $($qualifiedSubscriptions.Count) available)."
if($qualifiedSubscriptions.Count -lt $requiredSubscriptions) {
    throw "Not enough qualified subscriptions found to accommodate all users. Required: $requiredSubscriptions, Found: $($qualifiedSubscriptions.Count)."
}

if($deploymentType -eq "subscription") {
    Write-Host "Deploying lab resources scoped to subscriptions."
    $currentUserIndex = 0
    $deploymentTasks = @()
    foreach($sub in $qualifiedSubscriptions) {
        # stop if all users have been assigned
        if($currentUserIndex -ge $users.Count) {
            break
        }
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
        $user = $users[$currentUserIndex]
        # assign user to this subscription as owner
        if(-not (Get-AzRoleAssignment -ObjectId $user.Id -Scope "/subscriptions/$($sub.Id)" -RoleDefinitionName "Owner" -ErrorAction SilentlyContinue)) {
            Write-Host "Assigning user $($user.UserPrincipalName) as Owner to subscription $($sub.Name) ($($sub.Id))..."
            New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName "Owner" -Scope "/subscriptions/$($sub.Id)" -ErrorAction Stop | Out-Null
        }
        else {
            Write-Host "User $($user.UserPrincipalName) is already assigned as Owner to subscription $($sub.Name) ($($sub.Id))."
        }
        # collect deployment task if labDirectory is specified
        if($labDirectory -ne "") {
            if((Test-Path (Join-Path $labDirectory "deploy-lab.ps1") -PathType Leaf)) {
                $deploymentTasks += @{
                    HackboxTenantId = $user.HackboxTenantId
                    UserPrincipalName = $user.UserPrincipalName
                    UserId = $user.Id
                    SubscriptionId = $sub.Id
                    SubscriptionName = $sub.Name
                }
            }
            else {
                Write-Warning "deploy-lab.ps1 script not found in lab directory $labDirectory. Skipping deployment for user $($user.UserPrincipalName)."
            }
        }

        Start-Sleep -Seconds 1
        $currentUserIndex++
    }

    # Run deployments in parallel using jobs (true process isolation)
    if($deploymentTasks.Count -gt 0) {
        Write-Host "Starting parallel deployment for $($deploymentTasks.Count) users (max $labDeploymentParallelization concurrent jobs)..."
        $labScriptPath = Join-Path $labDirectory "deploy-lab.ps1"
        
        $runningJobs = @()
        $taskIndex = 0
        $completedCount = 0
        
        while($taskIndex -lt $deploymentTasks.Count -or $runningJobs.Count -gt 0) {
            # Start new jobs up to the limit
            while($runningJobs.Count -lt $labDeploymentParallelization -and $taskIndex -lt $deploymentTasks.Count) {
                $task = $deploymentTasks[$taskIndex]
                Write-Host "[Job $($taskIndex + 1)/$($deploymentTasks.Count)] Starting deployment for user $($task.UserPrincipalName) in subscription $($task.SubscriptionName)..."
                
                $job = Start-Job -ScriptBlock {
                    param($labScriptPath, $deploymentType, $subscriptionId, $preferredLocation, $userId, $maxSleepDelay)
                    
                    # Import Az modules
                    foreach($mod in @("Az.Accounts","Az.Resources")) {
                        Import-Module $mod -ErrorAction Stop
                    }
                    # and set context
                    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop -Scope Process | Out-Null

                    # random sleep in milliseconds to reduce contention
                    if($maxSleepDelay -gt 1000) {
                        Start-Sleep -Milliseconds (Get-Random -Minimum 1000 -Maximum $maxSleepDelay)
                    }
                    else {
                        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum $maxSleepDelay)
                    }
                    
                    & $labScriptPath `
                        -DeploymentType $deploymentType `
                        -SubscriptionId $subscriptionId `
                        -PreferredLocation $preferredLocation `
                        -AllowedEntraUserIds @($userId)
                } -ArgumentList $labScriptPath, $deploymentType, $task.SubscriptionId, $preferredLocation, $task.UserId, $maxSleepDelayMilliseconds
                
                $runningJobs += @{ Job = $job; Task = $task; Index = $taskIndex }
                $taskIndex++
            }
            
            # Wait for at least one job to complete
            if($runningJobs.Count -gt 0) {
                $completed = $runningJobs | Where-Object { $_.Job.State -eq 'Completed' -or $_.Job.State -eq 'Failed' }
                
                foreach($item in $completed) {
                    $completedCount++
                    if($item.Job.State -eq 'Failed') {
                        Write-Warning "[Job $($item.Index + 1)] Deployment FAILED for user $($item.Task.UserPrincipalName): $($item.Job.ChildJobs[0].JobStateInfo.Reason)"
                        $credentialConsumer.ConsumeJobOutput((Receive-Job -Job $item.Job -ErrorAction SilentlyContinue), $item.Task.HackboxTenantId)
                    }
                    else {
                        Write-Host "[Job $($item.Index + 1)] Deployment completed for user $($item.Task.UserPrincipalName) ($completedCount/$($deploymentTasks.Count))"
                        $credentialConsumer.ConsumeJobOutput((Receive-Job -Job $item.Job), $item.Task.HackboxTenantId)
                    }
                    Remove-Job -Job $item.Job -Force
                }
                
                $runningJobs = @($runningJobs | Where-Object { $_.Job.State -eq 'Running' })
                
                if($runningJobs.Count -ge $labDeploymentParallelization -or ($taskIndex -ge $deploymentTasks.Count -and $runningJobs.Count -gt 0)) {
                    Start-Sleep -Milliseconds 500
                }
            }
        }
        
        Write-Host "Parallel deployment completed. Total: $completedCount jobs."
    }
}
elseif($deploymentType -eq "resourcegroup" -or $deploymentType -eq "resourcegroup-with-subscriptionowner") {
    Write-Host "Deploying lab resources scoped to resource groups."
    $currentUserIndex = 0
    $deploymentTasks = @()
    foreach($sub in $qualifiedSubscriptions) {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        for($i=0; $i -lt $teamsPerSubscription; $i++) {
            # stop if all users have been assigned
            if($currentUserIndex -ge $users.Count) {
                break
            }
            $user = $users[$currentUserIndex]
            # assign user to this subscription as reader
            $rolename = "Reader"
            if($deploymentType -eq "resourcegroup-with-subscriptionowner") {
                $rolename = "Owner"
            }
            if(-not (Get-AzRoleAssignment -ObjectId $user.Id -Scope "/subscriptions/$($sub.Id)" -RoleDefinitionName $rolename -ErrorAction SilentlyContinue)) {
                Write-Host "Assigning user $($user.UserPrincipalName) as $rolename to subscription $($sub.Name) ($($sub.Id))..."
                New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName $rolename -Scope "/subscriptions/$($sub.Id)" -ErrorAction Stop | Out-Null
            }
            else {
                Write-Host "User $($user.UserPrincipalName) is already assigned as Reader to subscription $($sub.Name) ($($sub.Id))."
            }


            if($skipResourceGroupCreation) {
                $resourceGroupName = "$($user.UserPrincipalName.Split("@")[0].ToLower())"
            }
            else {
                $resourceGroupName = "rg-$($user.UserPrincipalName.Split("@")[0].ToLower())"
                if(-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
                    Write-Host "Creating resource group $resourceGroupName in subscription $($sub.Name) ($($sub.Id))..."
                    if($preferredLocation -ne "") { 
                        $rglocation = $preferredLocation 
                    } 
                    else { 
                        $rglocation = "swedencentral" 
                    }
                    New-AzResourceGroup -Name $resourceGroupName -Location $rglocation -ErrorAction Stop | Out-Null
                }
                else {
                    Write-Host "Resource group $resourceGroupName already exists in subscription $($sub.Name) ($($sub.Id))."
                }
                # assign user to this resource group as owner
                if(-not (Get-AzRoleAssignment -ObjectId $user.Id -Scope "/subscriptions/$($sub.Id)/resourceGroups/$resourceGroupName" -RoleDefinitionName "Owner" -ErrorAction SilentlyContinue)) {
                    Write-Host "Assigning user $($user.UserPrincipalName) as Owner to resource group $resourceGroupName in subscription $($sub.Name) ($($sub.Id))..."
                    New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName "Owner" -Scope "/subscriptions/$($sub.Id)/resourceGroups/$resourceGroupName" -ErrorAction Stop | Out-Null
                }
                else {
                    Write-Host "User $($user.UserPrincipalName) is already assigned as Owner to resource group $resourceGroupName in subscription $($sub.Name) ($($sub.Id))."
                }
            }

            # collect deployment task if labDirectory is specified
            if($labDirectory -ne "") {
                if((Test-Path (Join-Path $labDirectory "deploy-lab.ps1") -PathType Leaf)) {
                    $deploymentTasks += @{
                        HackboxTenantId = $user.HackboxTenantId
                        UserPrincipalName = $user.UserPrincipalName
                        UserId = $user.Id
                        SubscriptionId = $sub.Id
                        SubscriptionName = $sub.Name
                        ResourceGroupName = $resourceGroupName
                    }
                }
                else {
                    Write-Warning "deploy-lab.ps1 script not found in lab directory $labDirectory. Skipping deployment for user $($user.UserPrincipalName)."
                }
            }

            Start-Sleep -Seconds 1

            $currentUserIndex++
        }
    }

    # Run deployments in parallel using jobs (true process isolation)
    if($deploymentTasks.Count -gt 0) {
        Write-Host "Starting parallel deployment for $($deploymentTasks.Count) users (max $labDeploymentParallelization concurrent jobs)..."
        $labScriptPath = Join-Path $labDirectory "deploy-lab.ps1"
        
        $runningJobs = @()
        $taskIndex = 0
        $completedCount = 0
        
        while($taskIndex -lt $deploymentTasks.Count -or $runningJobs.Count -gt 0) {
            # Start new jobs up to the limit
            while($runningJobs.Count -lt $labDeploymentParallelization -and $taskIndex -lt $deploymentTasks.Count) {
                $task = $deploymentTasks[$taskIndex]
                Write-Host "[Job $($taskIndex + 1)/$($deploymentTasks.Count)] Starting deployment for user $($task.UserPrincipalName) in subscription $($task.SubscriptionName)..."
                
                $job = Start-Job -ScriptBlock {
                    param($labScriptPath, $deploymentType, $subscriptionId, $resourceGroupName, $preferredLocation, $userId, $maxSleepDelay)
                    
                    # Import Az modules
                    foreach($mod in @("Az.Accounts","Az.Resources")) {
                        Import-Module $mod -ErrorAction Stop
                    }
                    # and set context
                    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop -Scope Process | Out-Null

                    # random sleep in milliseconds to reduce contention
                    if($maxSleepDelay -gt 1000) {
                        Start-Sleep -Milliseconds (Get-Random -Minimum 1000 -Maximum $maxSleepDelay)
                    }
                    else {
                        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum $maxSleepDelay)
                    }
                    
                    & $labScriptPath `
                        -DeploymentType $deploymentType `
                        -SubscriptionId $subscriptionId `
                        -ResourceGroupName $resourceGroupName `
                        -PreferredLocation $preferredLocation `
                        -AllowedEntraUserIds @($userId)
                } -ArgumentList $labScriptPath, $deploymentType, $task.SubscriptionId, $task.ResourceGroupName, $preferredLocation, $task.UserId, $maxSleepDelayMilliseconds
                
                $runningJobs += @{ Job = $job; Task = $task; Index = $taskIndex }
                $taskIndex++
            }
            
            # Wait for at least one job to complete
            if($runningJobs.Count -gt 0) {
                $completed = $runningJobs | Where-Object { $_.Job.State -eq 'Completed' -or $_.Job.State -eq 'Failed' }
                
                foreach($item in $completed) {
                    $completedCount++
                    if($item.Job.State -eq 'Failed') {
                        Write-Warning "[Job $($item.Index + 1)] Deployment FAILED for user $($item.Task.UserPrincipalName): $($item.Job.ChildJobs[0].JobStateInfo.Reason)"
                        $credentialConsumer.ConsumeJobOutput((Receive-Job -Job $item.Job -ErrorAction SilentlyContinue), $item.Task.HackboxTenantId)
                    }
                    else {
                        Write-Host "[Job $($item.Index + 1)] Deployment completed for user $($item.Task.UserPrincipalName) ($completedCount/$($deploymentTasks.Count))"
                        $credentialConsumer.ConsumeJobOutput((Receive-Job -Job $item.Job), $item.Task.HackboxTenantId)
                    }
                    Remove-Job -Job $item.Job -Force
                }
                
                $runningJobs = @($runningJobs | Where-Object { $_.Job.State -eq 'Running' })
                
                if($runningJobs.Count -ge $labDeploymentParallelization -or ($taskIndex -ge $deploymentTasks.Count -and $runningJobs.Count -gt 0)) {
                    Start-Sleep -Milliseconds 500
                }
            }
        }
        
        Write-Host "Parallel deployment completed. Total: $completedCount jobs."
    }
}

Write-Host ("Exporting created lab credentials to " + (Join-Path $consoleRoot "createdLabUserSettings.json"))
$credentialConsumer.jsonifyCredentials() | Out-File (Join-Path $consoleRoot "createdLabUserSettings.json") -Encoding UTF8
