param(
    [string]$HackName = "",
    [string]$HackVariant = "",
    [string]$GithubForkUser = "",
    [string]$Branch = "master",
    [switch]$Download
)

$script:scriptPath = (Get-Item "$PSScriptRoot").FullName
$script:WhatTheHackRepo = (Join-Path $script:scriptPath "Repo")
$script:ConsoleRoot =  (Get-Item "$PSScriptRoot/../..").FullName


if((-not $Download) -and (Test-Path "$script:WhatTheHackRepo" -PathType Container)){
    Write-Host "WhatTheHack Repo already exists locally. Using cached version. Use -Download to re-download the repo."
}
else {
    Write-Host "Downloading WhatTheHack Repo from GitHub"
    if(Test-Path "$script:WhatTheHackRepo" -PathType Container) {
        Remove-Item "$script:WhatTheHackRepo" -Recurse -Force | Out-Null
    }
    New-Item -Path "$script:WhatTheHackRepo" -ItemType Directory | Out-Null
    if(Test-Path "$script:WhatTheHackRepo.zip" -PathType Leaf) {
        Remove-Item "$script:WhatTheHackRepo.zip" -Force
    }
    if($GithubForkUser -ne "") {
        Write-Host "Downloading from user fork: $GithubForkUser"
        Invoke-WebRequest -Uri "https://github.com/$GithubForkUser/WhatTheHack/archive/refs/heads/$Branch.zip" -OutFile "$script:WhatTheHackRepo.zip"
    }
    else {
        Invoke-WebRequest -Uri "https://github.com/microsoft/WhatTheHack/archive/refs/heads/$Branch.zip" -OutFile "$script:WhatTheHackRepo.zip"
    }
    Expand-Archive "$script:WhatTheHackRepo.zip" -DestinationPath "$script:WhatTheHackRepo"
    Remove-Item "$script:WhatTheHackRepo.zip" -Force | Out-Null
}

function getSupportedVariantsByName {
    param (
        [string]$HackName
    )

    if($HackName -ieq "001-IntroToKubernetes") {
        return @("A","B","C","D")
    }

    if($HackName -ieq "015-Serverless") {
        return @("Standard", "Accelerator", "All")
    }

    if($HackName -ieq "039-AKSEnterpriseGrade") {
        return @("Standard","Accelerator")
    }

    if($HackName -ieq "047-TrafficControlWithDapr") {
        return @("A","B")
    }

    return @()
}

function getRelativeHackPaths {
    $hacks = @()
    foreach($rd in (Get-ChildItem -Path "$script:WhatTheHackRepo" -Directory)) {
        foreach($hack in (Get-ChildItem -Path "$($rd.FullName)" -Directory)) {
            if($hack.Name -notmatch "^[0-9]+-" -or $hack.Name.StartsWith("000-")) {
                continue
            }
            if(
                (-not (Test-Path "$($hack.FullName)/Coach" -PathType Container)) -or
                (-not (Test-Path "$($hack.FullName)/Student" -PathType Container)) -or
                ((Get-ChildItem "$($hack.FullName)/Coach" -Filter *.md).Count -eq 0) -or
                ((Get-ChildItem "$($hack.FullName)/Student" -Filter *.md).Count -eq 0)
            ) {
                continue
            }
            $hacks += [PSCustomObject]@{
                Name = $hack.Name
                Path = $hack.FullName
                RelativePath = $hack.FullName.Substring($script:WhatTheHackRepo.Length+1)
                HackVariants = (getSupportedVariantsByName -HackName $hack.Name)
            }
        }
        if(
            (Test-Path "$($rd.FullName)/Coach" -PathType Container) -and
            (Test-Path "$($rd.FullName)/Student" -PathType Container) -and
            (Get-ChildItem "$($rd.FullName)/Coach" -Filter *.md).Count -gt 0 -and
            (Get-ChildItem "$($rd.FullName)/Student" -Filter *.md).Count -gt 0
        ) {
            $hacks += [PSCustomObject]@{
                Name = $rd.Name
                Path = $rd.FullName
                RelativePath = $rd.FullName.Substring($script:WhatTheHackRepo.Length+1)
                HackVariants = (getSupportedVariantsByName -HackName $rd.Name)
            }
        }
    }
    return $hacks
}

