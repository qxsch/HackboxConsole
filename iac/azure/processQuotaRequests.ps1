<#
.SYNOPSIS
Submits Azure quota increase tickets for matching subscriptions using a CSV manifest.

.DESCRIPTION
Imports quota request rows from the supplied CSV, validates required fields, and creates support tickets for each eligible subscription filtered by optional management group and prefix settings.

.PARAMETER csvFilePath
Path to the CSV file describing quota requests. (Columns: QuotaType, ServiceType, Location, PricingPlan, NewLimit, DeploymentType, SKU, vCoreLimit, SubnetLimit)

.PARAMETER ContactPreferredTimeZone
Time zone to include in the support contact metadata (defaults to UTC).

.PARAMETER ContactPreferredLanguage
Preferred support language code (defaults to en-US).

.PARAMETER ContactCountry
Country/region for the support contact (defaults to USA).

.PARAMETER managementGroupId
Optional management group ID used to further filter subscriptions.

.PARAMETER subscriptionPrefix
Subscription name prefix used to scope which enabled subscriptions are processed (defaults to traininglab-).

.PARAMETER noAutoDiscoveredLab
If set, disables auto-discovery of the quota request CSV file in the expected lab directory location.
If the csvFilePath parameter is provided, this switch is ignored.

.EXAMPLE
PS> .\processQuotaRequests.ps1 -csvFilePath .\quotaRequests.csv -subscriptionPrefix "traininglab-"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$csvFilePath,

    [ValidateNotNullOrEmpty()]
    [string]$ContactPreferredTimeZone = "UTC",

    [ValidatePattern('^[a-z]{2}-[A-Z]{2}$')]
    [string]$ContactPreferredLanguage = "en-US",

    [ValidateNotNullOrEmpty()]
    [string]$ContactCountry = "USA",

    [string]$managementGroupId = "",
    [string]$subscriptionPrefix = "traininglab-",

    [switch]$noAutoDiscoveredLab
)

if($csvFilePath -eq "" -and (-not $noAutoDiscoveredLab)) {
    try {
        $csvFilePath = (Join-Path (Get-Item "$PSScriptRoot/..").FullName "lab" "quota-requests.csv") 
        if((Test-Path -Path $csvFilePath -PathType Leaf)) {
            Write-Host "Auto-discovered quota request CSV at: $csvFilePath"
        }
        else {
            $csvFilePath = ""
        }
    }
    catch {
        $csvFilePath = ""
    }
}

if(-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Force
}
Import-Module Az -ErrorAction Stop

if(-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -UseDeviceAuthentication
}

Import-Module "Microsoft.Graph.Authentication"  -ErrorAction Stop
if(-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-Warning "Connecting to Microsoft Graph..."
    Connect-MgGraph -UseDeviceCode
}

$me = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/me?$select=id,displayName,givenName,surname,mail,userPrincipalName,jobTitle,mobilePhone,officeLocation,preferredLanguage,companyName'
if($null -eq $me) {
    throw "Failed to retrieve user information from Microsoft Graph."
}
# first name
$ContactFirstName = ""
if(-not [string]::IsNullOrEmpty($me.givenName)) {
    $ContactFirstName = $me.givenName
}
if([string]::IsNullOrEmpty($ContactFirstName)) {
    $ContactFirstName = $me.displayName.Split(" ")[0]
    # still empty?
    if([string]::IsNullOrEmpty($ContactFirstName)) {
        $ContactFirstName = "Automation"
    }
}
# last name
$ContactLastName = ""
if(-not [string]::IsNullOrEmpty($me.surname)) {
    $ContactLastName = $me.surname
}
if([string]::IsNullOrEmpty($ContactLastName)) {
    $ContactLastName = $me.displayName.Split(" ")[-1]
    # still empty?
    if([string]::IsNullOrEmpty($ContactLastName)) {
        $ContactLastName = "Account"
    }
}
# email
$ContactEmailAddress = ""
if(-not [string]::IsNullOrEmpty($me.mail)) {
    $ContactEmailAddress = $me.mail
}
if([string]::IsNullOrEmpty($ContactEmailAddress)) {
    $ContactEmailAddress = $me.userPrincipalName
}
if([string]::IsNullOrEmpty($ContactEmailAddress)) {
    throw "Failed to determine contact email address from user information."
}


# Service and Classification IDs
$QUOTA_SERVICE_ID = "06bfd9d3-516b-d5c6-5802-169c800dec89"
$WEBAPP_SERVICE_ID = "b452a42b-3779-64de-532c-8a32738357a6"
$WEBAPP_CLASSIFICATION_ID = "/providers/Microsoft.Support/services/b452a42b-3779-64de-532c-8a32738357a6/problemClassifications/7fb8e85d-239b-3b7b-dcd0-1ae517097c7a"
$COMPUTE_CLASSIFICATION_ID = "/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/e12e3d1d-7fa0-af33-c6d0-3c50df9658a3"
$SQLMI_CLASSIFICATION_ID = "/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications/83ab35e7-7b4d-819e-be8f-3c20a8554920"

