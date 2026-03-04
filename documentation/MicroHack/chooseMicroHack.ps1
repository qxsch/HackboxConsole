param(
    [string]$HackName = "",
    [string]$HackVariant = "",
    [string]$GithubForkUser = "",
    [string]$Branch = "master",
    [switch]$Download
)

$script:scriptPath = (Get-Item "$PSScriptRoot").FullName
$script:MicroHackRepo = (Join-Path $script:scriptPath "Repo")
$script:ConsoleRoot =  (Get-Item "$PSScriptRoot/../..").FullName


if((-not $Download) -and (Test-Path "$script:MicroHackRepo" -PathType Container)){
    Write-Host "MicroHack Repo already exists locally. Using cached version. Use -Download to re-download the repo."
}
else {
    Write-Host "Downloading MicroHack Repo from GitHub"
    if(Test-Path "$script:MicroHackRepo" -PathType Container) {
        Remove-Item "$script:MicroHackRepo" -Recurse -Force | Out-Null
    }
    New-Item -Path "$script:MicroHackRepo" -ItemType Directory | Out-Null
    if(Test-Path "$script:MicroHackRepo.zip" -PathType Leaf) {
        Remove-Item "$script:MicroHackRepo.zip" -Force
    }
    if($GithubForkUser -ne "") {
        Write-Host "Downloading from user fork: $GithubForkUser"
        Invoke-WebRequest -Uri "https://github.com/$GithubForkUser/MicroHack/archive/refs/heads/$Branch.zip" -OutFile "$script:MicroHackRepo.zip"
    }
    else {
        Invoke-WebRequest -Uri "https://github.com/microsoft/MicroHack/archive/refs/heads/$Branch.zip" -OutFile "$script:MicroHackRepo.zip"
    }
    Expand-Archive "$script:MicroHackRepo.zip" -DestinationPath "$script:MicroHackRepo"
    Remove-Item "$script:MicroHackRepo.zip" -Force | Out-Null
}

function getSupportedVariantsByName {
    param (
        [string]$HackName
    )

    return @()
}

