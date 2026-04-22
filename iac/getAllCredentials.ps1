<#
.SYNOPSIS
Retrieve all entries from the credentials or connections storage table used by the console.

.DESCRIPTION
Queries every entity from the specified table of the given storage account and
outputs them as PowerShell objects. Supports the same authentication methods
(Account Keys or Entra ID / OAuth) and optional temporary firewall rule as
addMultipleCredentials.ps1.

.PARAMETER storageAccountName
Name of the Azure Storage Account that hosts the table.

.PARAMETER ResourceGroupName
Resource group containing the storage account. Defaults to 'HackConsole'.

.PARAMETER TableName
Which table to query. Valid values are 'credentials' and 'connections'.

.PARAMETER ip
Client IPv4 address to allow through the storage account firewall.
When omitted, the script resolves the public IP automatically.

.PARAMETER skipFirewallRule
Skip adding and removing the temporary firewall rule for the client IP.

.EXAMPLE
.\getAllCredentials.ps1 -storageAccountName 'contosovault'
Returns all credential entries from the 'credentials' table.

.EXAMPLE
.\getAllCredentials.ps1 -storageAccountName 'contosovault' -TableName 'connections'
Returns all connection entries from the 'connections' table.

.EXAMPLE
.\getAllCredentials.ps1 -storageAccountName 'contosovault' | ConvertTo-Json | Out-File creds-backup.json
Exports all credentials to a JSON file.

.EXAMPLE
.\getAllCredentials.ps1 | Where-Object { $_.PartitionKey -eq 'team1' }
Retrieves credentials and filters by tenant (PartitionKey).

#>
[CmdletBinding()]
param(
    [string]$storageAccountName = "",
    [string]$ResourceGroupName = "HackConsole",
    [ValidateSet("credentials", "connections")]
    [string]$TableName = "credentials",
    [string]$ip = "",
    [switch]$skipFirewallRule
)

# --- Storage account discovery ---
if([string]::IsNullOrWhiteSpace($storageAccountName)) {
    Write-Verbose "Storage account name not provided. Attempting to retrieve from resource group."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName | Where-Object { $_.Kind -eq 'StorageV2' -and $_.StorageAccountName.StartsWith('storage') } | Select-Object -First 1
    if($null -eq $storageAccount) {
        throw "No suitable storage account found in resource group '$ResourceGroupName'. Please provide the storage account name explicitly."
    }
    $storageAccountName = $storageAccount.StorageAccountName
}

