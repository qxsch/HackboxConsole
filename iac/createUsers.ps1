<#
.SYNOPSIS
Creates user accounts for Contoso Hotel OpenHack hackathon events with configurable roles and password complexity.

.DESCRIPTION
This script generates user accounts for hackathon participants including hackers, coaches, and an optional techlead.
It supports flexible password generation with simple (human-readable) or complex password options.
Output is saved as JSON and optionally as CSV files for easy distribution and import.

.PARAMETER numberOfTenants
The number of tenant teams to create. Each tenant gets one hacker and one coach account.
Valid range: 1-200
Default: 4

.PARAMETER baseHackerUsername
The base username for hacker accounts. Will be suffixed with padded team numbers (e.g., hacker01, hacker02).

.PARAMETER baseCoachUsername
The base username for coach accounts. Will be suffixed with padded team numbers (e.g., coach01, coach02).

.PARAMETER hackerPasswordStrength
Password complexity for hacker accounts.
Valid values:
- Simple: Uses adjective-noun-number format (e.g., "big-apple-42")
- Complex: Uses random alphanumeric characters

.PARAMETER coachPasswordStrength
Password complexity for coach accounts.
Valid values:
- Simple: Uses adjective-noun-number format (e.g., "big-apple-42")
- Complex: Uses random alphanumeric characters
.PARAMETER simplePasswordAdjectives
Custom array of adjectives for simple password generation.
If not provided, uses default fruit-related adjectives.
Example: @('red','blue','green','fast','slow')

.PARAMETER simplePasswordNouns
Custom array of nouns for simple password generation.
If not provided, uses default fruit names.
Example: @('car','house','tree','book','pen')

.PARAMETER complexPasswordLength
Length of complex passwords in characters.

.PARAMETER complexPasswordAllowSpecialChars
Include special characters in complex passwords for additional security.

.PARAMETER disableTechleadUser
Disable creation of the techlead user account.

.PARAMETER disableHackerUser
Disable creation of the hacker user accounts.

.PARAMETER disableCoachUser
Disable creation of the coach user accounts.

.PARAMETER createCsvFiles
Generate separate CSV files for hackers and coaches in addition to the main JSON file. (Useful to put passwords f.e. into Excel or PowerPoint for distribution)

.EXAMPLE
.\createUsers.ps1 -numberOfTenants 25 -createCsvFiles -complexPasswordAllowSpecialChars
Creates 25 tenant teams, generates CSV files, and uses special characters in complex passwords.

.EXAMPLE
.\createUsers.ps1 -numberOfTenants 5 -simplePasswordAdjectives @('red','blue','green') -simplePasswordNouns @('car','bike','bus')
Creates 5 tenant teams using custom words for simple password generation for the hacker users.
Example passwords: "red-car-23", "blue-bike-87"

.EXAMPLE
.\createUsers.ps1 -numberOfTenants 10 -disableTechleadUser -baseHackerUsername "student" -baseCoachUsername "mentor"
Creates 10 tenant teams without techlead, using custom base usernames like "student01", "mentor01".
#>
param(
    [ValidateRange(1,200)]
    [int]$numberOfTenants=4,
    [string]$baseHackerUsername="hacker",
    [string]$baseCoachUsername="coach",
    [ValidateSet("simple","complex")]
    [string]$hackerPasswordStrength="simple",
    [ValidateSet("simple","complex")]
    [string]$coachPasswordStrength="complex",
    [string[]]$simplePasswordAdjectives = @(),
    [string[]]$simplePasswordNouns = @(),
    [ValidateRange(12,64)]
    [int]$complexPasswordLength = 16,
    [switch]$skipCoachUser,
    [switch]$complexPasswordAllowSpecialChars,
    [switch]$disableTechleadUser,
    [switch]$disableHackerUser,
    [switch]$disableCoachUser,
    [switch]$createCsvFiles

)


$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$consoleRoot = Split-Path -Parent $scriptPath