function getRelativeHackPaths {
    $hacks = @()
    foreach($rd in (Get-ChildItem -Path "$script:MicroHackRepo" -Directory)) {
        foreach($category in (Get-ChildItem -Path "$($rd.FullName)" -Directory)) {
            if($category.Name -notmatch "^[0-9]+-" -or $category.Name.StartsWith("00-") -or $category.Name.StartsWith("99-")) {
                continue
            }
            foreach($topic in (Get-ChildItem -Path "$($category.FullName)" -Directory)) {
                if($topic.Name -notmatch "^[0-9]+-[0-9]+") {
                    continue
                }
                foreach($hack in (Get-ChildItem -Path "$($topic.FullName)" -Directory)) {
                    if($hack.Name -notmatch "^[0-9]+[-_]") {
                        continue
                    }

                    $HackStructure = "Unknown"
                    # checking hack structure
                    if(
                        (Test-Path (Join-Path $hack.FullName "walkthrough") -PathType Container) -and
                        (Test-Path (Join-Path $hack.FullName "challenges") -PathType Container) -and
                        (Get-ChildItem -Path (Join-Path $hack.FullName "walkthrough") -Filter *.md -Recurse).Count -gt 0  -and
                        (Get-ChildItem -Path (Join-Path $hack.FullName "challenges") -Filter *.md -Recurse).Count -gt 0
                    ) {
                        $HackStructure = "challenges/walkthrough"
                    }
                    elseif(
                        (Test-Path (Join-Path $hack.FullName "Solutionguide") -PathType Container) -and
                        (Test-Path (Join-Path $hack.FullName "Challenges") -PathType Container) -and
                        (Get-ChildItem -Path (Join-Path $hack.FullName "Solutionguide") -Filter *.md -Recurse).Count -gt 0  -and
                        (Get-ChildItem -Path (Join-Path $hack.FullName "Challenges") -Filter *.md -Recurse).Count -gt 0
                    ) {
                        $HackStructure = "Challenges/Solutionguide"
                    }
                    else {
                        Continue
                    }
                    $hacks += [PSCustomObject]@{
                        Name = $hack.Name
                        Path = $hack.FullName
                        RelativePath = $hack.FullName.Substring($script:MicroHackRepo.Length+1)
                        HackVariants = (getSupportedVariantsByName -HackName $hack.Name)
                        HackStructure = $HackStructure
                    }
                }
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
    $content[0] = $content[0] -replace "^#(\s+(Optional|Extra|Challenge|Walkthrough|Solution):?)+\s+\d+(\s*[:-])?", "# "
    $content[0] = $content[0] -replace "^#\s+", "# "

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

    Write-Host "Hack structure: $($chosenHack.HackStructure)"

    # checking hack structure
    if($chosenHack.HackStructure -eq "challenges/walkthrough") {
        Write-Host "Copying challenges to hack_console"
        Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "walkthrough" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "challenges") -Recurse -Force | Out-Null
        Write-Host "Copying solutions to hack_console"
        Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "challenges" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "solutions") -Recurse -Force | Out-Null
    }
    elseif($chosenHack.HackStructure -eq "Challenges/Solutionguide") {
        Write-Host "Copying challenges to hack_console"
        Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "Solutionguide" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "challenges") -Recurse -Force | Out-Null
        Write-Host "Copying solutions to hack_console"
        Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "Challenges" -and $_.Name.StartsWith(".") -eq $false }  | Copy-Item -Destination (Join-Path $script:ConsoleRoot "hack_console" "solutions") -Recurse -Force | Out-Null
        Rename-Item -Path (Join-Path $script:ConsoleRoot "hack_console" "challenges" "Challenges") -NewName "challenges" | Out-Null
        Rename-Item -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions" "Solutionguide") -NewName "walkthrough" | Out-Null
        
    }
    else {
        throw "Hack structure $($chosenHack.HackStructure) not recognized."
    }

    Write-Host "Creating student zip file for download"
    if(Test-Path "$script:MicroHackRepo-Student" -PathType Container) {
        Remove-Item "$script:MicroHackRepo-Student" -Recurse -Force | Out-Null
    }
    New-Item -Path "$script:MicroHackRepo-Student" -ItemType Directory | Out-Null
    Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "walkthrough" }  | Copy-Item -Destination "$script:MicroHackRepo-Student" -Recurse -Force | Out-Null
    Get-ChildItem -Path (Join-Path "$script:MicroHackRepo-Student" "challenges") -Recurse -Filter *.md  | Remove-Item -Recurse -Force | Out-Null
    # for BCDR_Azure_Native, remove challenges & img folder entirely
    if($chosenHack.Name -eq "04_BCDR_Azure_Native") {
         Remove-Item -Recurse -Force -Path (Join-Path "$script:MicroHackRepo-Student" "challenges") | Out-Null
         Remove-Item -Recurse -Force -Path (Join-Path "$script:MicroHackRepo-Student" "img") | Out-Null
    }
    Get-ChildItem "$script:MicroHackRepo-Student" -Directory | Compress-Archive -DestinationPath (Join-Path $script:ConsoleRoot "hack_console" "challenges" "download-Student.zip") -Force | Out-Null
    Remove-Item "$script:MicroHackRepo-Student" -Recurse -Force | Out-Null

    Write-Host "Creating Coach zip file for download"
    if(Test-Path "$script:MicroHackRepo-Coach" -PathType Container) {
        Remove-Item "$script:MicroHackRepo-Coach" -Recurse -Force | Out-Null
    }
    New-Item -Path "$script:MicroHackRepo-Coach" -ItemType Directory | Out-Null
    Get-ChildItem -Path $chosenHack.Path | Where-Object { $_.Name -ne "challenges" }  | Copy-Item -Destination "$script:MicroHackRepo-Coach" -Recurse -Force | Out-Null
    Get-ChildItem -Path (Join-Path "$script:MicroHackRepo-Coach" "walkthrough") -Recurse -Filter *.md  | Remove-Item -Recurse -Force | Out-Null
    # for BCDR_Azure_Native, remove walkthrough & img folder entirely
    if($chosenHack.Name -eq "04_BCDR_Azure_Native") {
         Remove-Item -Recurse -Force -Path (Join-Path "$script:MicroHackRepo-Coach" "walkthrough") | Out-Null
         Remove-Item -Recurse -Force -Path (Join-Path "$script:MicroHackRepo-Coach" "img") | Out-Null
    }
    Get-ChildItem "$script:MicroHackRepo-Coach" -Directory | Compress-Archive -DestinationPath (Join-Path $script:ConsoleRoot "hack_console" "solutions" "download-Coach.zip") -Force | Out-Null
    Remove-Item "$script:MicroHackRepo-Coach" -Recurse -Force | Out-Null


    Write-Host "Rewriting .md files"
    foreach($subdir in @("challenges", "solutions")) {
        foreach($mdFile in (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir) -Recurse -Filter *.md)) {
            rewriteMdFile -FilePath $mdFile.FullName
        }
        # remove direct links to challenges/solutions in the readme file
        if(Test-Path (Join-Path $script:ConsoleRoot "hack_console" $subdir "Readme.md") -PathType Leaf) {
            $content = (Get-Content -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir "Readme.md") -Raw).Trim() -split "`n"
            $nc = @()
            $ignoreLines = $false
            foreach($l in $content) {
                if($ignoreLines) {
                    if($l.StartsWith("#")) {
                        # does not contain Challenge or Solution anymore
                        if($l.Contains("Challenge") -or $l.Contains("Solution") -or $l.Contains("Walkthrough") ) {
                            # always add headings
                            $nc += $l
                            continue
                        }
                        $ignoreLines = $false
                    }
                    else {
                        continue
                    }
                }
                elseif($l.StartsWith("##") -and ( $l.Contains("Challenge") -or $l.Contains("Solution") -or $l.Contains("Walkthrough") ) ) {
                    $ignoreLines = $true
                }
                $nc += $l
            }
            $content = $nc -join "`n"
        
            Set-Content -Path (Join-Path $script:ConsoleRoot "hack_console" $subdir "Readme.md") -Value $content
        }
    }

    $challenge1 = (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "challenges") -Recurse -Filter *challenge*.md | Sort-Object FullName)[0]
    if($challenge1) {
        $relativePath = (Resolve-Path $challenge1.FullName).Path.Replace((Resolve-Path (Join-Path $script:ConsoleRoot "hack_console" "challenges")).Path, "")
        if($relativePath.StartsWith("\")) {
            $relativePath = $relativePath.Substring(1)
        }
        $relativeDepth = ($relativePath.Split([IO.Path]::DirectorySeparatorChar).Count - 1)
        Write-Host "Adding download link to $relativePath"
        $content = (Get-Content $challenge1.FullName -Raw).Trim() -split "`n"
        $content = (
            $content[0] + "`n`n" +
            "> [!IMPORTANT]`n" +
            "> **Please download this file before proceeding: [download-Student.zip](" + ("../" * $relativeDepth) + "download-Student.zip)**`n" +
            "> `n" +
            "> This is required content, that you will need to complete the hack.`n" +
            "`n`n" +
            "> [!TIP]`n" +
            "> There is also a Readme.md file: [Readme.md](" + ("../" * $relativeDepth) + "Readme.md)`n" +
            "> Please check the prerequisites in the Readme.md file before proceeding.`n" +
            ($content[1..($content.Count-1)] -join "`n")
        )
        Set-Content -Path $challenge1.FullName -Value $content
    }
    $solution1 = (Get-ChildItem -Path (Join-Path $script:ConsoleRoot "hack_console" "solutions") -Recurse -Filter *solution*.md | Sort-Object FullName)[0]
    if($solution1) {
        # relative path to solution file
        $relativePath = (Resolve-Path $solution1.FullName).Path.Replace((Resolve-Path (Join-Path $script:ConsoleRoot "hack_console" "solutions")).Path, "")
        if($relativePath.StartsWith("\")) {
            $relativePath = $relativePath.Substring(1)
        }
        $relativeDepth = ($relativePath.Split([IO.Path]::DirectorySeparatorChar).Count - 1)
        Write-Host "Adding download link to $relativePath"
        $content = (Get-Content $solution1.FullName -Raw).Trim() -split "`n"
        $content = (
            $content[0] + "`n`n" +
            "> [!IMPORTANT]`n" +
            "> **Please download this file before proceeding: [download-Coach.zip](" + ("../" * $relativeDepth) + "download-Coach.zip)**`n" +
            "> `n" +
            "> This is required content, that you will need to complete the hack.`n" +
            "`n`n" +
            "> [!TIP]`n" +
            "> There is also a Readme.md file: [Readme.md](" + ("../" * $relativeDepth) + "Readme.md)`n" +
            "> Please check the prerequisites in the Readme.md file before proceeding.`n" +
            ($content[1..($content.Count-1)] -join "`n")
        )
        Set-Content -Path $solution1.FullName -Value $content
    }

}


