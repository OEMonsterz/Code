# HP Support Assistant silent install for Intune (PowerShell)

[![Lint and test](https://github.com/OEMonsterz/Code/actions/workflows/lint.yml/badge.svg)](https://github.com/OEMonsterz/Code/actions/workflows/lint.yml)
[![Integration](https://github.com/OEMonsterz/Code/actions/workflows/integration.yml/badge.svg)](https://github.com/OEMonsterz/Code/actions/workflows/integration.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

**Automated, verified install, detection and uninstall of HP Support Assistant (the Microsoft Store / AppX version) with Microsoft Intune, ConfigMgr or plain PowerShell.**

It pulls the **latest** HP Support Assistant straight from HP, checks it, installs it for every user, and leaves updating to the Microsoft Store from there.

If you've tried to deploy HP Support Assistant 9.x and ended up with an app that won't install silently, won't show for existing users, or that Intune keeps reporting as "not detected", this is for you.

## The problem

HP Support Assistant 9 is no longer a normal installer. It ships inside an HP SoftPaq as an **AppX bundle**, which causes a string of headaches for IT admins:

- there's no real silent switch you can hand to Intune
- it has to be **provisioned** for the machine, and each existing user also has to **register** it
- MSI-style detection rules don't work on AppX packages
- running in the wrong context (32-bit PowerShell, a standard user) quietly fails
- the HP download needs to be found, trusted and unpacked before anything can happen

These scripts solve all of that.

## What it does

- **Always installs the current version.** It looks up the latest HP Support Assistant SoftPaq in HP's catalogue at install time. Nothing is stored in the repo.
- **Downloads from HP only.** HTTPS from `ftp.hp.com`. Any other host, or plain HTTP/FTP, is refused.
- **Verifies at every stage, and installs nothing if a check fails:**
  1. **Before download:** the URL is on the allow-list, and HP's published hash is fetched.
  2. **After download:** size, SHA256 (or MD5 if that's all HP publishes) and a valid **HP Inc. digital signature**.
  3. **After extraction:** the AppX bundle's name, publisher and version are checked against the manifest.
  4. **After install:** the provisioned version must match the bundle that was installed.
  5. **After uninstall:** nothing may be left behind.
- **Works for existing users.** An Active Setup bridge registers the app for each user at next logon.
- **Hands over to the Microsoft Store.** HP Support Assistant is a Store app, so once it's installed the Store can keep it updated (subject to your organisation's Store and update policies). Run the installer again at any time to pick up a newer version.
- **Cleans up after itself.** Downloaded and extracted files are deleted, logs are capped at 1 MB.

## Quick start: Intune (Win32 app)

1. Put these files in one folder:
   - `Install-HPSupportAssistant.ps1`
   - `Uninstall-HPSupportAssistant.ps1`
   - `HPSupportAssistant.Sources.json`
2. Package it with the [Win32 Content Prep Tool](https://learn.microsoft.com/mem/intune/apps/apps-win32-prepare):
   ```
   IntuneWinAppUtil.exe -c <folder> -s Install-HPSupportAssistant.ps1 -o <output folder>
   ```
3. In Intune, add a **Windows app (Win32)** and use:

   | Setting | Value |
   | --- | --- |
   | Install command | `%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HPSupportAssistant.ps1` |
   | Uninstall command | `%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-HPSupportAssistant.ps1` |
   | Install behaviour | System |
   | Detection rule | Custom script: `Detect-HPSupportAssistant.ps1`, with *Run script as 32-bit process* set to **No** |

   The `SysNative` path matters. The Intune agent is a 32-bit process, and a plain `powershell.exe` would run the 32-bit version, which can't see machine-wide AppX state.
4. Assign to a pilot group first.

Exit codes: `0` = success, `1` = failed (see the log).

## Run it by hand

From an **elevated, 64-bit** PowerShell:

```powershell
# Test the whole download chain without installing anything
.\Install-HPSupportAssistant.ps1 -VerifyOnly

# Install or update
.\Install-HPSupportAssistant.ps1

# Reinstall even if already current
.\Install-HPSupportAssistant.ps1 -Force

# Remove
.\Uninstall-HPSupportAssistant.ps1
```

Logs are in `C:\ProgramData\HPSupportAssistant-Intune\Logs\` (`Install.log`, `Uninstall.log`, `Detection.log`).

## Files

| File | Purpose |
| --- | --- |
| [`Install-HPSupportAssistant.ps1`](scripts/hp-support-assistant/Install-HPSupportAssistant.ps1) | Resolve, download, verify, extract, install, verify |
| [`Uninstall-HPSupportAssistant.ps1`](scripts/hp-support-assistant/Uninstall-HPSupportAssistant.ps1) | Remove everything and verify |
| [`Detect-HPSupportAssistant.ps1`](scripts/hp-support-assistant/Detect-HPSupportAssistant.ps1) | Intune detection rule |
| [`HPSupportAssistant.Sources.json`](scripts/hp-support-assistant/HPSupportAssistant.Sources.json) | Where to download from, who must have signed it, and a fallback SoftPaq |

## Configuration

Everything is in `HPSupportAssistant.Sources.json`:

| Field | Meaning |
| --- | --- |
| `softPaqName`, `category`, `releaseTypes` | How to find the app in HP's catalogue |
| `allowedHosts` | Hosts the installer may download from (default `ftp.hp.com`) |
| `expectedSigner` | The SoftPaq must be digitally signed by this publisher |
| `expectedBundleName`, `expectedBundlePublisher` | Identity the AppX bundle must have |
| `fallbackSoftPaqNumber`, `fallbackDownloadUri`, `fallbackVersion` | Used only if the catalogue lookup fails |
| `minimumHpcmslVersion` | Minimum HP Client Management Script Library version |

The Active Setup name defaults to `HP-Support-Assistant`. If you change it with `-ActiveSetupKeyName`, use the same value in the install, uninstall and detection scripts.

## Requirements

- Windows 10 1803 or later, or Windows 11 (HP's requirement for HP Support Assistant 9)
- Run as SYSTEM or an elevated administrator, in 64-bit PowerShell
- Internet access to `ftp.hp.com` and, if the HP module isn't already installed, the PowerShell Gallery

## Troubleshooting

**HP Support Assistant won't install silently through Intune.**
Use the install command above, with the `SysNative` path, and check `Install.log`. The most common causes are a 32-bit PowerShell host and a blocked connection to `ftp.hp.com`.

**Intune always says "not detected".**
Set *Run script as 32-bit process* to **No** on the detection rule. Provisioned AppX state can't be read from a 32-bit process or as a standard user.

**The app is installed but missing for an existing user.**
The Active Setup bridge registers it at that user's next logon. Check `%LOCALAPPDATA%\HPSupportAssistant-Intune\UserRegistration.log` for that user.

**"Catalogue returned no entry" in the log.**
The catalogue lookup only works on HP hardware (it uses the device's system ID). If it fails, the installer falls back to the SoftPaq pinned in the manifest and says so in the log. The fallback is verified exactly like a catalogue download.

**Why not plain FTP?**
`ftp.hp.com` is HP's download server and also serves HTTPS. Plain FTP isn't encrypted and can't be authenticated, so it's refused. Hash and signature checks apply either way.

## How it's tested

Every push runs PSScriptAnalyzer and Pester tests under PowerShell 7 and Windows PowerShell 5.1. A separate integration workflow, run on demand and weekly, does the real thing on a Windows runner: downloads from HP, checks hash and signature, extracts, provisions, detects, uninstalls and confirms the app is gone. The weekly run also warns if HP changes a URL.

**Not yet covered by CI:** the catalogue lookup on real HP hardware (runners aren't HP devices), and the per-user Active Setup registration for real signed-in users. Please try those on a pilot device and [open an issue](../../issues) with what you find.

## Contributing

Fixes, ideas and test results from real devices are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem, see [SECURITY.md](SECURITY.md).

## Disclaimer

Provided as-is, with no warranty. Test with a pilot group before wide deployment. Not affiliated with or endorsed by HP Inc. or Microsoft. HP and HP Support Assistant are trademarks of HP Inc.

## Licence

[MIT](LICENSE)