function generatePassword {
    param(
        [ValidateSet("simple","complex")]
        [string]$strength="simple",
        [string[]]$simpleAdjectives = @(),
        [string[]]$simpleNouns = @(),
        [ValidateRange(12,64)]
        [int]$complexLength = 16,
        [switch]$complexAllowSpecialChars
    )
    if($strength -eq "simple") {
        # simple password
        if($null -ne $simpleAdjectives -and $simpleAdjectives.Count -gt 0) {
            $adjectives = $simpleAdjectives
        } else {
            $adjectives = @('big','small','tasty','sweet','sour','fresh','ripe','juicy','delicious','yummy','crisp','zesty','fruity','succulent', 'flavorful')
        }
        if($null -ne $simpleNouns -and $simpleNouns.Count -gt 0) {
            $fruits = $simpleNouns
        } else {
            $fruits = @('apple','banana','cherry','grape','kiwi','lemon','mango','nectarine','orange','papaya','quince','raspberry','strawberry','tangerine','watermelon')
        }
        # password is adjective + fruit + 2 digit number
        return ($adjectives | Get-Random) + "-" + ($fruits | Get-Random) + "-" + (Get-Random -Minimum 10 -Maximum 99).ToString()

    }
    else {
        # complex password
        $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        $specialChars = '!@#&$/*-_=+;:,.?'

        $pwd = -join ((1..$complexLength) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
        if($complexAllowSpecialChars) {
            # replace some characters with special characters
            $numSpecialChars = [Math]::Max(1, [Math]::Floor($complexLength / 8))
            for($i=0; $i -lt $numSpecialChars; $i++) {
                $pos = Get-Random -Minimum 2 -Maximum $complexLength
                $specialChar = $specialChars[(Get-Random -Maximum $specialChars.Length)]
                $pwd = $pwd.Substring(0, $pos - 1) + $specialChar + $pwd.Substring($pos)
            }
        }
        return $pwd        
    }
}


$users = @()
if($disableTechleadUser -or $numberOfTenants -le 1) {
    Write-Host "Techlead user creation is disabled."
 }
else {
    # add a techlead user (always with highest complex password + 4 extra length)
    $users += [PSCustomObject]@{
        "username" = "techlead1"
        "password" = ( generatePassword -strength "complex" -complexLength ($complexPasswordLength + 4) -complexAllowSpecialChars )
        "role" = "techlead"
    }
}

# digits of numberOfTenants
$tenantDigits = $numberOfTenants.ToString().Length

# add hacker and coach users for each tenant
for ($i = 1; $i -le $numberOfTenants; $i++) {
    $paddedIndex = $i.ToString().PadLeft($tenantDigits, '0')
    if(-not $disableHackerUser) {
        $users += [PSCustomObject]@{
            "username" = ( $baseHackerUsername + $paddedIndex )
            "password" = ( generatePassword -strength $hackerPasswordStrength -simpleAdjectives $simplePasswordAdjectives -simpleNouns $simplePasswordNouns -complexLength $complexPasswordLength -complexAllowSpecialChars:$complexPasswordAllowSpecialChars )
            "role" = "hacker"
            "tenant" = ( "team" + $paddedIndex )
        }
    }
    if(-not $disableCoachUser) {
        $users += [PSCustomObject]@{
            "username" = ( $baseCoachUsername + $paddedIndex )
            "password" = ( generatePassword -strength $coachPasswordStrength -simpleAdjectives $simplePasswordAdjectives -simpleNouns $simplePasswordNouns -complexLength $complexPasswordLength -complexAllowSpecialChars:$complexPasswordAllowSpecialChars )
            "role" = "coach"
            "tenant" = ( "team" + $paddedIndex )
        }
    }
}


$users | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path -Path $consoleRoot -ChildPath "users.json") -Encoding utf8

if($createCsvFiles) {
    $users  | Where-Object { $_.role -eq "hacker" } | Select-Object tenant,username,password | ConvertTo-Csv | Out-File -FilePath (Join-Path -Path $consoleRoot -ChildPath "users-hackers.csv") -Encoding utf8
    $users  | Where-Object { $_.role -eq "coach" } | Select-Object tenant,username,password | ConvertTo-Csv | Out-File -FilePath (Join-Path -Path $consoleRoot -ChildPath "users-coaches.csv") -Encoding utf8
    Write-Host "CSV files for hackers and coaches have been created."
    Write-Host "The CSV files are located at:"
    Write-Host (" - " + (Join-Path -Path $consoleRoot -ChildPath "users-hackers.csv"))
    Write-Host (" - " + (Join-Path -Path $consoleRoot -ChildPath "users-coaches.csv"))
}
