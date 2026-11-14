"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");
const api = require("../browser-extension/supercopy.js");
const contentScript = fs.readFileSync(path.join(__dirname, "../browser-extension/content.js"), "utf8");
const coreScript = fs.readFileSync(path.join(__dirname, "../browser-extension/supercopy.js"), "utf8");
const id = 1794042840000;

function message(offset, author, text) {
  return `<div id="message-body-${id + offset}"><div id="author-${id + offset}"><span>${author}</span><span>External</span></div><div id="content-${id + offset}">${text}</div><div>3 reactions Seen by everyone</div></div>`;
}

function fixture(html = message(0, "Alice", "<p>First message</p>") + message(60000, "Bob", "<p>Second message</p>")) {
  const dom = new JSDOM(`<!doctype html><title>Chat | Project Alpha | Tenant | Microsoft Teams</title><body>${html}<textarea id="editor">First message</textarea><div id="captions">First message</div></body>`, { url: "https://teams.microsoft.com/v2/", runScripts: "outside-only" });
  return { dom, doc: dom.window.document };
}

function select(doc, start, end = start) {
  const range = doc.createRange();
  range.setStart(start, 0);
  range.setEnd(end, end.childNodes.length);
  const selection = doc.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function install(dom, trustedEvents = true) {
  dom.window.chrome = {
    storage: { local: { get: async () => ({ enabled: true }) }, onChanged: { addListener() {} } },
    runtime: { onMessage: { addListener() {} } }
  };
  const addListener = dom.window.addEventListener.bind(dom.window);
  if (trustedEvents) {
    dom.window.addEventListener = (type, listener, options) => addListener(type, event => listener(new Proxy(event, {
      get(target, key) {
        if (key === "isTrusted") return true;
        const value = Reflect.get(target, key, target);
        return typeof value === "function" ? value.bind(target) : value;
      }
    })), options);
  }
  dom.window.eval(coreScript);
  dom.window.eval(contentScript);
  dom.window.addEventListener = addListener;
}

function copy(dom, target = dom.window.document.body) {
  const data = new Map();
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { setData: (type, value) => data.set(type, value) } });
  target.dispatchEvent(event);
  return { data, event };
}

test("reads author, epoch timestamp and chat without reaction or trust-label pollution", () => {
  const { doc } = fixture();
  const [first, second] = api.readMessages(doc);
  assert.equal(first.author, "Alice");
  assert.equal(second.author, "Bob");
  assert.equal(first.chat, "Project Alpha");
  assert.match(first.time, /^2026-11-07 \d{2}:14$/);
  assert.deepEqual(first.parts, [{ kind: "text", text: "First message" }]);
});

test("selection includes first message at index zero", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  select(doc, messages[0].content);
  assert.deepEqual(api.selectedMessages(doc, messages).map(m => m.id), [String(id)]);
});

test("partial selection copies entire message", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  const range = doc.createRange();
  range.setStart(messages[0].content.firstChild.firstChild, 2);
  range.setEnd(messages[0].content.firstChild.firstChild, 5);
  doc.getSelection().addRange(range);
  assert.equal(api.formatMessages(api.selectedMessages(doc, messages)).text.split("\n")[3], "First message");
});

test("multi-message selection preserves order", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  select(doc, messages[0].content, messages[1].content);
  assert.equal(api.selectedMessages(doc, messages).length, 2);
});

test("reversed selection preserves document order", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  const selection = doc.getSelection();
  selection.setBaseAndExtent(messages[1].content.firstChild.firstChild, 6, messages[0].content.firstChild.firstChild, 2);
  assert.deepEqual(api.selectedMessages(doc, messages).map(m => m.author), ["Alice", "Bob"]);
});

test("selection starting from an author includes its message", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  select(doc, doc.getElementById(`author-${id}`), messages[1].content);
  assert.equal(api.selectedMessages(doc, messages).length, 2);
});

test("selection ending at the next content's start excludes the untouched message", () => {
  const { doc } = fixture();
  const messages = api.readMessages(doc);
  const range = doc.createRange();
  range.setStart(messages[0].content, 0);
  range.setEnd(messages[1].content, 0);
  doc.getSelection().addRange(range);
  assert.deepEqual(api.selectedMessages(doc, messages).map(m => m.author), ["Alice"]);
});

