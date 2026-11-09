# Contributing

Thanks for helping. Fixes, new scripts and better docs are all welcome.

## Ground rules

- **No secrets or internal details.** No tenant IDs, tokens, company names, server names or real device logs.
- **Keep scripts self-contained and readable.** Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`) on every script.
- **Intune contract matters.** Detection scripts must exit `0` and write to STDOUT only when the app is detected.
- **Say what you tested.** Windows version, Intune or local run, and the result.

## How to contribute

1. Fork the repo and create a branch.
2. Make your change.
3. Run the linter locally (optional, CI does it too):
   ```powershell
   Install-Module PSScriptAnalyzer -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
   ```
4. Open a pull request using the template.

## Reporting bugs

Use the bug report issue template. Include your Windows build, how you deploy (Intune or manual) and the relevant lines from `Detection.log`.
