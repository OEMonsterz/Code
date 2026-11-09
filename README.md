# HP Support Assistant: Intune deployment scripts

Scripts to help IT admins deploy, detect and remove **HP Support Assistant** (the Microsoft Store / AppX version) with **Microsoft Intune**.

Lots of admins struggle with this app. It's an AppX package, it's provisioned per machine, and it needs per-user setup, so the usual MSI-style detection rules don't work. These scripts are my working solution. Contributions and fixes are very welcome.

> **Status:** early. Detection script is ready to use. Install and uninstall scripts are planned (see [Roadmap](#roadmap)).

## What's here

| Script | Purpose |
| --- | --- |
| [`scripts/hp-support-assistant/Detect-HPSupportAssistant.ps1`](scripts/hp-support-assistant/Detect-HPSupportAssistant.ps1) | Intune Win32 app detection rule |

## Quick start: detection rule

1. In Intune, open your Win32 app, then **Detection rules** > **Add** > **Use a custom detection script**.
2. Upload `Detect-HPSupportAssistant.ps1`.
3. Set:
   - **Run script as 32-bit process on 64-bit clients:** `No`
   - **Enforce script signature check and run script silently:** `No` (unless you sign it)
4. Save and assign.

The app counts as **detected** when the AppX package is provisioned on the device or installed for any user. The script exits `0` and writes a line to STDOUT, which is what Intune requires.

### Optional: also require the per-user setup

If your installer sets up each user through an [Active Setup](https://learn.microsoft.com/windows/win32/setupapi/) component, you can make detection require it:

```powershell
.\Detect-HPSupportAssistant.ps1 -RequireUserBridge -ActiveSetupKeyName 'Your-Component-Name'
```

### Test it locally

Run from an **elevated** PowerShell (64-bit):

```powershell
.\Detect-HPSupportAssistant.ps1
echo $LASTEXITCODE   # 0 = detected, 1 = not detected
```

Logs go to `C:\ProgramData\HPSupportAssistant-Intune\Logs\Detection.log` (capped at 1 MB, one rotated copy kept).

## Common problems

- **Always shows "not detected":** the rule is probably running as a 32-bit process. Set that option to `No`.
- **Detected on the device but Intune disagrees:** detection must run as SYSTEM (Intune's default). Provisioned AppX state isn't visible to standard users.
- **Nothing in the log:** the folder needs write access for SYSTEM/admins. Logging failures never change the detection result.

## Roadmap

- [ ] Install script
- [ ] Uninstall script (remove provisioned and per-user copies)
- [ ] Pester tests
- [ ] Example Intune app configuration

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem, see [SECURITY.md](SECURITY.md).

## Disclaimer

These scripts are provided as-is, with no warranty. Test in a pilot group before wide deployment. Not affiliated with or endorsed by HP Inc. or Microsoft.

## Licence

[MIT](LICENSE)
