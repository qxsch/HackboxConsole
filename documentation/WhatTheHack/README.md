# WhatTheHack Documentation

Run a [WhatTheHack](https://github.com/microsoft/WhatTheHack) hackathon with the Hackathon Console.

> [!NOTE]
> **59+ hacks are supported.** Some hacks (~12) are not supported. (Unsupported hacks are usually using word or powerpoint files instead of markdown.)
> Use the chooseMicroHack.ps1 script to find the supported hacks and their details.


## Prerequisites
 - Powershell 7+
 - Azure Az Module
 - Git
 - Azure Subscription
 - Bicep installed ( https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install#install-manually )
 - This repository cloned (``git clone https://github.com/qxsch/HackboxConsole.git``)


## Execution Steps

1. Choose a hack
   ```pwsh
   .\documentation\WhatTheHack\chooseWhatTheHack.ps1 | Format-Table Name, RelativePath, HackVariants
   ```
   
1. Prepare the environment for the chosen hack
   ```pwsh
   .\documentation\WhatTheHack\chooseWhatTheHack.ps1 -HackName "001-IntroToKubernetes"
   # some hacks offer variants, e.g. "A" or "B" or "C" or "D" for "001-IntroToKubernetes"
   # .\documentation\WhatTheHack\chooseWhatTheHack.ps1 -HackName "001-IntroToKubernetes" -HackVariant "B"
   ```
   
1. Create the Hackathon Console Users (in this example, we prepare logins for 4 teams with a single coach for each team)
   ```pwsh
   .\iac\createUsers.ps1 -numberOfTenants 4 -createCsvFiles
   # there are users-coaches.csv and users-hackers.csv, that you can use to share with the participants and coaches
   ```

1. Deploy to Azure
   ```pwsh
   # we use -doNotCopyChallengesOrSolutions, because the above steps already copied everything to the right place
   .\iac\deployHackerConsole.ps1 -doNotCopyChallengesOrSolutions
   ```

1. Check the users.json file for the logins of the teams and coaches

1. To Setup a pre-built environment for the hack:
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
