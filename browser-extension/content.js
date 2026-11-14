(() => {
  "use strict";
  if (globalThis.teamsSupercopyInstalled) return;
  globalThis.teamsSupercopyInstalled = true;
  const api = globalThis.TeamsSupercopy;
  const images = new Map();
  const pending = new Map();
  let enabled = true;
  let shift = false;
  let bypass = false;
  let hovered = null;
  let menuMessage = null;
  let noticeTimer;
  let sequence = 0;

  chrome.storage.local.get({ enabled: true }).then(settings => { enabled = settings.enabled; });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.enabled) enabled = changes.enabled.newValue;
  });

  function notice(message, error = false) {
    let node = document.getElementById("teams-supercopy-notice");
    if (!node) {
      node = document.createElement("div");
      node.id = "teams-supercopy-notice";
      node.setAttribute("role", "status");
      node.style.cssText = "position:fixed;bottom:24px;right:24px;z-index:2147483647;padding:12px 16px;border-radius:8px;color:#fff;font:14px system-ui;box-shadow:0 4px 24px #0004;max-width:360px;pointer-events:none";
      document.documentElement.append(node);
    }
    node.style.background = error ? "#9c2727" : "#242635";
    node.textContent = `Teams Supercopy: ${message}`;
    node.hidden = false;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => { node.hidden = true; }, 2400);
  }

  function report(result) {
    notice(`${result.count} message${result.count === 1 ? "" : "s"}, ${result.images} image${result.images === 1 ? "" : "s"} copied${result.missingImages ? ` (${result.missingImages} unavailable)` : ""}`, result.missingImages > 0);
  }

  async function loadImage(part) {
    if (!part.src || images.has(part.src)) return;
    if (pending.has(part.src)) return pending.get(part.src);
    const job = (async () => {
      let data;
      let source = "loaded image";
      try {
        const url = new URL(part.src, location.href);
        if (!["https:", "blob:", "data:"].includes(url.protocol)) return;
        const response = await fetch(url.href, { credentials: "same-origin", signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error("Image unavailable");
        const blob = await response.blob();
        if (!/^image\/(png|jpe?g|gif|webp)$/i.test(blob.type) || blob.size > 12 * 1024 * 1024) throw new Error("Unsupported image");
        data = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = reject;
          reader.readAsDataURL(blob);
        });
      } catch {
        try {
          const img = part.element;
          if (!img.complete || !img.naturalWidth || img.naturalWidth * img.naturalHeight > 20_000_000) return;
          const canvas = document.createElement("canvas");
          canvas.width = img.naturalWidth;
          canvas.height = img.naturalHeight;
          canvas.getContext("2d").drawImage(img, 0, 0);
          data = canvas.toDataURL("image/png");
          source = "rendered image";
        } catch { return; }
      }
      // Keep a bounded, in-memory cache. No chat data is stored in extension storage.
      if (images.size >= 32) images.delete(images.keys().next().value);
      images.set(part.src, { data, source });
    })().finally(() => pending.delete(part.src));
    pending.set(part.src, job);
    return job;
  }

  function prepare(messages) {
    return Promise.all(messages.flatMap(message => message.parts.filter(part => part.kind === "image").map(loadImage)));
  }

  function selection() {
    const messages = api.readMessages(document);
    return { messages, selected: api.selectedMessages(document, messages) };
  }

  function messageForAction(target) {
    const body = target.closest?.(api.BODY);
    if (body) return body;
    const toolbar = target.closest?.('[role="toolbar"]');
    if (!toolbar?.querySelector('[data-tid="message-actions-more"]')) return null;
    const observed = toolbar.querySelector('[data-tabster*="firstReactionItem-"]')?.getAttribute("data-tabster") || "";
    const id = /firstReactionItem-(\d{10,})/.exec(observed)?.[1];
    return id ? document.getElementById(`message-body-${id}`) : null;
  }

  window.addEventListener("copy", event => {
    if (!event.isTrusted) return;
    sequence++;
    if (!enabled || bypass || shift || api.editable(event.target) || api.editable(document.activeElement) || !event.clipboardData) return;
    const { selected } = selection();
    if (selected.some(message => message.parts.some(part => part.kind === "image" && !images.has(part.src)))) {
      event.preventDefault();
      event.stopImmediatePropagation();
      notice("preparing images...");
      void explicitCopy(selected);
      return;
    }
    const result = api.formatMessages(selected, images);
    if (!result) return;
    event.clipboardData.setData("text/plain", result.text);
    event.clipboardData.setData("text/html", result.html);
    event.preventDefault();
    event.stopImmediatePropagation();
    report(result);
  }, true);

  function originalCopy() {
    bypass = true;
    try { document.execCommand("copy"); } finally { bypass = false; }
  }

  async function explicitCopy(messages) {
    if (!messages.length) { notice("no chat message selected or under the mouse", true); return; }
    const current = ++sequence;
    const url = location.href;
    await prepare(messages);
    if (sequence !== current || location.href !== url || !messages.every(message => message.content.isConnected)) return;
    const result = api.formatMessages(messages, images);
    try {
      await navigator.clipboard.write([new ClipboardItem({
        "text/plain": new Blob([result.text], { type: "text/plain" }),
        "text/html": new Blob([result.html], { type: "text/html" })
      })]);
      report(result);
    } catch (error) { notice(`copy failed: ${error.message}`, true); }
  }

  window.addEventListener("keydown", event => {
    if (!event.isTrusted) return;
    shift = event.shiftKey;
    if ((event.key === "Enter" || event.key === " ") && event.target.closest?.('[data-tid="message-actions-more"], [data-tid="message-actions-menu-hidden-button"]')) {
      menuMessage = messageForAction(event.target);
    }
    if (!enabled || event.isComposing || event.key.toLowerCase() !== "c" || !(event.ctrlKey || event.metaKey) || api.editable(event.target)) return;
    const { messages, selected } = selection();
    if (event.altKey) {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (!event.repeat) void explicitCopy(event.shiftKey ? messages : selected.length ? selected : messages.filter(message => message.body === hovered));
    } else if (selected.length) {
      // Suppress Teams call shortcuts, while retaining the browser's normal copy action.
      event.stopImmediatePropagation();
      if (event.shiftKey) { event.preventDefault(); originalCopy(); }
    }
  }, true);
  window.addEventListener("keyup", event => { shift = event.shiftKey; }, true);
  window.addEventListener("blur", () => { shift = false; sequence++; });
  window.addEventListener("pointerdown", event => { shift = event.shiftKey; }, true);
  window.addEventListener("pointerover", event => {
    if (!enabled) return;
    const body = messageForAction(event.target);
    if (!body) { hovered = null; return; }
    if (body === hovered) return;
    hovered = body;
    void prepare(api.readMessages(document).filter(message => message.body === body));
  }, true);
  document.addEventListener("selectionchange", () => {
    if (enabled) void prepare(selection().selected);
  });
  window.addEventListener("contextmenu", event => {
    shift = event.shiftKey;
    menuMessage = event.target.closest?.(api.BODY) || null;
  }, true);
  window.addEventListener("pointerdown", event => {
    const body = messageForAction(event.target);
    if (body) menuMessage = body;
    else if (!event.target.closest?.('[role="menu"], [role="menuitem"]')) menuMessage = null;
  }, true);
  window.addEventListener("click", event => {
    if (!event.isTrusted) return;
    if (!enabled || shift || event.shiftKey || !menuMessage?.isConnected) return;
    const item = event.target.closest?.('[role="menuitem"]');
    if (!item || !/^(copy|copia)$/i.test(api.clean(item.textContent))) return;
    const messages = api.readMessages(document).filter(message => message.body === menuMessage);
    if (!messages.length) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    void explicitCopy(messages);
    // Close Teams' menu without invoking its own copy handler.
    item.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    menuMessage = null;
  }, true);

  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (message.type !== "supercopy-status") return;
    reply({ enabled, messages: api.readMessages(document).length });
  });
})();
