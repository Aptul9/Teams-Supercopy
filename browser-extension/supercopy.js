(function (root) {
  "use strict";

  const CONTENT = '[id^="content-"]';
  const BODY = '[id^="message-body-"]';
  const WRAPPER = '[data-testid="message-wrapper"]';
  const EDITABLE = 'input, textarea, [contenteditable]:not([contenteditable="false"]), [role="textbox"]';
  const QUOTE = 'blockquote, [itemtype*="Reply"], [data-message-object="quoted-reply"]';
  const clean = value => (value || "").replace(/\u00a0/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  const escape = value => String(value).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]);
  const element = node => node?.nodeType === 1 ? node : node?.parentElement;
  const editable = node => !!element(node)?.closest(EDITABLE);

  function timestamp(id) {
    const date = new Date(Number(id));
    if (!Number.isFinite(date.getTime())) return "unknown time";
    const pad = number => String(number).padStart(2, "0");
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function chatTitle(doc) {
    const parts = doc.title.split(" | ");
    if (parts.length >= 3 && /^(chat|conversation|conversazione)$/i.test(parts[0])) return clean(parts[1]);
    const heading = doc.querySelector('[data-tid="chat-header-title"], [data-tid="chat-title"], [data-tid="chat-topic"]');
    return clean(heading?.textContent) || clean(parts.length >= 3 ? parts[1] : doc.title.replace(/\s*[|\-]\s*Microsoft Teams.*$/i, "")) || "Microsoft Teams";
  }

  function isEmoji(img) {
    return /emoji|emoticon/i.test(`${img.getAttribute("itemtype") || ""} ${img.getAttribute("data-tid") || ""}`)
      || /\/emoticons?\//i.test(img.getAttribute("src") || "");
  }

  function partsFrom(content) {
    const parts = [];
    let text = "";
    const flush = () => {
      if (clean(text)) parts.push({ kind: "text", text: clean(text) });
      text = "";
    };
    function walk(node) {
      if (node.nodeType === 3) { text += node.nodeValue; return; }
      if (node.nodeType !== 1) return;
      if (node.matches('script, style, button, [data-tid="quoted-reply-unverified"]')) return;
      if (node.getAttribute("aria-hidden") === "true" && node.tagName !== "IMG" && !node.querySelector("img")) return;
      if (node.matches(QUOTE)) {
        flush();
        const author = node.querySelector('[itemprop="author"], [itemprop="mri"], [data-tid="quoted-reply-author"]');
        const time = node.querySelector('[itemprop="time"], time, [data-tid="quoted-reply-timestamp"]');
        const body = node.querySelector('[itemprop="text"], [data-tid="quoted-reply-text"], [data-tid="quoted-reply-preview-content"]');
        const label = /(?:Inizio citazione|Begin quote|Start of quote), (.+?), (\d{1,2}\/\d{1,2}\/\d{2,4},? \d{1,2}[:.]\d{2}(?:\s?[AP]M)?), ([\s\S]*?), (?:fine citazione|end quote|end of quote)/i.exec(node.getAttribute("aria-label") || "");
        const copy = node.cloneNode(true);
        copy.querySelectorAll('[itemprop="author"], [itemprop="mri"], [itemprop="time"], time, [data-tid="quoted-reply-author"], [data-tid="quoted-reply-timestamp"]').forEach(el => el.remove());
        parts.push({ kind: "quote", author: clean(label?.[1] || author?.textContent || time?.previousElementSibling?.textContent), time: clean(label?.[2] || time?.textContent || time?.getAttribute("datetime")), text: clean(label?.[3] || (body || copy).textContent) });
        return;
      }
      if (node.tagName === "IMG") {
        if (isEmoji(node)) { text += node.alt; return; }
        flush();
        parts.push({ kind: "image", element: node, src: node.currentSrc || node.getAttribute("src") || "", alt: node.alt || "" });
        return;
      }
      if (node.tagName === "BR") { text += "\n"; return; }
      const block = /^(P|DIV|LI|PRE|TR|H[1-6])$/.test(node.tagName);
      if (block && text && !text.endsWith("\n")) text += "\n";
      if (node.tagName === "LI") text += "- ";
      for (const child of node.childNodes) walk(child);
      if (node.tagName === "TD" || node.tagName === "TH") text += "\t";
      if (block) text += "\n";
    }
    for (const child of content.childNodes) walk(child);
    flush();
    return parts;
  }

  function readMessages(doc) {
    const chat = chatTitle(doc);
    const messages = [];
    for (const content of doc.querySelectorAll(CONTENT)) {
      const match = /^content-(\d{10,})$/.exec(content.id);
      if (!match || editable(content) || content.closest(QUOTE)) continue;
      const id = match[1];
      const body = doc.getElementById(`message-body-${id}`);
      if (!body || !body.contains(content)) continue;
      const authorNode = doc.getElementById(`author-${id}`);
      const name = authorNode?.querySelector('[data-tid="author"], [data-tid="message-author-name"]') || authorNode?.firstElementChild || authorNode;
      const author = clean(name?.textContent) || clean(body.querySelector('[data-tid="message-author-name"]')?.textContent);
      messages.push({ id, chat, author: author || "Unknown author", time: timestamp(id), content, body, scope: content.closest(WRAPPER) || body, parts: partsFrom(content) });
    }
    return messages;
  }

  function selectedMessages(doc, messages) {
    const selection = doc.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return [];
    if (editable(selection.anchorNode) || editable(selection.focusNode)) return [];
    const start = element(selection.anchorNode)?.closest(WRAPPER) || element(selection.anchorNode)?.closest(BODY);
    const end = element(selection.focusNode)?.closest(WRAPPER) || element(selection.focusNode)?.closest(BODY);
    // Both ends must belong to a real message. Never enrich captions or sidebar selections.
    if (!messages.some(m => m.scope === start) || !messages.some(m => m.scope === end)) return [];
    return messages.filter(message => {
      for (let i = 0; i < selection.rangeCount; i++) {
        const range = selection.getRangeAt(i);
        if (!range.intersectsNode(message.content)) continue;
        const bounds = doc.createRange();
        bounds.selectNodeContents(message.content);
        const intersection = range.cloneRange();
        if (range.compareBoundaryPoints(0, bounds) < 0) intersection.setStart(message.content, 0);
        if (range.compareBoundaryPoints(2, bounds) > 0) intersection.setEnd(message.content, message.content.childNodes.length);
        const fragment = intersection.cloneContents();
        if (clean(fragment.textContent) || fragment.querySelector("img")) return true;
      }
      return false;
    });
  }

  function formatMessages(messages, images = new Map()) {
    if (!messages.length) return null;
    const text = [`Teams chat: ${messages[0].chat}`, ""];
    const html = [`<p><b>Teams chat: ${escape(messages[0].chat)}</b></p>`];
    let imageCount = 0;
    let missingImages = 0;
    for (const message of messages) {
      const header = `[${message.time}] ${message.author}`;
      text.push(header);
      html.push(`<p><b>${escape(header)}</b>`);
      if (!message.parts.length) {
        text.push("(no text: attachment or card)");
        html.push("<br>(no text: attachment or card)");
      }
      for (const part of message.parts) {
        if (part.kind === "image") {
          const number = ++imageCount;
          const image = images.get(part.src);
          if (image?.data?.startsWith("data:image/")) {
            text.push(`[image ${number}: ${image.source}, embedded in HTML]`);
            html.push(`<br>[image ${number}]<br><img alt="" src="${escape(image.data)}">`);
          } else {
            missingImages++;
            text.push(`[image ${number}: not available, hover the message and copy again]`);
            html.push(`<br>[image ${number}: not available]`);
          }
        } else {
          const line = part.kind === "quote"
            ? `> in reply to ${part.author || "Unknown author"}${part.time ? ` (${part.time})` : ""}: ${part.text}`
            : part.text;
          text.push(line);
          html.push(`<br>${escape(line).replace(/\n/g, "<br>")}`);
        }
      }
      text.push("");
      html.push("</p>");
    }
    return { text: text.join("\n").trimEnd() + "\n", html: html.join(""), count: messages.length, images: imageCount, missingImages };
  }

  const api = { CONTENT, BODY, clean, editable, chatTitle, partsFrom, readMessages, selectedMessages, formatMessages, timestamp };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.TeamsSupercopy = api;
})(globalThis);
