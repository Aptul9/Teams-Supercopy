# Teams Supercopy

<img src="assets/icon.png" alt="Teams Supercopy icon" width="96">

Copy Microsoft Teams messages with the sender, the time, the messages being replied to and the images, ready to paste into an AI chat.

Teams' own copy keeps only the text. Teams Supercopy turns a selection into this:

```
Teams chat: Project Alpha

[2026-10-29 09:14] Mario Rossi
Can someone check the deploy logs?

[2026-10-29 09:15] Mario Rossi
[image 1: original, C:\Users\mario\AppData\Local\Temp\teams-supercopy\0-weu-d14-....jpg]
this is the error

[2026-10-29 09:16] Laura Bianchi
> in reply to Mario Rossi (29/10/2026 09:14): Can someone check the deploy logs?
on it
> in reply to Mario Rossi (29/10/2026 09:15): this is the error
the pod is restarting because of the readiness probe
```

A message that quotes several messages keeps each quote at its position in the text.

## What lands on the clipboard

Two formats at once; the target app picks the one it understands:

| Format | Content | Pasted by |
|---|---|---|
| HTML | the text plus every image embedded | chat apps such as claude.ai: one paste gives the text and the images as attachments |
| Plain text | the text, with each image as `[image N: <source>, <path>]` | terminals, editors, Claude Code: the path points to the image saved on disk |

Images are saved to `%TEMP%\teams-supercopy\` and files older than a day are deleted on the next copy.

A local agent with filesystem access can open an image from its path while the file exists. Pasting that path into a web chat does not upload the image. Attach the saved file when the destination does not import the embedded HTML image.

## Keys

| Keys | Copies |
|---|---|
| `Ctrl+C` (or right-click > Copy) in Teams | the selected messages, enriched automatically |
| `Ctrl+Shift+C` in native Teams | the original copy, without enrichment; the Teams audio-call shortcut is suppressed |
| Hold `Shift` while clicking Copy | the original copy, without enrichment |
| `Ctrl+Alt+C` | the selected messages; with nothing selected, the message under the mouse |
| `Ctrl+Alt+Shift+C` | every message loaded in the open chat |

The listener watches the clipboard. Automatic enrichment requires native Teams in the foreground, a clipboard owner belonging to that Teams process or its WebView2 child processes, HTML and a Teams source URL. Copies from browser tabs, including EverTranscript captions on Teams web, are ignored even when their text matches a native Teams chat. Plain-text-only copies are ignored. Holding Shift when the clipboard update arrives bypasses enrichment. `Ctrl+Shift+C` is handled only in native Teams and sends a plain `Ctrl+C` after the modifiers are released; other applications keep their shortcuts. Clipboard changes that arrive while enrichment runs are never overwritten by that pending result.

Side effect: pasting inside Teams a message copied from Teams also pastes the full version, with header lines and quotes.

Keep Shift held until the Copy action completes. `Ctrl+Shift+C` requires the listener to be running: without it, native Teams uses that shortcut to start an audio call. Supercopy leaves browser shortcuts unchanged.

After each press a small notice appears next to the mouse for about 1.5 seconds, without taking focus from Teams:

- dark: `Teams Supercopy: 2 messages, 1 image copied`
- red: nothing was copied, with the reason. Teams is not the active window, no message under the mouse, or the selection did not match. In that last case the clipboard still holds Teams' own plain copy.

Paste only after the dark notice: the special copy lands about a second after the key press, so a paste made sooner gets Teams' plain copy. Every press is logged to `teams-supercopy.log` next to the installed script.

## Browser extension

The `browser-extension/` directory contains a standalone Manifest V3 extension for Chrome and Edge. The native Windows listener is not required. It runs only on `https://teams.microsoft.com/` and `https://teams.cloud.microsoft/`.

Version 1.0.1 uses the app icon `assets/icon.png`. `pwsh -File tools/generate-icons.ps1` rebuilds `browser-extension/icons/` and `store/assets/Teams Supercopy Icon.png` from it; the 128 px icon keeps 96 px artwork with transparent padding, as the Chrome Web Store requires.

### Load locally

1. Open `chrome://extensions/` in Chrome, or `edge://extensions/` in Edge.
2. Enable Developer mode.
3. Choose **Load unpacked**, then select this repository's `browser-extension` directory.
4. Reload the Teams Web tab. Open a chat and select message text.
5. Press `Ctrl+C`, then paste after the Supercopy notice.

The toolbar popup enables or pauses automatic enrichment. No build step is needed. Reload the extension and Teams tab after updating its source files.