function validateHackName {
    param (
        [string]$HackName
    )

    $chosenHackRelativePathCount = 0
    $chosenHackRelativePath = $null
    $chosenHackNameCount = 0
    $chosenHackName = $null
    foreach($h in getRelativeHackPaths) {
        if($h.Name -ieq $HackName) {
            $chosenHackNameCount++
            $chosenHackName = $h
        }
        if($h.RelativePath -ieq $HackName) {
            $chosenHackRelativePathCount++
            $chosenHackRelativePath = $h
        }
    }
    if($chosenHackRelativePathCount -gt 0) {
        return $chosenHackRelativePath
    }
    elseif($chosenHackNameCount -gt 0) {
        if($chosenHackNameCount -gt 1) {
            Write-Warning "Multiple hacks found with the name '$HackName'. Please specify the relative path instead."
        }
        return $chosenHackName
    }
    else {
        throw "No hack found with the name or relative path '$HackName'."
    }    
}

function rewriteMdFile {
    param (
        [string]$FilePath
    )

    $content = (Get-Content -Path $FilePath -Raw).Trim() -split "`n"

    # cleaning up the title
    $content[0] = $content[0] -replace "^#(\s+Optional)?\s+(Challenge|Solution)\s+\d+(\s*[:-])?", "# "

    # navigation bars
    for($i=0; $i -lt 5  -and $i -lt $content.Count; $i++) {
        if($content[$i].Contains("[Home](") -and ( $content[$i].Contains("Challenge") -or $content[$i].Contains("Solution") ) ) {
            $content[$i] = ""
            break
        }
    }

    $content = $content -join "`n"

    # rewriting relative links
    $content = $content -replace "\]\(\.\.\/\.\.\/000-HowToHack\/", "](../000-HowToHack/"

    Set-Content -Path $FilePath -Value $content
}

