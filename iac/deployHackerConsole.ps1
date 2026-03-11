param (
    [string]$SourceChallengesDir = "",
    [string]$SourceSolutionsDir = "",
    [string]$SourceLabDir = "",
    [string]$ResourceGroupName = "HackConsole",

    [string]$location = $null,
    [string]$webAppName = $null,
    [string]$sku = $null,
    [string]$workerSize = $null,
    [switch]$useStorageAccountKeys,
    [switch]$usePublicEndpoints,

    [string]$hackerUsername = "",
    [securestring]$hackerPassword = $null,
    [string]$coachUsername = "",
    [securestring]$coachPassword = $null,

    [switch]$doNotCopyChallengesOrSolutions,
    [switch]$doNotCleanUp,


    # RDP Integration
    [switch]$deployRdpIntegration,
    [string]$rdpResourceGroupName = "HackConsole-RDP",
    [string]$rdpAcrName = $null,
    [ValidateSet('0.5Gi', '1.0Gi', '1.5Gi', '2.0Gi', '2.5Gi', '3.0Gi', '3.5Gi', '4.0Gi', '6.0Gi', '8.0Gi')]
    [string]$rdpContainerMemory = '4.0Gi',
    [int]$rdpConcurrentRequests = 20,
    [int]$rdpMinReplicas = 1,
    [int]$rdpMaxReplicas = 10,

    # RDP VM Deployment
    [switch]$deployRdpVms,
    [bool]$rdpVmByol = $false
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$consoleRoot = Split-Path -Parent $scriptPath

if(-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Force
}
Import-Module Az.Accounts
Import-Module Az.Websites
Import-Module Az.Resources

# use the following Git Tag
$rdpGitTag = "v3.7.1"
$branchHash = ""

# rdp vm deployment requires rdp integration
if($deployRdpVms) {
    $deployRdpIntegration = $true
}

if(-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -UseDeviceAuthentication
}

# Install required PowerShell modules
if((-not (Get-Command bicep.exe -ErrorAction SilentlyContinue)) -and (-not (Get-Command bicep -ErrorAction SilentlyContinue))) {
    Write-Error "Bicep CLI not found. Go to: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install#azure-powershell"
    throw "Bicep CLI not found. Please install Bicep CLI and make sure it is in your PATH."
}

# does the file exist?
if(-not (Test-Path (Join-Path $consoleRoot "users.json") -PathType Leaf)) {
    if($hackerUsername -eq "" -or $coachUsername -eq "" -or $hackerPassword -eq $null -or $coachPassword -eq $null) {
         throw "Either provide the users.json file or provide all four parameters: hackerUsername, hackerPassword, coachUsername, coachPassword"
    }
    if($deployRdpIntegration -or $deployRdpVms) {
        throw "RDP Integration or RDP VM deployment requested, but users.json file is not present. Please provide the users.json file for RDP deployments."
    }
}
else {
    if($hackerUsername -ne "" -or $coachUsername -ne "" -or $hackerPassword -ne $null -or $coachPassword -ne $null) {
        Write-Warning "Both users.json file and user parameters provided. The users.json file will be used."
    }
    # use defaults for template / they will be ignored by the application if users.json is present
    $hackerUsername = "hacker"
    $hackerPassword = ConvertTo-SecureString -String "hackerPassword" -AsPlainText -Force
    $coachUsername = "coach"
    $coachPassword = ConvertTo-SecureString -String "coachPassword" -AsPlainText -Force
}

if(-not $doNotCopyChallengesOrSolutions) {
    if($SourceChallengesDir -eq "") {
        throw "SourceChallengesDir must be provided"
    }
    if($SourceSolutionsDir -eq "") {
        throw "SourceSolutionsDir must be provided"
    }
    if(-not (Test-Path $SourceChallengesDir -PathType Container)) {
        throw "SourceChallengesDir must be a directory"
    }
    if(-not (Test-Path $SourceSolutionsDir -PathType Container)) {
        throw "SourceSolutionsDir must be a directory"
    }
    Write-Host "Copying challenges and solutions to the console"
    # remove the challenges directory
    Remove-Item -Path (Join-Path $consoleRoot "hack_console" "challenges") -Recurse -Force
    # remove the solutions directory
    Remove-Item -Path (Join-Path $consoleRoot "hack_console" "solutions") -Recurse -Force
    # copy the challenges to the console
    Copy-Item -Path $SourceChallengesDir -Destination (Join-Path $consoleRoot "hack_console" "challenges") -Recurse
    # copy the solutions to the console
    Copy-Item -Path $SourceSolutionsDir -Destination (Join-Path $consoleRoot "hack_console" "solutions") -Recurse

    # remove the lab directory if it exists and a source lab directory is provided
    if((Test-Path (Join-Path $consoleRoot "iac" "lab") -PathType Container)) {
        Remove-Item -Path (Join-Path $consoleRoot "iac" "lab") -Recurse -Force
    }
    # copy the lab directory, if a source lab directory is provided
    if($SourceLabDir -ne "" -and (Test-Path $SourceLabDir -PathType Container)) {
        Copy-Item -Path $SourceLabDir -Destination (Join-Path $consoleRoot "iac" "lab") -Recurse
    }
}
if(-not (Test-Path (Join-Path $consoleRoot "hack_console" "challenges") -PathType Container)) {
    throw "Challenges directory not found"
}
if(-not (Test-Path (Join-Path $consoleRoot "hack_console" "solutions") -PathType Container)) {
    throw "Solutions directory not found"
}
# no md files pattern challenge-*.md in the challenges directory (recursively)
$challengeMdFileCount = (Get-ChildItem -Path (Join-Path $consoleRoot "hack_console" "challenges") -Recurse -Filter "*challenge*.md").Count
Write-Host "  - Found $challengeMdFileCount challenges md files"
if($challengeMdFileCount -eq 0) {
    throw "No challenges md files found in the challenges directory"
}
$solutionMdFileCount = (Get-ChildItem -Path (Join-Path $consoleRoot "hack_console" "solutions") -Recurse -Filter "*solution*.md").Count
Write-Host "  - Found $solutionMdFileCount solutions md files"
if($solutionMdFileCount  -eq 0) {
    throw "No solutions md files found in the solutions directory"
}
if($challengeMdFileCount -ne $solutionMdFileCount) {
    Write-Warning "The number of challenges md files does not match the number of solutions md files"
}

Write-Host "Removing all __pycache__ directories"
Get-ChildItem -Path (Join-Path $consoleRoot "hack_console") -Recurse -Directory -Filter "__pycache__" | ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force }