### Browser controls

| Input | Result |
|---|---|
| `Ctrl+C`, browser Copy | Selected chat messages, including partially selected messages in full |
| Teams message menu **Copy** / **Copia** | That message with context |
| `Ctrl+Alt+C` | Selected messages, or the message under the mouse |
| `Ctrl+Alt+Shift+C` | Every message currently rendered in the chat |
| `Ctrl+Shift+C` with chat text selected | Original copy; Teams does not receive the call shortcut |
| Hold Shift while choosing Copy | Original copy |

Compose drafts, sidebar text and captions are excluded, even if they match a chat message. Other sites are unaffected. Shortcuts in editable fields are left unchanged. Browser shortcuts without a chat selection are also left unchanged.

### Browser images

HTML includes image bytes as data URLs. Plain text uses `[image N: loaded image, embedded in HTML]` instead of a Windows file path. The browser extension does not write image files to disk. A plain-text destination receives the image marker only.

Image preparation starts when a message is hovered or selected. A first copy waits for missing image bytes. Images are fetched from their already-rendered source URL using the current Teams browser session, with a five-second timeout per image. A readable canvas image is the fallback. A failed image remains an explicit unavailable marker; the message text is still copied. This uses the loaded image, which can be a thumbnail, rather than claiming an original full-resolution image.

Only PNG, JPEG, GIF and WebP images up to 12 MiB are embedded. Cache is memory-only and limited to 32 images. No clipboard-read permission, Graph API, tenant consent, separate backend or telemetry is used. Extension storage contains only the enabled flag.

### Browser verification

```powershell
npm ci
npm test
```

The suite covers DOM extraction, selection boundaries, ordered replies, images, ordinary copy events, Teams portal toolbars, Shift bypass and exclusions. `tests/browser-fixture.html` contains synthetic messages for installed-extension copy/paste checks.

### Chrome Web Store release

`.github/workflows/chrome-web-store.yml` publishes the extension; nothing is uploaded by hand.

- A pull request that touches the extension, the tests or the workflow runs `npm test` and builds `Teams Supercopy <version>.zip` from `browser-extension/` (plus `LICENSE` when the repository has one). Nothing is uploaded.
- A push to `main` that touches `browser-extension/`, `tools/chrome-web-store.mjs` or the workflow builds the same ZIP and submits it for review through Chrome Web Store API V2, only when the manifest version is higher than every published or pending store version. An equal or lower version is reported as `published`, `in_review` or `not_newer` and nothing is sent.
- While another version is in review the new one is `deferred`; the six-hourly scheduled run submits it once the review ends. No review is cancelled.
- Google authentication is keyless: GitHub OIDC through Workload Identity Federation provider `github-cws/teams-supercopy`, restricted to this repository, `main` and this workflow. No key or refresh token is stored.
- To release, raise `version` in `browser-extension/manifest.json` in the pull request. Repository variables: `CWS_ITEM_ID`, `CWS_PUBLISHER_ID`, `CWS_SERVICE_ACCOUNT`, `CWS_WORKLOAD_IDENTITY_PROVIDER`, `CWS_PUBLISH_ENABLED` (`true` enables submission).
- Store listing text, icon and screenshots are not part of the API upload; they stay as set in the dashboard.

Chrome validation on 2026-11-07 through Playwriter:

- Real Teams Web selection: two messages, one reply, 308 plain-text characters, with chat title, authors and timestamps.
- Real Teams Web media: one message and one embedded GIF, `image/gif`, 35,434 decoded bytes in the Windows HTML clipboard format.
- Installed-extension synthetic fixture: text and a PNG pasted into a local contenteditable target; pasted image loaded successfully.
- `npm test`: 32 checks passed, including rejection of page-generated copy and shortcut events.

### Browser limits

- Only rendered chat messages are read. Scroll to load older messages. No full-history export.
- Current selectors use Teams' `content-<epoch>`, `message-body-<epoch>` and `author-<epoch>` IDs. Teams updates can change them.
- Teams channel layouts and localized menu labels other than English and Italian are not validated.
- The extension cannot bypass image CORS or browser clipboard restrictions. Image failures are reported rather than silently replaced with expiring authenticated URLs.
- Edge installation and real destination apps remain untested. Rich image import depends on the destination's paste behavior.
- Teams' own Copy menu is covered by DOM tests only. Live menu activation was blocked by overlapping controls; ordinary selected-text copy was tested on real Teams.

## Native Windows requirements