if($HackName -eq "") {
    getRelativeHackPaths
}
else {
    $chosenHack = validateHackName -HackName $HackName
    if($chosenHack) {
        Write-Host "Using hack: $($chosenHack.RelativePath)"
    }
    else {
        throw "No valid hack found for: $HackName"
    }
    # Clean up existing challenges and solutions
    foreach($subdir in @("challenges", "solutions")) {
        if(Test-Path (Join-Path $script:ConsoleRoot "hack_console" $subdir)  -PathType Container) {
            Write-Host "Removing existing $subdir from hack_console"
            Remove-Item (Join-Path $script:ConsoleRoot "hack_console" $subdir) -Recurse -Force | Out-Null
        }
        New-Item -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir) -ItemType Directory | Out-Null
        New-Item -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir ".gitkeep") -ItemType File | Out-Null
    }

    # Always copy HowToHack
    foreach($rd in (Get-ChildItem -Path "$script:WhatTheHackRepo" -Directory)) {
        if($rd.Name -eq "000-HowToHack") {
            Write-Host "Copying HowToHack to hack_console"
            Write-Host "Copying files from $($rd.FullName) to $(Join-Path $script:ConsoleRoot "hack_console" "challenges")"
            foreach($subdir in @("challenges", "solutions")) {
                Copy-Item -Path $rd.FullName -Destination (Join-Path $script:ConsoleRoot "hack_console" $subdir) -Recurse -Force | Out-Null
            }
            break
        }
        foreach($hack in (Get-ChildItem -Path "$($rd.FullName)" -Directory)) {
            if($hack.Name -eq "000-HowToHack") {
                Write-Host "Copying HowToHack to hack_console"
                foreach($subdir in @("challenges", "solutions")) {
                    Copy-Item -Path $hack.FullName -Destination (Join-Path $script:ConsoleRoot "hack_console" $subdir) -Recurse -Force | Out-Null
                }
                break
            }
        }
    }
    #remove any *challenge*.md files from HowToHack in solutions
    foreach($subdir in @("challenges", "solutions")) {
        Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "$subdir" "000-HowToHack") -Recurse -Filter *challenge*.md | Remove-Item -Force | Out-Null
    }

    Write-Host "Copying challenges to hack_console"
    Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "Coach" -and $_.Name -ne "Host" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "challenges") -Recurse -Force | Out-Null
    Write-Host "Copying solutions to hack_console"
    Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "Student" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "solutions") -Recurse -Force | Out-Null

    Write-Host "Renaming .md files (if applicable)"
    foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "challenges" "Student") -Filter *.md)) {
        Write-Host "Processing $($mdFile.Name)"
        if((-not $mdFile.Name.ToLower().Contains("challenge")) -and $mdFile.Name -match "^[0-9]+-") {
            $newName = $mdFile.Name -replace "^(?<num>[0-9]+)-", 'Challenge-${num}-'
            Write-Host "`tRenaming $($mdFile.Name) to $newName"
            Rename-Item -Path $mdFile.FullName -NewName $newName
    
        }
    }
    foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Coach") -Filter *.md)) {
        if((-not $mdfile.Name.ToLower().Contains("solution")) -and $mdFile.Name -match "^[0-9]+-") {
            $newName = $mdFile.Name -replace "^(?<num>[0-9]+)-", 'Solution-${num}-'
            Write-Host "`tRenaming $($mdFile.Name) to $newName"
            Rename-Item -Path $mdFile.FullName -NewName $newName
    
        }
    }
    if(
        (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Coach") -Filter *.md | Where-Object { $_.Name.ToLower().Contains("solution") }).Count -eq 0
    ) {
        foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Coach") -Filter *.md)) {
            if($mdFile.Name.ToLower().Contains("challenge")) {
                $newName = $mdFile.Name -replace "challenge", "Solution"
                Write-Host "`tRenaming $($mdFile.Name) to $newName"
                Rename-Item -Path $mdFile.FullName -NewName $newName
            }
        }
    }


    Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "challenges" "Student") -Recurse | Where-Object { $_.Name -ne "download-Student.zip" -and $_.Name -notlike "*.md" } | Compress-Archive -DestinationPath (Join-Path $script:ConsoleRoot "hack_console" "challenges" "download-Student.zip") -Force | Out-Null
    Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Coach") -Recurse | Where-Object { $_.Name -ne "download-Coach.zip" -and $_.Name -notlike "*.md" } | Compress-Archive -DestinationPath (Join-Path $script:ConsoleRoot "hack_console" "solutions" "download-Coach.zip") -Force | Out-Null

    Write-Host "Rewriting .md files"
    foreach($subdir in @("challenges", "solutions")) {
        foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir) -Recurse -Filter *.md)) {
            rewriteMdFile -FilePath $mdFile.FullName
        }
        foreach($role in @("Student", "Coach")) {
            if(Test-Path (Join-Path $script:ConsoleRoot "hack_console" $subdir $role) -PathType Container) {
                $prereqFile = $null
                foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir $role) -Filter 00*.md)) {
                    $prereqFile = $mdFile
                    break
                }
                if($null -eq $prereqFile) {
                    foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir $role) -Filter *00*.md)) {
                        $prereqFile = $mdFile
                        break
                    }

                    if($null -eq $prereqFile) {
                        Write-Warning "No prerequisites file found in $subdir. It's recommended to have a prerequisites file named '00*.md' or similar."
                    }
                }
                if($prereqFile) {
                    Write-Host "Adding download link to $($prereqFile.Name)"
                    $content = (Get-Content $prereqFile.FullName -Raw).Trim() -split "`n"
                    $content = (
                        $content[0] + "`n`n" +
                        "> [!IMPORTANT]`n" +
                        "> **Please download this file before proceeding: [download-$($role).zip](../download-$($role).zip)**`n" +
                        "> `n" +
                        "> This is required content, that you will need to complete the hack.`n" +
                        ($content[1..($content.Count-1)] -join "`n")
                    )
                    Set-Content -Path $prereqFile.FullName -Value $content
                }
            }
        }
    }

    # setting the paths
    $studentPath = (Join-Path $script:ConsoleRoot "hack_console" "challenges" "Student")
    $coachPath = (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Coach")
    # special instructions for 001-IntroToKubernetes)
    if($chosenHack.Name -eq "001-IntroToKubernetes") {
        if($HackVariant -eq "") {
            $HackVariant = "A"
            Write-Warning "No HackVariant specified. Defaulting to Path A. (Available Paths: 'A', 'B', 'C', 'D')"
        }
        if($HackVariant -notin @("A","B","C","D")) {
            Write-Warning "Invalid HackVariant specified: $HackVariant. Defaulting to Path A. (Available Paths: 'A', 'B', 'C', 'D')"
        }
        Write-Host "Applying special instructions for Path $HackVariant"
        # 01
        Remove-Item (Join-Path $studentPath "Challenge-01.md") -Force | Out-Null
        Remove-Item (Join-Path $coachPath "Solution-01.md") -Force | Out-Null
        # 02
        Remove-Item (Join-Path $studentPath "Challenge-02.md") -Force | Out-Null
        Remove-Item (Join-Path $coachPath "Solution-02.md") -Force | Out-Null
        # Apply special instructions based on HackVariant
        if($HackVariant -eq "A") {
            # 02b
            Remove-Item (Join-Path $studentPath "Challenge-02B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02B.md") -Force | Out-Null
            # 02c
            Remove-Item (Join-Path $studentPath "Challenge-02C.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02C.md") -Force | Out-Null

        }
        elseif($HackVariant -eq "B") {
            # 01a
            Remove-Item (Join-Path $studentPath "Challenge-01A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-01A.md") -Force | Out-Null
            # 02a
            Remove-Item (Join-Path $studentPath "Challenge-02A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02A.md") -Force | Out-Null
            # 02c
            Remove-Item (Join-Path $studentPath "Challenge-02C.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02C.md") -Force | Out-Null

        }
        elseif($HackVariant -eq "C") {
            # 01a
            Remove-Item (Join-Path $studentPath "Challenge-01A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-01A.md") -Force | Out-Null
            # 02a
            Remove-Item (Join-Path $studentPath "Challenge-02A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02A.md") -Force | Out-Null
            # 02b
            Remove-Item (Join-Path $studentPath "Challenge-02B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02B.md") -Force | Out-Null
        }
        elseif($HackVariant -eq "D") {
            # 01a
            Remove-Item (Join-Path $studentPath "Challenge-01A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-01A.md") -Force | Out-Null
            # 02a
            Remove-Item (Join-Path $studentPath "Challenge-02A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02A.md") -Force | Out-Null
            # 02b
            Remove-Item (Join-Path $studentPath "Challenge-02B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02B.md") -Force | Out-Null
            # 02c
            Remove-Item (Join-Path $studentPath "Challenge-02C.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-02C.md") -Force | Out-Null
        }
    }
    elseif($chosenHack.Name -eq "015-Serverless") {
        if($HackVariant -eq "") {
            $HackVariant = "Standard"
            Write-Warning "No HackVariant specified. Defaulting to Standard. (Available Variants: 'Standard', 'Accelerator', 'All')"
        }
        if($HackVariant -notin @("Standard","Accelerator","All")) {
            Write-Warning "Invalid HackVariant specified: $HackVariant. Defaulting to Standard. (Available Variants: 'Standard', 'Accelerator', 'All')"
        }
        Write-Host "Applying special instructions for Path $HackVariant"
        if($HackVariant -eq "Standard") {
            # 03a
            Remove-Item (Join-Path $studentPath "Challenge-03A.md") -Force | Out-Null
            # 07a
            Remove-Item (Join-Path $studentPath "Challenge-07A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-07A.md") -Force | Out-Null
            # 07b
            Remove-Item (Join-Path $studentPath "Challenge-07B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-07B.md") -Force | Out-Null
        }
        elseif($HackVariant -eq "Accelerator") {
            # 03a
            Remove-Item (Join-Path $studentPath "Challenge-03.md") -Force | Out-Null
            Rename-Item (Join-Path $studentPath "Challenge-03A.md") -NewName "Challenge-03.md" | Out-Null
            # 07a
            Remove-Item (Join-Path $studentPath "Challenge-07A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-07A.md") -Force | Out-Null
            # 07b
            Remove-Item (Join-Path $studentPath "Challenge-07B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-07B.md") -Force | Out-Null
        }
        elseif($HackVariant -eq "All") {
            # 03a
            Remove-Item (Join-Path $studentPath "Challenge-03A.md") -Force | Out-Null
        }
    }
    elseif($chosenHack.Name -eq "039-AKSEnterpriseGrade") {
        if($HackVariant -eq "") {
            $HackVariant = "Standard"
            Write-Warning "No HackVariant specified. Defaulting to Standard. (Available Variants: 'Standard', 'Accelerator')"
        }
        if($HackVariant -notin @("Standard","Accelerator")) {
            Write-Warning "Invalid HackVariant specified: $HackVariant. Defaulting to Standard. (Available Variants: 'Standard', 'Accelerator')"
        }
        Write-Host "Applying special instructions for Variant $HackVariant"
        if($HackVariant -eq "Standard") {
            # 02a
            Remove-Item (Join-Path $studentPath "Challenge-02A.md") -Force | Out-Null
        }
        elseif($HackVariant -eq "Accelerator") {
            # 02
            Remove-Item (Join-Path $studentPath "Challenge-02.md") -Force | Out-Null
        }
    }
    elseif($chosenHack.Name -eq "047-TrafficControlWithDapr") {
        if($HackVariant -eq "") {
            $HackVariant = "A"
            Write-Warning "No HackVariant specified. Defaulting to Path A. (Available Paths: 'A', 'B', 'C', 'D')"
        }
        if($HackVariant -notin @("A","B","C","D")) {
            Write-Warning "Invalid HackVariant specified: $HackVariant. Defaulting to Path A. (Available Paths: 'A', 'B', 'C', 'D')"
        }
        Write-Host "Applying special instructions for Path $HackVariant"
        # 08
        Remove-Item (Join-Path $studentPath "Challenge-08.md") -Force | Out-Null
        Remove-Item (Join-Path $coachPath "Solution-08.md") -Force | Out-Null
        # Apply special instructions based on HackVariant
        if($HackVariant -eq "A") {
            # 08b
            Remove-Item (Join-Path $studentPath "Challenge-08B.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-08B.md") -Force | Out-Null
        }
        elseif($HackVariant -eq "B") {
            # 08a
            Remove-Item (Join-Path $studentPath "Challenge-08A.md") -Force | Out-Null
            Remove-Item (Join-Path $coachPath "Solution-08A.md") -Force | Out-Null
        }
    }

    # create the lab directory
    $labDir = Join-Path $script:ConsoleRoot "iac" "lab"
    if (Test-Path $labDir -PathType Container) {
        Remove-Item -Path $labDir -Recurse -Force
    }
    # finding the right script for lab deployment (if any)
    $deployLabScripts = Get-ChildItem -Path $chosenHack.Path -Recurse -Filter "deploy-lab.ps1"
    $qualifiedLabScript = $null
    foreach ($candidate in $deployLabScripts) {
        $cmdInfo = Get-Command $candidate.FullName
        $params = $cmdInfo.Parameters

        $hasValidParamBlock = (
            $params.ContainsKey('DeploymentType') -and
            $params['DeploymentType'].ParameterType -eq [string] -and
            ($params['DeploymentType'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] -and
                $_.ValidValues -contains 'subscription' -and
                $_.ValidValues -contains 'resourcegroup' -and
                $_.ValidValues -contains 'resourcegroup-with-subscriptionowner'
            }) -and
            $params.ContainsKey('SubscriptionId') -and
            $params['SubscriptionId'].ParameterType -eq [string] -and
            $params.ContainsKey('ResourceGroupName') -and
            $params['ResourceGroupName'].ParameterType -eq [string] -and
            $params.ContainsKey('PreferredLocation') -and
            $params['PreferredLocation'].ParameterType -eq [string] -and
            $params.ContainsKey('AllowedEntraUserIds') -and
            $params['AllowedEntraUserIds'].ParameterType -eq [string[]]
        )

        if (-not $hasValidParamBlock) {
            Write-Host -ForegroundColor Yellow "deploy-lab.ps1 found in $($candidate.Directory.FullName) but does not have the expected param block. Skipping."
        }
        else {
            $qualifiedLabScript = $candidate
            break
        }
    }
    # found?
    if ($qualifiedLabScript) {
        $sourceDir = $qualifiedLabScript.Directory.FullName
        Write-Host "Found qualifying deploy-lab.ps1 in: $sourceDir"
        Write-Host "Copying lab contents to: $labDir"
        New-Item -Path $labDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $sourceDir "*") -Destination $labDir -Recurse -Force
        Write-Host -ForegroundColor Green "This hack supports automated lab deployment."
        Write-Host -ForegroundColor Green "To disable automated lab deployment, use ./iac/azure/deployLabEnvironments.ps1 with -noAutoDiscoveredLab switch."
    }
    else {
        Write-Host "No deploy-lab.ps1 found in hack directory, this hack does not support automated lab deployment."
    }
}