test("image-only message can be selected without any text", () => {
  const { doc } = fixture(message(0, "Alice", '<img src="data:image/png;base64,AA==" alt="">'));
  const messages = api.readMessages(doc);
  select(doc, messages[0].content);
  assert.equal(api.selectedMessages(doc, messages).length, 1);
});

test("captions with matching text remain excluded", () => {
  const { doc } = fixture();
  select(doc, doc.getElementById("captions"));
  assert.equal(api.selectedMessages(doc, api.readMessages(doc)).length, 0);
});

test("selection extending outside chat remains excluded", () => {
  const { doc } = fixture();
  select(doc, api.readMessages(doc)[0].content, doc.getElementById("captions"));
  assert.equal(api.selectedMessages(doc, api.readMessages(doc)).length, 0);
});

test("editable draft content never becomes a chat message", () => {
  const { doc } = fixture(`<div contenteditable="true">${message(0, "Alice", "Draft")}</div>`);
  assert.equal(api.readMessages(doc).length, 0);
});

test("unrecognized content IDs remain excluded", () => {
  const { doc } = fixture('<div id="content-menu">Settings</div><div id="content-1794042840000">Not in message body</div>');
  assert.equal(api.readMessages(doc).length, 0);
});

test("several quotes stay in their original position", () => {
  const quote = name => `<blockquote itemtype="http://schema.skype.com/Reply"><span itemprop="author">${name}</span><time itemprop="time">07/11/2026 09:14</time><p itemprop="text">Quoted text</p></blockquote>`;
  const { doc } = fixture(message(0, "Bob", `<p>Before</p>${quote("Alice")}<p>Between</p>${quote("Carol")}<p>After</p>`));
  const result = api.formatMessages(api.readMessages(doc));
  assert.match(result.text, /Before\n> in reply to Alice \(07\/11\/2026 09:14\): Quoted text\nBetween\n> in reply to Carol .*\nAfter/);
});

test("current Teams reply cards use full accessibility quote instead of truncated preview", () => {
  const quote = '<div data-message-object="quoted-reply" aria-label="Inizio citazione, Alice Example, 07/11/2026 09:14, Full quoted message, fine citazione"><div data-tid="quoted-reply-card"><span>Alice Example</span><span data-tid="quoted-reply-timestamp">07/11/2026 09:14</span><span data-tid="quoted-reply-preview-content">Full quoted...</span></div></div>';
  const { doc } = fixture(message(0, "Bob", `${quote}<p>Response</p>`));
  const result = api.formatMessages(api.readMessages(doc));
  assert.match(result.text, /> in reply to Alice Example \(07\/11\/2026 09:14\): Full quoted message\nResponse/);
  assert.doesNotMatch(result.text, /Full quoted\.\.\./);
});

test("author outside message body in current Teams wrapper remains selectable", () => {
  const { doc } = fixture(`<div data-testid="message-wrapper"><time>Today</time><span id="author-${id}" data-tid="message-author-name">Alice</span><div id="message-body-${id}"><div id="content-${id}" data-message-content=""><p>Message</p></div></div></div>`);
  const messages = api.readMessages(doc);
  select(doc, doc.getElementById(`author-${id}`), messages[0].content);
  assert.equal(api.selectedMessages(doc, messages)[0].author, "Alice");
});

test("multiline text, lists and Unicode survive", () => {
  const { doc } = fixture(message(0, "Renée", "<p>è già così<br>next line</p><ul><li>one</li><li>two</li></ul><pre>a\n  b</pre>"));
  const result = api.formatMessages(api.readMessages(doc));
  assert.match(result.text, /è già così\nnext line\n- one\n- two\na\n  b/);
  assert.match(result.html, /è già così<br>next line/);
});

