# Teams Supercopy

Copy Microsoft Teams messages with the sender, the time and the message being replied to, ready to paste into an AI chat.

Teams' own copy keeps only the text. Teams Supercopy turns a selection into this:

```
Teams chat: Project Alpha

[2026-10-29 09:14] Mario Rossi
Can someone check the deploy logs?

[2026-10-29 09:16] Laura Bianchi
> in reply to Mario Rossi (29/10/2026 09:14): Can someone check the deploy logs?
On it, the pod is restarting because of the readiness probe.
```

## Hotkeys

| Keys | Copies |
|---|---|
| `Ctrl+Alt+C` | the selected messages; with nothing selected, the message under the mouse |
| `Ctrl+Alt+Shift+C` | every message loaded in the open chat |

The hotkeys act only when Teams is the foreground window. Anywhere else they play the Windows "asterisk" sound and do nothing.

## Requirements

- Windows 10 or 11
- New Microsoft Teams (process `ms-teams.exe`). Classic Teams is not supported.
- PowerShell 7 (`pwsh`). Windows PowerShell 5.1 is not tested.

```powershell
winget install Microsoft.PowerShell
```

No admin rights, no Graph API, no tenant consent: everything runs locally for the current user.

## Install

From a clone of this repository, in PowerShell 7:

```powershell
git clone https://github.com/Aptul9/Teams-Supercopy.git
cd Teams-Supercopy
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1`:

1. stops a running Teams Supercopy listener, if any
2. copies `teams-supercopy.ps1` to `%LOCALAPPDATA%\Programs\TeamsSupercopy\`
3. creates `Teams Supercopy.lnk` in the user Startup folder (`shell:startup`), so the listener starts at every login
4. starts the listener now, hidden

It prints the installed paths and whether the listener is running. Re-running it updates the installed copy.

Options: `-InstallDir <path>`, `-StartupDir <path>`, `-NoStart`.

## Start at login without the installer

The listener is the script run with no arguments. To start it at login by hand, create the Startup shortcut:

```powershell
$script = "$env:LOCALAPPDATA\Programs\TeamsSupercopy\teams-supercopy.ps1"   # wherever the script is
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Teams Supercopy.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = (Get-Command pwsh).Source
$s.Arguments = "-NoProfile -WindowStyle Hidden -File `"$script`""
$s.WindowStyle = 7
$s.Save()
```

Start it now without logging out:

```powershell
Start-Process pwsh -ArgumentList '-NoProfile','-WindowStyle','Hidden','-File',"`"$script`"" -WindowStyle Hidden
```

## Verify

Listener running:

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object CommandLine -match 'teams-supercopy\.ps1' | Select-Object ProcessId, CommandLine
```

Reading Teams works (open a chat in Teams first; this prints instead of touching the clipboard):

```powershell
pwsh -NoProfile -File "$env:LOCALAPPDATA\Programs\TeamsSupercopy\teams-supercopy.ps1" -Once All -Stdout
```

The output must list the messages of the open chat with author and time. Then the real test: select a few messages in Teams, press `Ctrl+Alt+C`, paste.

One-shot modes, also usable from other tools or agents:

| Command | Output |
|---|---|
| `-Once All` | every loaded message of the open chat |
| `-Once Hover` | the message under the mouse |
| `-Once Selection` | the messages matching the text already on the clipboard |
| add `-Stdout` | print instead of writing the clipboard |

Errors raised while handling a hotkey go to `teams-supercopy.log` next to the installed script, with a Windows "hand" error sound.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Stops the listener, deletes the Startup shortcut and the installed folder.

## How it works

- Teams is a WebView2 app. Its UI Automation tree (the accessibility data used by screen readers) carries, for every message, `author-<id>`, `content-<id>` and `message-body-<id>`. These are only in the **raw** view of the tree, not in the default control view.
- `<id>` is the message arrival time in epoch milliseconds, so the time is read from the id, independent of the UI language.
- A reply shows up in `content-<id>` as `Inizio citazione, <author>, <date>, <text>, fine citazione <reply>` (Italian UI).
- On `Ctrl+Alt+C` the script waits for Ctrl, Alt and Shift to be released, then sends a plain `Ctrl+C`. Sending it with Shift still down would reach Teams as `Ctrl+Shift+C`, which starts an audio call.
- The copied text is matched line by line, in order, against the messages in the tree. Matching lines rather than whole blocks works because Teams copies a quoted block as `Author` plus text without the date.
- If the clipboard does not change (nothing selected), the message under the cursor is found by bounding rectangle. `AutomationElement.FromPoint` returns the whole message pane on WebView2, not the bubble.

## Limits

- Only messages Teams has rendered are visible. Scroll up to load older ones before copying.
- Tested on the Italian Teams UI, Teams build `26260.1717`. The quote markers for other UI languages (`Begin quote` / `end quote` are in the pattern) are not verified. If quotes do not come out, dump the tree with `-Once All -Stdout` and adjust `$QuoteRx` in the script.
- It depends on the current Teams DOM ids. A Teams update that renames them breaks it.
- A partially selected message is copied whole.
- The listener uses the mutex `Local\TeamsCopyHotkeys`: a second copy started while one is running exits silently.
