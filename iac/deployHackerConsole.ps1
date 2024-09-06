param (
    [Parameter(Mandatory = $true)]
    [string]$SourceChallengesDir,
    [Parameter(Mandatory = $true)]
    [string]$SourceSolutionsDir,
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$location = $null,
    [string]$webAppName = $null,
    [string]$sku = $null,
    [string]$workerSize = $null,

    [Parameter(Mandatory = $true)]
    [string]$hackerUsername,
    [Parameter(Mandatory = $true)]
    [securestring]$hackerPassword,
    [Parameter(Mandatory = $true)]
    [string]$coachUsername,
    [Parameter(Mandatory = $true)]
    [securestring]$coachPassword,


    [switch]$doNotCleanUp
)


$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$consoleRoot = Split-Path -Parent $scriptPath

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
Copy-Item -Path $SourceChallengesDir -Destination (Join-Path $consoleRoot "hack_console" ) -Recurse
# copy the solutions to the console
Copy-Item -Path $SourceSolutionsDir -Destination (Join-Path $consoleRoot "hack_console" ) -Recurse
if(-not (Test-Path (Join-Path $consoleRoot "hack_console" "challenges") -PathType Container)) {
    throw "Challenges directory not found"
}
if(-not (Test-Path (Join-Path $consoleRoot "hack_console" "solutions") -PathType Container)) {
    throw "Solutions directory not found"
}
# no md files pattern challenge-*.md in the challenges directory (recursively)
$challengeMdFileCount = (Get-ChildItem -Path (Join-Path $consoleRoot "hack_console" "challenges") -Recurse -Filter "challenge-*.md").Count
Write-Host "  - Found $challengeMdFileCount challenges md files"
if($challengeMdFileCount -eq 0) {
    throw "No challenges md files found in the challenges directory"
}
$solutionMdFileCound = (Get-ChildItem -Path (Join-Path $consoleRoot "hack_console" "solutions") -Recurse -Filter "solution-*.md").Count
Write-Host "  - Found $solutionMdFileCound solutions md files"
if($solutionMdFileCound  -eq 0) {
    throw "No solutions md files found in the solutions directory"
}
if($challengeMdFileCount -ne $solutionMdFileCound) {
    Write-Warning "The number of challenges md files does not match the number of solutions md files"
}



# run the bicep deployment
Write-Host ( "Deploying the hacker console to Resource Group $ResourceGroupName (Subscription: " + ((Get-AzContext).Subscription.Id) + ")" )
$params = @{
    TemplateFile = (Join-Path $scriptPath "deployment.bicep")
    ResourceGroupName = $ResourceGroupName
    hackerUsername = $hackerUsername
    hackerPassword = $hackerPassword
    coachUsername = $coachUsername
    coachPassword = $coachPassword
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
$deployment = New-AzResourceGroupDeployment @params -ErrorAction Stop
Write-Host "Deployment completed"
Write-Host ( "  - Web App Name:         " + $deployment.Outputs.webAppName.Value )
Write-Host ( "  - Web App URL:          https://" + $deployment.Outputs.webAppUrl.Value )
Write-Host ( "  - Storage Account Name: " + $deployment.Outputs.storageAccountName.Value )



# deploying the zip package
Write-Host "Creating the zip package"
$zipPackagePath = Join-Path $scriptPath "hack_console.zip"
if(Test-Path $zipPackagePath) {
    Remove-Item $zipPackagePath -Force
}
Get-ChildItem . | Where-Object { $_.Name -notin @( "iac" ) } | Compress-Archive -DestinationPath $zipPackagePath
Write-Host "Publishing the zip package to the web app"
Publish-AzWebApp -ResourceGroupName $ResourceGroupName -Name $deployment.Outputs.webAppName.Value -ArchivePath $zipPackagePath -Force -ErrorAction Stop | Out-Null



if(-not $doNotCleanUp) {
    Write-Host "Cleaning up"
    # clean up the zip package
    Remove-Item -Path $zipPackagePath -Force | Out-Null

    # clean up the challenges directory
    Remove-Item -Path (Join-Path $consoleRoot "hack_console" "challenges") -Recurse -Force | Out-Null
    New-Item -Path (Join-Path $consoleRoot "hack_console" "challenges") -ItemType Directory | Out-Null
    New-Item -Path (Join-Path $consoleRoot "hack_console" "challenges" ".gitkeep") -ItemType File | Out-Null

    # clean up the solutions directory
    Remove-Item -Path (Join-Path $consoleRoot "hack_console" "solutions") -Recurse -Force | Out-Null
    New-Item -Path (Join-Path $consoleRoot "hack_console" "solutions") -ItemType Directory | Out-Null
    New-Item -Path (Join-Path $consoleRoot "hack_console" "solutions" ".gitkeep") -ItemType File | Out-Null
}


Write-Host -ForegroundColor Green ( "URL:  https://" + $deployment.Outputs.webAppUrl.Value )