test("copied HTML escapes active content and author markup", () => {
  const { doc } = fixture(message(0, "Alice &amp; Bob", '<p>&lt;script&gt;bad&lt;/script&gt;</p><script>bad()</script><button>Copy</button>'));
  const result = api.formatMessages(api.readMessages(doc));
  assert.match(result.html, /Alice &amp; Bob/);
  assert.match(result.html, /&lt;script&gt;bad&lt;\/script&gt;/);
  assert.doesNotMatch(result.html, /<script>|bad\(\)|Copy/);
});

test("images embed in HTML with plain-text marker at the right position", () => {
  const { doc } = fixture(message(0, "Alice", '<p>Before</p><img src="blob:https://teams.microsoft.com/photo" alt="image"><p>After</p>'));
  const images = new Map([["blob:https://teams.microsoft.com/photo", { data: "data:image/png;base64,AA==", source: "original" }]]);
  const result = api.formatMessages(api.readMessages(doc), images);
  assert.match(result.text, /Before\n\[image 1: original, embedded in HTML\]\nAfter/);
  assert.match(result.html, /<img alt="" src="data:image\/png;base64,AA==">/);
  assert.equal(result.missingImages, 0);
});

test("unavailable image is explicit rather than an authenticated or expiring URL", () => {
  const { doc } = fixture(message(0, "Alice", '<img src="https://example.com/photo?token=private" alt="image">'));
  const result = api.formatMessages(api.readMessages(doc));
  assert.equal(result.missingImages, 1);
  assert.doesNotMatch(result.text + result.html, /token=|example.com/);
});

test("emoji images become text instead of attachments", () => {
  const { doc } = fixture(message(0, "Alice", '<p>OK <img data-tid="emoji" alt=":thumbsup:" src="https://example.com/emoticon.png"></p>'));
  const result = api.formatMessages(api.readMessages(doc));
  assert.equal(result.images, 0);
  assert.match(result.text, /OK :thumbsup:/);
});

test("Teams media hidden only from accessibility still embeds", () => {
  const { doc } = fixture(message(0, "Alice", '<p>Photo</p><div aria-hidden="true"><img aria-hidden="true" src="data:image/png;base64,AA=="></div>'));
  const result = api.formatMessages(api.readMessages(doc), new Map([["data:image/png;base64,AA==", { data: "data:image/png;base64,AA==", source: "loaded image" }]]));
  assert.equal(result.images, 1);
  assert.equal(result.missingImages, 0);
});

test("attachment-only content gets explicit marker", () => {
  const { doc } = fixture(message(0, "Alice", ""));
  assert.match(api.formatMessages(api.readMessages(doc)).text, /no text: attachment or card/);
});

test("ordinary copy event writes text and HTML synchronously", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  install(dom);
  select(doc, api.readMessages(doc)[0].content);
  const { data, event } = copy(dom);
  assert.equal(event.defaultPrevented, true);
  assert.match(data.get("text/plain"), /^Teams chat: Project Alpha\n\n\[/);
  assert.match(data.get("text/html"), /<b>.*Alice<\/b>/);
});

test("first ordinary image copy waits for embedded bytes before writing clipboard", async t => {
  const { dom, doc } = fixture(message(0, "Alice", '<p>Photo</p><img src="data:image/png;base64,AA==" alt="image">'));
  t.after(() => dom.window.close());
  let resolveWrite;
  let credentials;
  const written = new Promise(resolve => { resolveWrite = resolve; });
  dom.window.AbortSignal = AbortSignal;
  dom.window.fetch = async (url, options) => { credentials = options.credentials; return { ok: true, blob: async () => new dom.window.Blob(["png"], { type: "image/png" }) }; };
  dom.window.ClipboardItem = class { constructor(data) { this.data = data; } };
  Object.defineProperty(dom.window.navigator, "clipboard", { value: { write: async items => resolveWrite(items) } });
  install(dom);
  select(doc, api.readMessages(doc)[0].content);
  const result = copy(dom);
  assert.equal(result.event.defaultPrevented, true);
  assert.equal(result.data.size, 0);
  const items = await written;
  await new Promise(setImmediate);
  assert.equal(items.length, 1);
  assert.equal(credentials, "same-origin");
  assert.ok(items[0].data["text/html"].size > 0);
  assert.match(doc.getElementById("teams-supercopy-notice").textContent, /1 image copied/);
});