- Windows 10 or 11
- New Microsoft Teams (process `ms-teams.exe`). Classic Teams is not supported.
- PowerShell 7 (`pwsh`). Windows PowerShell 5.1 is not tested.

```powershell
winget install Microsoft.PowerShell
```

No admin rights, no Graph API, no tenant consent: everything runs locally for the current user.

## Install

Download [TeamsSupercopy-Windows.zip](https://servizi.everbright.it/download/TeamsSupercopy-Windows.zip), also linked from the [products page](https://servizi.everbright.it/prodotti/) with its version. Extract it to any folder, then in PowerShell 7 from that folder:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The extracted folder is not needed afterwards. From a clone of this repository the same command works from the repository root:

```powershell
git clone https://github.com/Aptul9/Teams-Supercopy.git
cd Teams-Supercopy
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1`:

1. stops a running Teams Supercopy tray app and listener, if any
2. copies `TeamsSupercopy.exe`, `teams-supercopy.ps1` and `assets\icon.ico` to `%LOCALAPPDATA%\Programs\TeamsSupercopy\`
3. creates `Teams Supercopy.lnk` in the user Startup folder (`shell:startup`), pointing to `TeamsSupercopy.exe`, so it starts at every login
4. starts `TeamsSupercopy.exe` now

`TeamsSupercopy.exe` is a tray icon. It runs `teams-supercopy.ps1` through `pwsh` with no console window, starts it again if it stops (up to five times a minute), and ends it on exit. Its menu has Open log, Restart and Exit. No window to close by mistake: on Windows 11 Windows Terminal ignores `-WindowStyle Hidden`, so a listener started as `pwsh -WindowStyle Hidden` shows a terminal window and dies when that window is closed. The exe is built from `tray/TeamsSupercopy.cs` by `tools/package-windows.ps1` with the .NET Framework 4 `csc.exe` included in Windows; it is not in the repository.

It prints the installed version and paths and whether the listener is running. Re-running it, from a newer download or clone, updates the installed copy.

Options: `-InstallDir <path>`, `-StartupDir <path>`, `-NoStart`.

## Windows download release

`.github/workflows/windows-download.yml` builds and publishes the ZIP; nothing is uploaded by hand.

- The version is `$SupercopyVersion` in `teams-supercopy.ps1`, the only place it is written. The listener logs it at startup (`listener ready v1.0.0`). Raise it in the pull request that changes the listener.
- A pull request or a push to `main` that touches the native files (`teams-supercopy.ps1`, `tray/TeamsSupercopy.cs`, `install.ps1`, `uninstall.ps1`, `assets/icon.ico`, `README.md`, `tests/clipboard.Tests.ps1`, the two `tools/*-windows*.ps1` scripts or the workflow) runs the clipboard tests on `windows-latest`, builds `TeamsSupercopy-Windows.zip` and `TeamsSupercopy-Windows.json` with `tools/package-windows.ps1`, then `tools/test-windows-package.ps1` extracts the ZIP, checks it against its manifest and JSON, installs it into temporary folders, starts the tray app through the Startup shortcut, checks the listener has no console and is restarted after being killed, and uninstalls it.
- On a push to `main` only, the job `servizi` uploads the tested ZIP, then the JSON `{version, sha256, bytes, commit, file}`, to `https://servizi.everbright.it/download/` through the restricted SSH key of this repository. The products page reads the JSON for the link and the version line.
- Repository secrets: `SERVIZI_HOST`, `SERVIZI_KNOWN_HOSTS`, `SERVIZI_DOWNLOAD_SSH_KEY`.
- The Chrome extension release is separate and unaffected.

Local build and test (the test refuses to run while a listener is running, since install and uninstall stop it):

```powershell
pwsh -NoProfile -STA -File tests/clipboard.Tests.ps1
pwsh -NoProfile -File tools/package-windows.ps1 -OutputDirectory "$env:TEMP\supercopy-release"
pwsh -NoProfile -File tools/test-windows-package.ps1 -Archive "$env:TEMP\supercopy-release\TeamsSupercopy-Windows.zip"
```

## Start at login without the installer

The listener is the script run with no arguments; `TeamsSupercopy.exe` runs the `teams-supercopy.ps1` in its own folder. To start it at login by hand, put both in one folder and create the Startup shortcut:

```powershell
$exe = "$env:LOCALAPPDATA\Programs\TeamsSupercopy\TeamsSupercopy.exe"   # wherever the exe and script are
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Teams Supercopy.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = $exe
$s.WorkingDirectory = Split-Path $exe
$s.Save()
```

Start it now without logging out:

```powershell
Start-Process "$env:LOCALAPPDATA\Programs\TeamsSupercopy\TeamsSupercopy.exe"
```

## Verify

Clipboard regression checks (Windows, restores the original clipboard afterward):

```powershell
pwsh -NoProfile -STA -File tests/clipboard.Tests.ps1
```

Listener running:

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object CommandLine -match 'teams-supercopy\.ps1' | Select-Object ProcessId, CommandLine
```

Reading Teams works (open a chat in Teams first; this prints instead of touching the clipboard):

```powershell
pwsh -NoProfile -File "$env:LOCALAPPDATA\Programs\TeamsSupercopy\teams-supercopy.ps1" -Once All -Stdout
```

The output must list the messages of the open chat with author and time. Then the real test: select a few messages in Teams, press `Ctrl+Alt+C`, paste.

Check automatic enrichment and bypasses with the same selected message:

1. Press `Ctrl+C` in native Teams. The pasted copy must include the chat header, author and timestamp.
2. Press `Ctrl+Shift+C`, then release the keys. The pasted copy must remain the original selected text.
3. Hold Shift while choosing Copy from the context menu. The pasted copy must remain the original selected text.
4. Copy matching text from EverTranscript or another browser tab. Supercopy must leave that copy unchanged.

One-shot modes, also usable from other tools or agents:

| Command | Output |
|---|---|
| `-Once All` | every loaded message of the open chat |
| `-Once Hover` | the message under the mouse |
| `-Once Selection` | the messages matching the text already on the clipboard |
| add `-Stdout` | print instead of writing the clipboard |

Errors raised while handling a hotkey go to `teams-supercopy.log` next to the installed script, with a Windows "hand" error sound. When the listener stops, the reason goes there too (`listener stopped: ...`); the tray menu opens the log.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Stops the tray app and the listener, deletes the Startup shortcut and the installed folder.

## How it works

- Teams is a WebView2 app. Its UI Automation tree (the accessibility data used by screen readers) carries, for every message, `author-<id>`, `content-<id>` and `message-body-<id>`. These are only in the **raw** view of the tree, not in the default control view.
- `<id>` is the message arrival time in epoch milliseconds, so the time is read from the id, independent of the UI language.
- A quote shows up inside `content-<id>` as `Inizio citazione, <author>, <date>, <text>, fine citazione` (Italian UI), optionally followed by `, Questo messaggio citato non è verificato da Teams`. A message can hold several, anywhere in its text.
- An image is an `Image` element under `content-<id>` whose AutomationId is `x_<objectId>` (for example `x_0-weu-d14-<32 hex>`). The tree has no pixels, but Teams downloads the image through its WebView2, so the full file is in the Chromium HTTP cache (`EBWebView\*\Cache\Cache_Data`, blockfile format) under the key `.../objects/<objectId>/views/imgo`. The script reads it from there: no network call, no token. If the entry is missing, it falls back to a screen capture of the thumbnail, marked `screen thumbnail` in the text.
- On `Ctrl+Alt+C` the script waits for Ctrl, Alt and Shift to be released, then sends a plain `Ctrl+C`. Sending it with Shift still down would reach Teams as `Ctrl+Shift+C`, which starts an audio call.
- The copied text is matched line by line, in order, against the messages in the tree. Matching lines rather than whole blocks works because Teams copies a quoted block as `Author` plus text without the date.
- If the clipboard does not change (nothing selected), the message under the cursor is found by bounding rectangle. `AutomationElement.FromPoint` returns the whole message pane on WebView2, not the bubble.

## Limits

- Only messages Teams has rendered are visible. Scroll up to load older ones before copying.
- Tested on the Italian Teams UI, Teams build `26260.1717`. The quote markers for other UI languages (`Begin quote` / `end quote` are in the pattern) are not verified. If quotes do not come out, dump the tree with `-Once All -Stdout` and adjust `$QuoteRx` in the script.
- It depends on the current Teams DOM ids. A Teams update that renames them breaks it.
- A partially selected message is copied whole.
- An image comes out at full size only if Teams has downloaded it, which happens when it is shown in the chat. An image that is neither in the cache nor on screen is reported as `[image N: not available]`.
- Files, cards and GIF stickers are not extracted; only images posted in the message.
- Paste checked on claude.ai in Chrome (text plus image attachments) and Word (text with the images inline). Other apps may take only the plain text, in which case the images are reachable through the paths in the text.
- The listener uses the mutex `Local\TeamsCopyHotkeys`: a second copy started while one is running exits silently.
