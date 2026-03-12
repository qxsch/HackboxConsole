# Generic Documentation

Generic Build Instructions

## Prerequisites
 - Powershell 7+
 - Azure Az Module
 - Git
 - Azure Subscription
 - Bicep installed ( https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install#install-manually )
 - This repository cloned (``git clone https://github.com/qxsch/HackboxConsole.git``)
 - You have:
   * a **challenges directory**: It containts ``*challenge*.md`` files (can also be within subdirectories).
   * a **solutions directory**: It containts ``*solution*.md`` files (can also be within subdirectories).
   * an optional **lab directory**: It contains:
     - an optional [quota-requests.csv](../../iac/sample-lab/quota-requests.csv) file defining the required Azure resources per subscription
     - an optional [deploy-lab.ps1](../../iac/sample-lab/deploy-lab.ps1) script to deploy the environments per team (subscription or resource group based deployment)


## Execution Steps

1. Create the Hackathon Console Users (in this example, we prepare logins for 4 teams with a single coach for each team)
   ```pwsh
   .\iac\createUsers.ps1 -numberOfTenants 4 -createCsvFiles
   # there are users-coaches.csv and users-hackers.csv, that you can use to share with the participants and coaches
   ```

1. Build the Hackathon Console and deploy it to Azure
   ```pwsh
   # select the appropriate subscription for the management resources
   Select-AzSubscription -SubscriptionId "management"
   # -SourceLabDir is optional, so:
   # either deploy the Hackathon Console WITH lab provisioning
   .\iac\deployHackerConsole.ps1 `
      -SourceChallengesDir C:\path\to\directory\challenges\ `
      -SourceSolutionsDir C:\path\to\directory\solutions\ `
      -SourceLabDir C:\path\to\directory\lab\
   # or deploy WITHOUT lab provisioning
   .\iac\deployHackerConsole.ps1 `
      -SourceChallengesDir C:\path\to\directory\challenges\ `
      -SourceSolutionsDir C:\path\to\directory\solutions\
   ```

1. Check the users.json file for the logins of the teams and coaches

1. $\color{#D29922}\textsf{\Large\kern{0.2cm}\normalsize(Optional)}$ In case you want to run it within pre-built environments:
   1. Weeks before the Event
      1. Create the lab users:
         > [!IMPORTANT]  
         > Please follow this guide to enable the TAP and set the maximum lifetime in days to satisfy the hackathon duration: [Temporary Access Pass (TAP) authentication method](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)

         ```pwsh
         $startDate = Get-Date "2025-12-12 08:00"
         $stopDate =  Get-Date -Date $startDate.addDays(2) -Hour 16
         # verify the dates
         Write-Host "Hackathon Start Date: $startDate"
         Write-Host "Hackathon Stop Date: $stopDate"
         # create the users in Entra ID
         # if you have a No Mfa group, add f.e. -additionalGroupnames @("NoMfaEnforcement") to the command below
         .\iac\azure\createEntraIdUsers.ps1 -hackathonStartDate $startDate -hackathonEndDate $stopDate
         ```

      1. Publish the user credentials to the Hackathon Console:
         ```pwsh
         # select the appropriate subscription for the management resources
         Select-AzSubscription -SubscriptionId "management"
         # deploy the Hackathon Console
         Get-Content .\createdEntraIdUserSettings.json | ConvertFrom-Json | .\iac\addMultipleCredentials.ps1
         ```

      1. Prepare the quota requests (if applicable):
         > [!IMPORTANT]  
         > Do not forget to edit the csv file, in case you host multiple teams per subscription!!
         
         ```pwsh
         # submitting the quota requests from the csv file (optionally use: -csvFilePath .\quotaRequests.csv)
         .\iac\azure\processQuotaRequests.ps1
         ```

   1. Multiple Days before the Event
      1. Deploy the lab environments:
         ```pwsh
         # for a resource group based deployment (multiple teams per subscription)
         .\iac\azure\deployLabEnvironments.ps1 -managementGroupId "labsubscriptions" -subscriptionPrefix "traininglab-" -deploymentType "resourcegroup" -teamsPerSubscription 4
         # or for subscription based deployments
         .\iac\azure\deployLabEnvironments.ps1 -managementGroupId "labsubscriptions" -subscriptionPrefix "traininglab-" -deploymentType "subscription"
         ```
      1. Publish the lab user credentials to the Hackathon Console (in case the deploy-lab.ps1 script created entries):
         ```pwsh
         # check if the createdLabUserSettings.json file exists
         Test-Path .\createdLabUserSettings.json
         # select the appropriate subscription for the management resources
         Select-AzSubscription -SubscriptionId "management"
         # deploy the Hackathon Console
         Get-Content .\createdLabUserSettings.json | ConvertFrom-Json | .\iac\addMultipleCredentials.ps1
         ```
      1. Test if everything is working as expected (resources got deployed, ...)

   1. After the Event
      1. Delete the lab environments:
         ```pwsh
            # as an alternative you can also delete all the resource groups
            .\iac\azure\removeAllResourceGroupsFromSubscriptions.ps1 -managementGroupId "labsubscriptions" -subscriptionPrefix "traininglab-"
         ```

      1. Delete old user accounts (if any):
         ```pwsh
         # delete old users
         .\iac\azure\deleteEntraIdUsers.ps1 -purgeUsers
         # remove orphaned role assignments
         .\iac\azure\removeOrphanedRoleAssignments.ps1 -includeResourceGroups
         ```

1. Collect the time tracking data for your participants after the event:
   ```pwsh
   # select the appropriate subscription for the management resources
   Select-AzSubscription -SubscriptionId "management"
   # collect the timing data
   .\iac\getTimings.ps1
   # do something useful with the timings.csv file
   # f.e. import it into Excel or PowerBI for further analysis on how to improve your next event
   ```