# Define QuotaRequest class
Add-Type @"
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

public class QuotaRequest {
    public string SubscriptionId { get; set; }
    public string QuotaType { get; set; }
    public string ServiceType { get; set; }
    public string Location { get; set; }
    public string PricingPlan { get; set; }
    public int NewLimit { get; set; }
    public string DeploymentType { get; set; }
    public int vCoreLimit { get; set; }
    public int SubnetLimit { get; set; }
    public string SKU { get; set; }

    public override string ToString() {
        return string.Format("{0} - {1} - {2}", 
            QuotaType, ServiceType, Location);
    }

    
    public static IReadOnlyList<string> GetAllPublicPropertyNames() {
        return typeof(QuotaRequest)
            .GetProperties(BindingFlags.Instance | BindingFlags.Public)
            .Select(p => p.Name)
            .ToArray();
    }
}
"@

function Test-QuotaRequest {
    param (
        [Parameter(Mandatory=$true)]
        [QuotaRequest]$Request
    )

    $validQuotaTypes = @('WebApp', 'Compute', 'Database')
    if ($Request.QuotaType -notin $validQuotaTypes) {
        throw "Invalid quota type: $($Request.QuotaType)"
    }

    switch ($Request.QuotaType) {
        'WebApp' {
            if ([string]::IsNullOrEmpty($Request.DeploymentType)) {
                throw "DeploymentType is required for Web App quotas"
            }
            $validPricingPlans = @('PremiumV3', 'StandardS1', 'StandardS2', 'StandardS3')
            if ($Request.PricingPlan -notin $validPricingPlans) {
                throw "Invalid Web App pricing plan: $($Request.PricingPlan)"
            }
        }
        'Compute' {
            $validSkus = @('DSv3 Series', 'FSv2 Series', 'ESv3 Series')
            if ($Request.SKU -notin $validSkus) {
                throw "Invalid Compute SKU: $($Request.SKU)"
            }
        }
        'Database' {
            switch ($Request.ServiceType) {
                'SQLMI' {
                    if ($Request.vCoreLimit -le 0 -or $Request.SubnetLimit -le 0) {
                        throw "SQLMI requires both vCore and Subnet limits to be specified"
                    }
                }
            }
        }
    }
}

function Get-WebAppQuotaTemplate {
    param(
        [Parameter(Mandatory=$true)]
        [QuotaRequest]$Request
    )

    return @{
        properties = @{
            serviceId = $WEBAPP_SERVICE_ID
            title = "Quota required for App Services in $($Request.Location)"
            problemClassificationId = $WEBAPP_CLASSIFICATION_ID
            severity = "Moderate"
            description = "Quota increase request for App Services"
            problemScopingQuestions = ConvertTo-Json @{
                articleId = "e93b54c0-d7ff-49af-ad95-4adc0f153dd0"
                scopingDetails = @(
                    @{
                        question = "Region"
                        controlId = "quota_region"
                        orderId = 2
                        inputType = "nonstatic"
                        answer = @{
                            displayValue = $Request.Location
                            value = $Request.Location
                            type = "string"
                        }
                    }
                    @{
                        question = "Deployment Type"
                        controlId = "quota_deployment_type"
                        orderId = 3
                        inputType = "static"
                        answer = @{
                            displayValue = $Request.DeploymentType
                            value = $Request.DeploymentType
                            type = "string"
                        }
                    }
                    @{
                        question = "Pricing plan"
                        controlId = "quota_sku_type"
                        orderId = 4
                        inputType = "static"
                        answer = @{
                            displayValue = $Request.PricingPlan
                            value = $Request.PricingPlan
                            type = "string"
                        }
                    }
                    @{
                        question = "How many instances do you need?"
                        controlId = "quota_increase_value"
                        orderId = 5
                        inputType = "nonstatic"
                        answer = @{
                            displayValue = $Request.NewLimit.ToString()
                            value = $Request.NewLimit.ToString()
                            type = "string"
                        }
                    }
                )
            }
            contactDetails = Get-DefaultContactDetails
        }
    }
}

function Get-ComputeQuotaTemplate {
    param(
        [Parameter(Mandatory=$true)]
        [QuotaRequest]$Request
    )

    return @{
        properties = @{
            serviceId = $QUOTA_SERVICE_ID
            title = "Compute Quota Increase - $($Request.SKU) - $($Request.Location)"
            description = "Quota increase request for Compute resources"
            problemClassificationId = $COMPUTE_CLASSIFICATION_ID
            severity = "moderate"
            advancedDiagnosticConsent = "Yes"
            contactDetails = Get-DefaultContactDetails
            quotaTicketDetails = @{
                quotaChangeRequestVersion = "1.0"
                quotaChangeRequests = @(
                    @{
                        region = $Request.Location
                        payload = ConvertTo-Json @{
                            SKU = $Request.SKU
                            NewLimit = $Request.NewLimit
                        }
                    }
                )
            }
        }
    }
}

