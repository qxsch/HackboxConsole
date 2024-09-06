# HackBox Console

A portal for **Hackathon participants** to access challenges and credentials.

A portal for **Hackathon coaches** to access challenges, solutions, credentials and unlock challenges for participants.

Solutions and challenges are stored in markdown files in a storage account.

Thanks to [zero-md](https://github.com/zerodevx/zero-md) the markdown files are rendered as HTML with a broad support for markdown syntax:
- [x] Math rendering via [`KaTeX`](https://github.com/KaTeX/KaTeX)
- [x] [`Mermaid`](https://github.com/mermaid-js/mermaid) diagrams
- [x] Syntax highlighting via [`highlight.js`](https://github.com/highlightjs/highlight.js)
- [x] Language detection for un-hinted code blocks
- [x] Hash-link scroll handling
- [x] FOUC prevention
- [x] Auto re-render on input changes
- [x] Light and dark themes
- [x] Spec-compliant extensibility



## How to build & Deploy

Deploy the console with the markdown files from the ContosoHotelOpenHack repository
```pwsh
.\iac\deployHackerConsole.ps1 `
    -SourceChallengesDir ..\ContosoHotelOpenHack\challenges\ `
    -SourceSolutionsDir ..\ContosoHotelOpenHack\solutions\ `
    -ResourceGroupName "hackathonconsole" `
    -hackerUsername "hacker" `
    -hackerPassword ("hacker" | ConvertTo-SecureString -AsPlainText -Force) `
    -coachUsername "coach" `
    -coachPassword ("coach" | ConvertTo-SecureString -AsPlainText -Force)
```

Publish additional credentials to the storage account in this example the name of the credential is ``Example Password`` with the (secret) value ``DontTellAnyone``
```pwsh
.\iac\addCredential.ps1 `
    -storageAccountName "storage...." `
    -ResourceGroupName "hackathonconsole" `
    -name "Example Password" `
    -value "DontTellAnyone"
```
