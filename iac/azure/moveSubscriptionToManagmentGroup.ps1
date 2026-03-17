<#
.SYNOPSIS
Moves one or more Azure subscriptions into a target management group.

.DESCRIPTION
Resolves each subscription input by subscription ID first and then by exact
subscription name. The script verifies that the target management group exists,
ensures the required Az PowerShell modules are available, signs in if needed,
and then moves each resolved subscription to the specified management group.

.PARAMETER subscriptions
One or more subscription identifiers to move. Each value can be either a
subscription GUID or an exact subscription name.

.PARAMETER targetManagementGroup
The management group ID to move the subscriptions into. The script validates
that the management group exists before performing any move operation.

.EXAMPLE
.\moveSubs.ps1 -subscriptions '11111111-1111-1111-1111-111111111111' -targetManagementGroup 'Contoso-Platform'

Moves the specified subscription GUID into the Contoso-Platform management group.

.EXAMPLE
.\moveSubs.ps1 -subscriptions 'Prod Subscription','Dev Subscription' -targetManagementGroup 'Contoso-Apps' -WhatIf

Shows which named subscriptions would be moved into the Contoso-Apps management
group without making any changes.

.NOTES
Requires Az.Accounts and Az.Resources. If no Az session is active, the script
prompts for authentication with device code flow.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[string[]]$subscriptions = @(),

	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$targetManagementGroup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-Subscription {
	param(
		[Parameter(Mandatory = $true)]
		[string]$InputValue,

		[Parameter(Mandatory = $true)]
		[object[]]$AvailableSubscriptions
	)

    $guidMatch = @($AvailableSubscriptions | Where-Object { $_.Id -ieq $InputValue })
    if ($guidMatch.Count -eq 1) {
        return $guidMatch[0]
    }

	$nameMatches = @($AvailableSubscriptions | Where-Object { $_.Name -ieq $InputValue })
	if ($nameMatches.Count -eq 1) {
		return $nameMatches[0]
	}

	if ($nameMatches.Count -gt 1) {
		throw "Subscription name '$InputValue' is ambiguous. Use the subscription GUID instead."
	}

	throw "Subscription '$InputValue' was not found by GUID or exact name."
}

if ($subscriptions.Count -eq 0) {
	throw 'At least one subscription must be provided in -subscriptions.'
}

$targetManagementGroupObject = Get-AzManagementGroup -GroupId $targetManagementGroup -Expand -ErrorAction SilentlyContinue
if ($null -eq $targetManagementGroupObject) {
	throw "Management group '$targetManagementGroup' was not found."
}

$availableSubscriptions = @(Get-AzSubscription)

foreach ($subscriptionInput in $subscriptions) {
	if ([string]::IsNullOrWhiteSpace($subscriptionInput)) {
		continue
	}

	$resolvedSubscription = Resolve-Subscription -InputValue $subscriptionInput.Trim() -AvailableSubscriptions $availableSubscriptions
	$targetDescription = "$($resolvedSubscription.Name) [$($resolvedSubscription.Id)] -> $targetManagementGroup"

	if ($PSCmdlet.ShouldProcess($targetDescription, 'Move subscription to management group')) {
		Write-Host "Moving subscription '$($resolvedSubscription.Name)' ($($resolvedSubscription.Id)) to management group '$targetManagementGroup'..."
		New-AzManagementGroupSubscription -GroupName $targetManagementGroupObject.Name -SubscriptionId $resolvedSubscription.Id | Out-Null
		Write-Host "Moved subscription '$($resolvedSubscription.Name)' ($($resolvedSubscription.Id)) to management group '$targetManagementGroup'."
	}
}