function Get-SQLMIQuotaTemplate {
    param(
        [Parameter(Mandatory=$true)]
        [QuotaRequest]$Request
    )

    return @{
        properties = @{
            serviceId = $QUOTA_SERVICE_ID
            title = "SQL Managed Instance Quota Increase - $($Request.Location)"
            description = "Quota increase request for SQL Managed Instance vCores and Subnet"
            problemClassificationId = $SQLMI_CLASSIFICATION_ID
            severity = "moderate"
            advancedDiagnosticConsent = "Yes"
            contactDetails = Get-DefaultContactDetails
            quotaTicketDetails = @{
                quotaChangeRequestVersion = "1.0"
                quotaChangeRequestSubType = "SQLMI"
                quotaChangeRequests = @(
                    @{
                        region = $Request.Location
                        payload = ConvertTo-Json @{
                            NewLimit = $Request.vCoreLimit
                            Metadata = $null
                            Type = "vCore"
                        }
                    }
                    @{
                        region = $Request.Location
                        payload = ConvertTo-Json @{
                            NewLimit = $Request.SubnetLimit
                            Metadata = $null
                            Type = "Subnet"
                        }
                    }
                )
            }
        }
    }
}

function Get-DefaultContactDetails {
    return @{
        firstName = $ContactFirstName
        lastName = $ContactLastName
        primaryEmailAddress = $ContactEmailAddress
        preferredContactMethod = "email"
        preferredTimeZone = $ContactPreferredTimeZone
        preferredSupportLanguage = $ContactPreferredLanguage
        country = $ContactCountry
    }
}


function Process-QuotaRequest {
    param(
        [Parameter(Mandatory=$true)]
        [QuotaRequest]$Request
    )

    # Validate request
    Test-QuotaRequest -Request $Request

    # Get appropriate template based on quota type
    $template = switch ($Request.QuotaType) {
        'WebApp' { Get-WebAppQuotaTemplate -Request $Request }
        'Compute' { Get-ComputeQuotaTemplate -Request $Request }
        'Database' {
            switch ($Request.ServiceType) {
                'SQLMI' { Get-SQLMIQuotaTemplate -Request $Request }
                default { throw "Unsupported database service type: $($Request.ServiceType)" }
            }
        }
        default { throw "Unsupported quota type: $($Request.QuotaType)" }
    }

    return $template
}


# read CSV and process each quota request
$quotaRequests = Import-Csv -Path $csvFilePath -ErrorAction Stop
$fieldNames = [QuotaRequest]::GetAllPublicPropertyNames()
$line = 0
foreach($row in $quotaRequests) {
    $line++
    foreach($field in $fieldNames) {
        if($field -eq 'SubscriptionId') {
            continue
        }
        if(-not $row.PSObject.Properties.Name.Contains($field)) {
            throw "Missing required field '$field' in CSV line $line."
        }
    }
    foreach($field in @("QuotaType","ServiceType","Location")) {
        if([string]::IsNullOrEmpty($row.$field)) {
            throw "Field '$field' cannot be empty in CSV line $line."
        }
    }
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

foreach($sub in (Get-AzSubscription  | Where-Object { $_.Name.ToLower().StartsWith($subscriptionPrefix.ToLower()) -and $_.State -eq "Enabled"})) {
    if($null -ne $subscriptionIdFilter) {
        if(-not $subscriptionIdFilter.ContainsKey($sub.Id.ToLower())) {
            continue
        }
    }

    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

    Write-Host "Processing Quota Requests for subscription: $($sub.Name) ($($sub.Id))"
    # running Quota Requests for this subscription
    $line = 0
    foreach($row in $quotaRequests) {
        $line++
        Write-Host "  - Processing quota request from CSV line $line..."
        if($row.SubscriptionId -ne $sub.Id) {
            continue
        }

        $request = [QuotaRequest]::new()
        foreach($field in $fieldNames) {
            $value = $row.$field
            if($field -in @('NewLimit', 'vCoreLimit', 'SubnetLimit')) {
                $value = [int]$value
            }
            $request."$field" = $value
        }

        try {
            $template = Process-QuotaRequest -Request $request
            $result = New-AzSupportTicket @template -ErrorAction Stop
            Write-Host "    - Created quota ticket: $($result.Name)"
        }
        catch {
            Write-Error "    - Failed to Create quota ticket for subscription $($sub.SubscriptionId): $_"
        }
        Start-Sleep -Seconds 2
    }
}