# --- Firewall management ---
$firewallAdded = $false
$publicAccessWasDisabled = $false
if(-not $skipFirewallRule) {
    # Check if public network access is enabled
    $storageAccountInfo = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -ErrorAction Stop
    if ($storageAccountInfo.PublicNetworkAccess -eq 'Disabled') {
        Write-Verbose "Public network access is disabled. Temporarily enabling it."
        Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -PublicNetworkAccess Enabled -ErrorAction Stop | Out-Null
        $publicAccessWasDisabled = $true
        Write-Verbose "Waiting for 10 seconds for the public network access change to take effect"
        Start-Sleep -Seconds 10
    }

    # add the client ip to the storage account firewall
    $ipToUse = $ip
    if([string]::IsNullOrWhiteSpace($ipToUse)) {
        $ipToUse = (Invoke-RestMethod https://ipinfo.io/json).ip
    }

    Write-Verbose "Adding firewall rule for the client ip ($ipToUse)"
    Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $storageAccountName -IPAddressOrRange "$ipToUse" -ErrorAction Stop | Out-Null
    $firewallAdded = $true

    Write-Verbose "Waiting for 10 seconds for the firewall rule to take effect"
    Start-Sleep -Seconds 10
}

try {
    # --- Helper: plain access token ---
    function Get-PlainAccessToken {
        param([string]$ResourceUrl, [string]$TenantId)

        $params = @{
            ResourceUrl = $ResourceUrl
            ErrorAction = 'Stop'
        }
        if ($TenantId) { $params.TenantId = $TenantId }

        $tokenResult = Get-AzAccessToken @params
        $token = $tokenResult.Token

        # Convert SecureString to plain text if needed
        if ($token -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
            try {
                $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

        return @{
            Token     = $token
            ExpiresOn = $tokenResult.ExpiresOn
        }
    }

    # --- Helper: SharedKeyLite authorization header ---
    function Get-SharedKeyAuthHeader {
        param(
            [string]$StorageAccountName,
            [string]$StorageAccountKey,
            [string]$Method,
            [string]$Resource,
            [string]$ContentType,
            [string]$Date
        )

        # SharedKeyLite for Table service: StringToSign = Date + "\n" + CanonicalizedResource
        $stringToSign = "$Date`n/$StorageAccountName/$Resource"

        # Create HMAC-SHA256 signature
        $keyBytes = [Convert]::FromBase64String($StorageAccountKey)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $signatureBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
        $signature = [Convert]::ToBase64String($signatureBytes)

        return "SharedKeyLite $StorageAccountName`:$signature"
    }

    # --- Helper: test table access ---
    function Test-TableConnectionRest {
        param(
            [string]$StorageAccountName,
            [string]$TableName,
            [string]$StorageAccountKey = $null
        )
        try {
            $tableUrl = "https://$StorageAccountName.table.core.windows.net/$TableName()"
            $dateString = [DateTime]::UtcNow.ToString("R")

            if ($StorageAccountKey) {
                $resource = "$TableName()"
                $authHeader = Get-SharedKeyAuthHeader -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -Method "GET" -Resource $resource -ContentType "" -Date $dateString

                $headers = @{
                    "Authorization"    = $authHeader
                    "Accept"           = "application/json;odata=nometadata"
                    "x-ms-version"     = "2020-12-06"
                    "x-ms-date"        = $dateString
                    "DataServiceVersion" = "3.0;NetFx"
                }
            }
            else {
                $azContext = Get-AzContext
                $tokenInfo = Get-PlainAccessToken -ResourceUrl "https://storage.azure.com" -TenantId $azContext.Tenant.Id
                $token = $tokenInfo.Token

                $headers = @{
                    "Authorization"    = "Bearer $token"
                    "Accept"           = "application/json;odata=nometadata"
                    "x-ms-version"     = "2020-12-06"
                    "x-ms-date"        = $dateString
                    "DataServiceVersion" = "3.0;NetFx"
                }
            }

            $response = Invoke-RestMethod -Uri "$tableUrl`?`$top=1" -Method Get -Headers $headers -ErrorAction Stop
            return $true
        }
        catch {
            return $false
        }
    }

    # --- Helper: query all entities with pagination ---
    function Get-AllTableEntitiesRest {
        param(
            [string]$StorageAccountName,
            [string]$TableName,
            [string]$StorageAccountKey = $null
        )

        $allEntities = [System.Collections.Generic.List[psobject]]::new()
        $baseUrl = "https://$StorageAccountName.table.core.windows.net/$TableName()"
        $nextPartitionKey = $null
        $nextRowKey = $null

        do {
            # Build query URL with continuation tokens if present
            $queryUrl = $baseUrl
            $queryParams = @()
            if ($nextPartitionKey) {
                $queryParams += "NextPartitionKey=$([Uri]::EscapeDataString($nextPartitionKey))"
            }
            if ($nextRowKey) {
                $queryParams += "NextRowKey=$([Uri]::EscapeDataString($nextRowKey))"
            }
            if ($queryParams.Count -gt 0) {
                $queryUrl = "$baseUrl`?$($queryParams -join '&')"
            }

            $dateString = [DateTime]::UtcNow.ToString("R")

            if ($StorageAccountKey) {
                $resource = "$TableName()"
                $authHeader = Get-SharedKeyAuthHeader -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -Method "GET" -Resource $resource -ContentType "" -Date $dateString

                $headers = @{
                    "Authorization"      = $authHeader
                    "Accept"             = "application/json;odata=nometadata"
                    "x-ms-version"       = "2020-12-06"
                    "x-ms-date"          = $dateString
                    "DataServiceVersion" = "3.0;NetFx"
                }
            }
            else {
                $azContext = Get-AzContext
                $tokenInfo = Get-PlainAccessToken -ResourceUrl "https://storage.azure.com" -TenantId $azContext.Tenant.Id
                $token = $tokenInfo.Token

                $headers = @{
                    "Authorization"      = "Bearer $token"
                    "Accept"             = "application/json;odata=nometadata"
                    "x-ms-version"       = "2020-12-06"
                    "x-ms-date"          = $dateString
                    "DataServiceVersion" = "3.0;NetFx"
                }
            }

            $response = Invoke-WebRequest -Uri $queryUrl -Method Get -Headers $headers -ErrorAction Stop

            $body = $response.Content | ConvertFrom-Json
            if ($body.value) {
                foreach ($entity in $body.value) {
                    if($TableName -eq 'credentials') {
                        if($null -ne $entity.note) {
                            $allEntities.Add([pscustomobject]@{
                                tenant = $entity.PartitionKey
                                group = $entity.group
                                name = $entity.name
                                value = $entity.Credential
                                note = $entity.note
                            })
                        }
                        else {
                            $allEntities.Add([pscustomobject]@{
                                tenant = $entity.PartitionKey
                                group = $entity.group
                                name = $entity.name
                                value = $entity.Credential
                            })
                        }
                    }
                    elseif($TableName -eq 'connections') {
                        if($null -eq $entity.port) {
                            $allEntities.Add([pscustomobject]@{
                                hackboxuser = $entity.PartitionKey
                                hackboxconnection = $entity.RowKey
                                user = $entity.user
                                pass = $entity.pass
                                host = $entity.host
                            })
                        }
                        else {
                            $allEntities.Add([pscustomobject]@{
                                hackboxuser = $entity.PartitionKey
                                hackboxconnection = $entity.RowKey
                                user = $entity.user
                                pass = $entity.pass
                                host = $entity.host
                                port = $entity.port
                            })
                        }
                    }
                    else {
                        $allEntities.Add($entity)
                    }
                }
            }

            # Check for continuation tokens in response headers
            $nextPartitionKey = $response.Headers['x-ms-continuation-NextPartitionKey']
            $nextRowKey = $response.Headers['x-ms-continuation-NextRowKey']

            # Unwrap single-element arrays returned by some PS versions
            if ($nextPartitionKey -is [array]) { $nextPartitionKey = $nextPartitionKey[0] }
            if ($nextRowKey -is [array]) { $nextRowKey = $nextRowKey[0] }

        } while ($nextPartitionKey)

        return $allEntities
    }

    # --- Authentication selection ---
    $storageAccountKey = $null

    # Try storage account keys first
    try {
        $keyResult = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $storageAccountName -ErrorAction Stop
        $storageAccountKey = $keyResult.Value[0]

        if (-not (Test-TableConnectionRest -StorageAccountName $storageAccountName -TableName $TableName -StorageAccountKey $storageAccountKey)) {
            $storageAccountKey = $null
        }
    }
    catch {
        # Storage account keys not available or disabled
    }

    # If storage account keys didn't work, try OAuth
    if (-not $storageAccountKey) {
        if (-not (Test-TableConnectionRest -StorageAccountName $storageAccountName -TableName $TableName)) {
            throw "Failed to connect to the storage table. Ensure your user has 'Storage Table Data Reader' (or Contributor) role on the storage account."
        }
    }

    # Log authentication method
    if ($storageAccountKey) {
        Write-Verbose "Using Account Keys Authentication Method"
    }
    else {
        $azContext = Get-AzContext
        Write-Verbose "Using EntraID Authentication Method with Account: $($azContext.Account.Id)"
    }

    # --- Query all entities ---
    Write-Verbose "Querying all entities from table '$TableName'..."
    $entities = Get-AllTableEntitiesRest -StorageAccountName $storageAccountName -TableName $TableName -StorageAccountKey $storageAccountKey

    Write-Verbose "Retrieved $($entities.Count) entities from table '$TableName'."

    # Output the entities to the pipeline
    $entities
}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    # --- Firewall cleanup ---
    if ($firewallAdded) {
        Write-Verbose "Removing firewall rule for the client ip ($ipToUse)"
        Remove-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $storageAccountName -IPAddressOrRange "$ipToUse" -ErrorAction Stop | Out-Null
    }
    if ($publicAccessWasDisabled) {
        Write-Verbose "Restoring public network access to disabled state"
        Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -PublicNetworkAccess Disabled -ErrorAction Stop | Out-Null
    }
}