# Deploy RDP Backend if requested
$rdpBackendUrls = ""  # default: no RDP backend
if($deployRdpIntegration) {
    if($branchHash -eq "") {
        $branchHash = (git ls-remote --tags https://github.com/qxsch/freerdp-web.git $rdpGitTag).Split("`t")[0]
    }
    if($branchHash -eq "") {
        throw "Could not find RDP Git Tag $rdpGitTag"
    }
    Write-Host "Creating the RDP Backend infrastructure - Using RDP branch $rdpGitTag with hash $branchHash"

    if(-not (Get-AzResourceGroup -Name $rdpResourceGroupName -ErrorAction SilentlyContinue)) {
        Write-Host -ForegroundColor "Yellow" "Creating Resource Group $rdpResourceGroupName"
        if($null -eq $location -or $location -eq "") {
            New-AzResourceGroup -Name $rdpResourceGroupName -Location "Sweden Central" | Out-Null
        }
        else {
            New-AzResourceGroup -Name $rdpResourceGroupName -Location $location | Out-Null
        }
    }

    $rdpParams = @{
        TemplateFile = (Join-Path $scriptPath "bicep" "deployment-rdp.bicep")
        ResourceGroupName = $rdpResourceGroupName
        containerMemory = $rdpContainerMemory
        concurrentRequests = $rdpConcurrentRequests
        minReplicas = $rdpMinReplicas
        maxReplicas = $rdpMaxReplicas
    }
    if(-not($null -eq $location -or $location -eq "")) {
        $rdpParams["location"] = $location
    }
    if(-not($null -eq $rdpAcrName -or $rdpAcrName -eq "")) {
        $rdpParams["acrName"] = $rdpAcrName
    }
    $rdpDeployment = New-AzResourceGroupDeployment @rdpParams -Name "rdpbackend"  -ErrorAction Continue -ErrorVariable +evx
    if($null -eq $rdpDeployment) {
        foreach($ev in $evx) {
            if($ev.Exception.Message.Contains('soft-deleted')) {
                Write-Host -ForegroundColor Yellow "Soft deleted resource found:`n$($ev.Exception.Message)"
            }
            elseif($ev.Exception.Message.Contains('quota')) {
                Write-Host -ForegroundColor Yellow "Quota exceeded:`n$($ev.Exception.Message)"
            }
        }
        throw "RDP Backend Deployment failed"
    }
    if($rdpDeployment.ProvisioningState -ne "Succeeded") {
        throw "RDP Backend Deployment failed with provisioning state: " + $rdpDeployment.ProvisioningState
    }


    Write-Host "RDP Backend Deployment completed"
    Write-Host ( "  - RDP Backend URL:      " + $rdpDeployment.Outputs.containerAppUrl.Value )
    Write-Host ( "  - VM Subnet ID:         " + $rdpDeployment.Outputs.vmSubnetId.Value )
    # string contains comma-separated list of RDP Backend URLs
    $rdpBackendUrls = $rdpDeployment.Outputs.containerAppUrl.Value
}



if(-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Host -ForegroundColor "Yellow" "Creating Resource Group $ResourceGroupName"
    if($null -eq $location -or $location -eq "") {
        New-AzResourceGroup -Name $ResourceGroupName -Location "Sweden Central" | Out-Null
    }
    else {
        New-AzResourceGroup -Name $ResourceGroupName -Location $location | Out-Null
    }
}

# run the bicep deployment
Write-Host ( "Deploying the hacker console to Resource Group $ResourceGroupName (Subscription: " + ((Get-AzContext).Subscription.Id) + ")" )
$params = @{
    TemplateFile = (Join-Path $scriptPath "bicep" "deployment.bicep")
    ResourceGroupName = $ResourceGroupName
    hackerUsername = $hackerUsername
    hackerPassword = $hackerPassword
    coachUsername = $coachUsername
    coachPassword = $coachPassword
    rdpBackendUrls = $rdpBackendUrls
}
if($useStorageAccountKeys) {
    Write-Host "Using Storage Account Keys for storage access"
    $params["useStorageAccountKeys"] = $true
}
else {
    Write-Host "Using Managed Identity for storage access"
    $params["useStorageAccountKeys"] = $false
}
if($usePublicEndpoints) {
    Write-Host "Using Public Endpoints for resources"
    $params["usePrivateEndpoints"] = $false
}
else {
    Write-Host "Using Private Endpoints for resources"
    $params["usePrivateEndpoints"] = $true
}
if(-not($null -eq $location -or $location -eq "")) {
    $params["location"] = $location
}
if(-not($null -eq $webAppName -or $webAppName -eq "")) {
    $params["webAppName"] = $webAppName
}
if(-not($null -eq $sku -or $sku -eq "")) {
    Write-Host "Setting sku to $sku"
    $params["sku"] = $sku
}
if(-not($null -eq $workerSize -or $workerSize -eq "")) {
    $params["workerSize"] = $workerSize
}
$deployment = New-AzResourceGroupDeployment @params -Name "hackboxconsole"  -ErrorAction Continue -ErrorVariable +evx
if($null -eq $deployment) {
    foreach($ev in $evx) {
        if($ev.Exception.Message.Contains('soft-deleted')) {
            Write-Host -ForegroundColor Yellow "Soft deleted resource found:`n$($ev.Exception.Message)"
        }
        elseif($ev.Exception.Message.Contains('quota')) {
            Write-Host -ForegroundColor Yellow "Quota exceeded:`n$($ev.Exception.Message)"
        }
    }
    throw "Hackbox Console Deployment failed"
}
if($deployment.ProvisioningState -ne "Succeeded") {
    throw "Hackbox Console Deployment failed with provisioning state: " + $deployment.ProvisioningState
}

Write-Host "Hackbox Console Deployment completed"
Write-Host ( "  - Web App Name:         " + $deployment.Outputs.webAppName.Value )
Write-Host ( "  - Web App URL:          https://" + $deployment.Outputs.webAppUrl.Value )
Write-Host ( "  - Storage Account Name: " + $deployment.Outputs.storageAccountName.Value )



# always start with a clean RDP integration directory
$rdpExtractedPath = Join-Path $consoleRoot "hack_console" "static" "freerdp-web"
if(Test-Path -Path $rdpExtractedPath) {
    Remove-Item -Path $rdpExtractedPath -Recurse -Force | Out-Null
}
# Integrating RDP Web Client if requested
if($deployRdpIntegration) {
    Write-Host "Creating  RDP Integration Frontend files - Using RDP Git Release $rdpGitTag"
    $rdpZipPath = Join-Path $consoleRoot "freerdp-web.zip"
    Invoke-WebRequest -Uri "https://github.com/qxsch/freerdp-web/releases/download/$rdpGitTag/frontendbuild.zip" -OutFile $rdpZipPath

    # create directory
    New-Item -ItemType Directory -Path $rdpExtractedPath | Out-Null

    # extract the zip file
    Expand-Archive -Path $rdpZipPath -DestinationPath $rdpExtractedPath -Force
    # remove the zip file
    Remove-Item -Path $rdpZipPath -Force | Out-Null
    # remove index.html if it exists
    Remove-Item -Path (Join-Path $rdpExtractedPath "index.html") -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}


# deploying the zip package
Write-Host "Creating the zip package"
$zipPackagePath = Join-Path $scriptPath "hack_console.zip"
if(Test-Path $zipPackagePath) {
    Remove-Item $zipPackagePath -Force
}
Get-ChildItem $consoleRoot | Where-Object { $_.Name -notin @( "iac", "createdEntraIdUserSettings.json" ) -and (-not $_.Name.EndsWith('.csv')) } | Compress-Archive -DestinationPath $zipPackagePath
Write-Host "Publishing the zip package to the web app"
Publish-AzWebApp -ResourceGroupName $ResourceGroupName -Name $deployment.Outputs.webAppName.Value -ArchivePath $zipPackagePath -Force -ErrorAction Stop | Out-Null



if(-not $doNotCleanUp) {
    Write-Host "Cleaning up"
    # clean up the zip package
    Remove-Item -Path $zipPackagePath -Force | Out-Null

    # just clean up the challenges and solutions directories, in case they got copied before
    if(-not $doNotCopyChallengesOrSolutions) {
        # clean up the challenges directory
        Remove-Item -Path (Join-Path $consoleRoot "hack_console" "challenges") -Recurse -Force | Out-Null
        New-Item -Path (Join-Path $consoleRoot "hack_console" "challenges") -ItemType Directory | Out-Null
        New-Item -Path (Join-Path $consoleRoot "hack_console" "challenges" ".gitkeep") -ItemType File | Out-Null

        # clean up the solutions directory
        Remove-Item -Path (Join-Path $consoleRoot "hack_console" "solutions") -Recurse -Force | Out-Null
        New-Item -Path (Join-Path $consoleRoot "hack_console" "solutions") -ItemType Directory | Out-Null
        New-Item -Path (Join-Path $consoleRoot "hack_console" "solutions" ".gitkeep") -ItemType File | Out-Null

        # clean up the lab directory
        Remove-Item -Path (Join-Path $consoleRoot "iac" "lab") -Recurse -Force | Out-Null
    }
}



<#
if($deployRdpVms -and $deployRdpIntegration) {
    $definedUsers = @()
    if(Test-Path (Join-Path $consoleRoot "users.json") -PathType Leaf) {
        $definedUsers = Get-Content (Join-Path $consoleRoot "users.json") | ConvertFrom-Json | Where-Object { ([string]$_.role).ToLower().Trim() -in @( "hacker", "coach" ) }
    }
    # query the currently deployed RDP
    $connections = & (Join-Path $scriptPath "getAllCredentials.ps1") -ResourceGroupName $ResourceGroupName -TableName = "connections"


    # do we have any users defined for RDP VM access?
    if($definedUsers.Count -gt 0) {

        $rdpParams = @{
            TemplateFile = (Join-Path $scriptPath "bicep" "deployment-multivms.bicep")
            ResourceGroupName = $rdpResourceGroupName
            byol = $rdpVmByol
            virtualNetworkSubnetId = $rdpDeployment.Outputs.vmSubnetId.Value
            minReplicas = $rdpMinReplicas
            maxReplicas = $rdpMaxReplicas
            userVms = $definedUsers
        }
        if(-not($null -eq $location -or $location -eq "")) {
            $rdpParams["location"] = $location
        }
        $rdpVmDeployment = New-AzResourceGroupDeployment @rdpParams -Name "rdpvms"  -ErrorAction Continue -ErrorVariable +evx
        if($null -eq $rdpVmDeployment) {
            foreach($ev in $evx) {
                if($ev.Exception.Message.Contains('soft-deleted')) {
                    Write-Host -ForegroundColor Yellow "Soft deleted resource found:`n$($ev.Exception.Message)"
                }
                elseif($ev.Exception.Message.Contains('quota')) {
                    Write-Host -ForegroundColor Yellow "Quota exceeded:`n$($ev.Exception.Message)"
                }
            }
            throw "RDP Backend Deployment failed"
        }
        if($rdpVmDeployment.ProvisioningState -ne "Succeeded") {
            throw "RDP VM Deployment failed with provisioning state: " + $rdpVmDeployment.ProvisioningState
        }


        Write-Host "RDP Backend Deployment completed"
        #Write-Host ( "  - xyz:      " + $rdpVmDeployment.Outputs.xyz.Value )
        #Write-Host ( "  - abc:         " + $rdpVmDeployment.Outputs.abc.Value )    
        Write-Host "RDP VM Deployment completed. Please use the RDP Backend URL to connect to the RDP VMs from the Hacker Console."



    }
    else {
        Write-Host -ForegroundColor Yellow "No users defined for RDP VM access. Please make sure to provide a users.json file with hacker and coach users for RDP VM access."
    }
}
#>

Write-Host -ForegroundColor Green ( "URL:  https://" + $deployment.Outputs.webAppUrl.Value )