test("Shift copy leaves original action unchanged", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  install(dom);
  select(doc, api.readMessages(doc)[0].content);
  doc.body.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Shift", shiftKey: true, bubbles: true }));
  const { data, event } = copy(dom);
  assert.equal(event.defaultPrevented, false);
  assert.equal(data.size, 0);
});

test("compose box copy is never intercepted", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  install(dom);
  select(doc, api.readMessages(doc)[0].content);
  doc.getElementById("editor").focus();
  assert.equal(copy(dom, doc.getElementById("editor")).data.size, 0);
});

test("captions copy event stays untouched", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  install(dom);
  select(doc, doc.getElementById("captions"));
  assert.equal(copy(dom).event.defaultPrevented, false);
});

test("Teams portal toolbar Copy resolves the actual message", async t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  doc.body.insertAdjacentHTML("beforeend", `<div role="toolbar"><button data-tabster='{"observed":{"names":["firstReactionItem-${id}"]}}'>Reaction</button><a role="button" data-tid="message-actions-more">More</a></div><div role="menu"><button role="menuitem">Copia</button></div>`);
  let resolveWrite;
  const written = new Promise(resolve => { resolveWrite = resolve; });
  dom.window.ClipboardItem = class { constructor(data) { this.data = data; } };
  Object.defineProperty(dom.window.navigator, "clipboard", { value: { write: async items => resolveWrite(items) } });
  install(dom);
  doc.querySelector('[data-tid="message-actions-more"]').dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
  doc.querySelector('[role="menuitem"]').click();
  const [item] = await written;
  const text = await new Promise(resolve => {
    const reader = new dom.window.FileReader();
    reader.onload = () => resolve(reader.result);
    reader.readAsText(item.data["text/plain"]);
  });
  assert.match(text, /Alice\nFirst message/);
  assert.doesNotMatch(text, /Bob|Second message/);
});

test("Ctrl+Shift+C blocks Teams shortcut before making original copy", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  let originalCopies = 0;
  let teamsShortcut = false;
  doc.execCommand = command => { assert.equal(command, "copy"); originalCopies++; return true; };
  install(dom);
  doc.body.addEventListener("keydown", () => { teamsShortcut = true; });
  select(doc, api.readMessages(doc)[0].content);
  const event = new dom.window.KeyboardEvent("keydown", { key: "c", ctrlKey: true, shiftKey: true, bubbles: true, cancelable: true });
  doc.body.dispatchEvent(event);
  assert.equal(event.defaultPrevented, true);
  assert.equal(originalCopies, 1);
  assert.equal(teamsShortcut, false);
});

test("page-generated copy and shortcut events never change the system clipboard", async t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  let writes = 0;
  Object.defineProperty(dom.window.navigator, "clipboard", { value: { write: async () => { writes++; } } });
  install(dom, false);
  select(doc, api.readMessages(doc)[0].content);
  doc.body.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "c", ctrlKey: true, altKey: true, shiftKey: true, bubbles: true, cancelable: true }));
  const result = copy(dom);
  await new Promise(setImmediate);
  assert.equal(writes, 0);
  assert.equal(result.event.defaultPrevented, false);
  assert.equal(result.data.size, 0);
});

test("installing content script twice registers only one copy handler", t => {
  const { dom, doc } = fixture();
  t.after(() => dom.window.close());
  install(dom);
  dom.window.eval(contentScript);
  select(doc, api.readMessages(doc)[0].content);
  assert.equal(copy(dom).data.size, 2);
  assert.equal(doc.querySelectorAll("#teams-supercopy-notice").length, 1);
});

test("manifest restricts access to Teams and requests no clipboard read", () => {
  const manifest = require("../browser-extension/manifest.json");
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.permissions, ["storage", "clipboardWrite"]);
  assert.deepEqual(manifest.content_scripts[0].matches, ["https://teams.microsoft.com/*", "https://teams.cloud.microsoft/*"]);
  assert.equal(manifest.background, undefined);
});
