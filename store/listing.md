# Chrome Web Store listing

## Store listing

Name: Teams Supercopy

Summary: Copy Teams Web messages with author, timestamp, replies and embedded images.

Language: English

Category: Productivity > Tools

Description:

Teams Supercopy copies messages from Microsoft Teams Web with their context.

Select message text and press Ctrl+C. The clipboard receives the chat name, author, local timestamp and quoted replies. Partially selected messages are copied in full.

Images are embedded in HTML when available. Plain text contains image markers, not image files. Only messages already loaded in the open chat can be copied.

Shortcuts:
- Ctrl+C: copy selected messages with context.
- Ctrl+Alt+C: copy the selection or the message under the mouse.
- Ctrl+Alt+Shift+C: copy all messages currently loaded in the chat.
- Ctrl+Shift+C with chat text selected: original copy without enrichment.
- Hold Shift while choosing Copy: original copy.

The toolbar popup can pause automatic enrichment. Compose drafts, captions and sidebar text are excluded.

The extension runs only on Teams Web. It does not read the clipboard, does not require the Windows Teams app, and has no analytics or developer-operated backend.

Teams Supercopy is an independent extension and is not affiliated with Microsoft.

## Privacy practices

Single purpose: Copy Microsoft Teams Web messages to the clipboard with their author, timestamp, quoted replies and available images.

storage: Stores only the local preference that enables or pauses enriched copying. Message content is not saved in extension storage.

clipboardWrite: Writes the messages requested by the user as plain text and HTML, including available images, after a copy action. The extension does not read the clipboard.

Host access: Content scripts run only on https://teams.microsoft.com/ and https://teams.cloud.microsoft/ to read already-loaded chat messages and handle copying. The extension does not read browsing history or content on other sites.

Remote code: No. All executable code is included in the extension package. Image requests download media data, not executable code.

Data categories: Personally identifiable information (author names); Personal communications (chat messages and quoted replies); Website content (chat titles, text and images).

Certifications: User data is not sold or transferred for advertising. It is used only for the extension's single purpose. It is not used for creditworthiness or lending.

Privacy policy: https://gist.github.com/Aptul9/9ed553ac0b54047c2e474d4564a3d48d

## Distribution

Visibility: Public

Price: Free

Regions: All available regions

Release: Automatically publish after Google approves the review.

## Review instructions

The extension requires an authorized Microsoft Teams Web account and an accessible chat. No tenant administrator consent or Windows Teams installation is required. No customer credentials are provided.

Open https://teams.cloud.microsoft/ or https://teams.microsoft.com/, sign in with an authorized Teams account and open a chat. Select text from one or more messages and press Ctrl+C. After the Teams Supercopy notice appears, paste into a text editor or rich-text editor. The output includes the chat title, author, timestamp and quoted replies. Available images are embedded in HTML. Press Ctrl+Shift+C with chat text selected to copy without enrichment.

Only already-loaded messages are read. No messages are sent, edited or deleted by the extension.

## Submitted review field

The dashboard limits this field to 500 characters. The submitted 473-character excerpt uses the approved instructions verbatim.

The extension requires an authorized Microsoft Teams Web account and an accessible chat. No tenant administrator consent or Windows Teams installation is required. No customer credentials are provided.

Open https://teams.cloud.microsoft/ or https://teams.microsoft.com/, sign in with an authorized Teams account and open a chat. Select text from one or more messages and press Ctrl+C. After the Teams Supercopy notice appears, paste into a text editor or rich-text editor.

## Publisher references

Publisher ID: `475e1955-3459-4c31-a9e5-c0ec9375475b`.

Item ID: `kmkdhdmkgkbfgcpefhockpplokelgkfk`.

Dashboard: https://chrome.google.com/webstore/devconsole/475e1955-3459-4c31-a9e5-c0ec9375475b/kmkdhdmkgkbfgcpefhockpplokelgkfk/edit/status
