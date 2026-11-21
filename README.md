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

Paste only after the dark notice: the special copy lands about a second after the key press, so a paste made sooner gets Teams' plain copy. Every press is logged (tray menu, Open log).

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

## Windows app

One file, `TeamsSupercopy.exe`: a tray icon with the listener inside. Nothing else to install: it runs on the .NET Framework 4.8 that Windows 10 and 11 already have.

- Windows 10 or 11, x64
- New Microsoft Teams (process `ms-teams.exe`). Classic Teams is not supported.
- No admin rights, no Graph API, no tenant consent: everything runs locally for the current user.

### Download

From the [products page](https://servizi.everbright.it/prodotti/) (Teams Supercopy card, then the installer or the portable ZIP), or from the [latest release](https://github.com/Aptul9/Teams-Supercopy/releases/latest):

| Download | What it does |
|---|---|
| [TeamsSupercopy-Windows-x64-Setup.exe](https://servizi.everbright.it/download/TeamsSupercopy-Windows-x64-Setup.exe) | per-user installer: program in `%LOCALAPPDATA%\Programs\Teams Supercopy`, **Teams Supercopy** in the Start menu, uninstall from Settings > Apps. One page asks whether it starts with Windows. |
| [TeamsSupercopy-Windows-x64.zip](https://servizi.everbright.it/download/TeamsSupercopy-Windows-x64.zip) | portable: the exe alone, to put in any folder and double-click |

The installer, a portable copy started for the first time, or a second launch show where it is: a notice next to the clock. The icon is in the notification area; Windows 11 may put it under the `^` arrow, from where it can be dragged onto the taskbar.

Installing or starting 1.1 removes the PowerShell version (up to 1.0.5): it stops the old listener, deletes `%LOCALAPPDATA%\Programs\TeamsSupercopy` and its `Teams Supercopy.lnk` in the Startup folder.

### Tray menu

Left or right click opens the menu, which stays open until the icon is clicked again (or Esc).

| Item | Does |
|---|---|
| Enabled | untick to turn Supercopy off without exiting: Ctrl+C and the shortcuts reach Teams untouched. Kept in `HKCU\Software\TeamsSupercopy` (`Disabled`), so it stays off after a restart. |
| Start with Windows | the `TeamsSupercopy` value in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, pointing at this exe |
| Open log | `%LOCALAPPDATA%\TeamsSupercopy\teams-supercopy.log`: every copy, every skipped copy with its reason, and why the listener stopped if it did |
| Restart | restarts the listener |
| Exit | ends the app |

The listener runs on its own thread. If it stops on an error, the app starts it again after 2 seconds, five times a minute at most, then shows a notice.

Command line, used by the installer: `--close-running` (closes a running copy, exit 1 if one is still running after 10 s), `--install-settings --startup on|off`, `--uninstall-cleanup`, `--startup` (started at sign-in: no notice).

### Build and release

`windows/` holds the app, built like EverTranscript Windows: the C# compiler of .NET Framework 4 (`csc.exe`, C# 5), an Inno Setup 6 installer from the tested ZIP.

```powershell
cd windows
./build.ps1 -Test                                       # bin\TeamsSupercopy.exe and the regressions (tests\SupercopyTests.cs, real clipboard)
./tools/package.ps1                                     # artifacts\release\TeamsSupercopy-Windows-x64.zip + .json
./tools/test-package.ps1 -Archive ./artifacts/release/TeamsSupercopy-Windows-x64.zip
./tools/installer.ps1                                   # TeamsSupercopy-Windows-x64-Setup.exe, "setup" added to the JSON
./tools/test-installer.ps1 -Setup ./artifacts/release/TeamsSupercopy-Windows-x64-Setup.exe
```

The package and installer tests refuse to run while Teams Supercopy is running: exit it from the tray first.

- The version is `AssemblyVersion` in `windows/src/App.cs`, the only place it is written. Raise it in the pull request that changes the app.
- `.github/workflows/windows.yml` runs the steps above on `windows-2022` for every pull request and push to `main` that touches `windows/`, the icon or the workflow.
- On a push to `main` it also creates the GitHub release `windows-v<version>-build.<run>.<attempt>` and uploads ZIP, installer and then the JSON `{version, sha256, bytes, commit, file, setup}` to `https://servizi.everbright.it/download/` through the restricted SSH key of this repository (secrets `SERVIZI_HOST`, `SERVIZI_KNOWN_HOSTS`, `SERVIZI_DOWNLOAD_SSH_KEY`). The products page reads that JSON for the popup.
- The Chrome extension release is separate and unaffected.

### Verify on a real Teams

1. Select a few messages in Teams, press `Ctrl+C`, paste: chat header, author and time must be there.
2. `Ctrl+Shift+C`, then release the keys: the paste is the original selected text.
3. Hold Shift while choosing Copy from the context menu: the paste is the original selected text.
4. Copy matching text from EverTranscript or another browser tab: Supercopy leaves it unchanged.
5. `Ctrl+Alt+C` with nothing selected: the message under the mouse. `Ctrl+Alt+Shift+C`: the whole loaded chat.

## How it works

- Teams is a WebView2 app. Its UI Automation tree (the accessibility data used by screen readers) carries, for every message, `author-<id>`, `content-<id>` and `message-body-<id>`. These are only in the **raw** view of the tree, not in the default control view.
- `<id>` is the message arrival time in epoch milliseconds, so the time is read from the id, independent of the UI language.
- A quote shows up inside `content-<id>` as `Inizio citazione, <author>, <date>, <text>, fine citazione` (Italian UI), optionally followed by `, Questo messaggio citato non è verificato da Teams`. A message can hold several, anywhere in its text.
- An image is an `Image` element under `content-<id>` whose AutomationId is `x_<objectId>` (for example `x_0-weu-d14-<32 hex>`). The tree has no pixels, but Teams downloads the image through its WebView2, so the full file is in the Chromium HTTP cache (`EBWebView\*\Cache\Cache_Data`, blockfile format) under the key `.../objects/<objectId>/views/imgo`. The app reads it from there: no network call, no token. If the entry is missing, it falls back to a screen capture of the thumbnail, marked `screen thumbnail` in the text.
- On `Ctrl+Alt+C` the app waits for Ctrl, Alt and Shift to be released, then sends a plain `Ctrl+C`. Sending it with Shift still down would reach Teams as `Ctrl+Shift+C`, which starts an audio call.
- The copied text is matched line by line, in order, against the messages in the tree. Matching lines rather than whole blocks works because Teams copies a quoted block as `Author` plus text without the date.
- If the clipboard does not change (nothing selected), the message under the cursor is found by bounding rectangle. `AutomationElement.FromPoint` returns the whole message pane on WebView2, not the bubble.

## Limits

- Only messages Teams has rendered are visible. Scroll up to load older ones before copying.
- Tested on the Italian Teams UI. The quote markers for other UI languages (`Begin quote` / `end quote` are in the pattern) are not verified; the pattern is `QuoteRx` in `windows/src/Copy.cs`.
- It depends on the current Teams DOM ids. A Teams update that renames them breaks it.
- A partially selected message is copied whole.
- An image comes out at full size only if Teams has downloaded it, which happens when it is shown in the chat. An image that is neither in the cache nor on screen is reported as `[image N: not available]`.
- Files, cards and GIF stickers are not extracted; only images posted in the message.
- Paste checked on claude.ai in Chrome (text plus image attachments) and Word (text with the images inline). Other apps may take only the plain text, in which case the images are reachable through the paths in the text.
- One copy runs at a time (mutex `Local\TeamsSupercopy`): a second launch only shows where the running one is.
