"use strict";
const toggle = document.getElementById("enabled");
const status = document.getElementById("status");
chrome.storage.local.get({ enabled: true }).then(settings => { toggle.checked = settings.enabled; });
toggle.addEventListener("change", async () => {
  await chrome.storage.local.set({ enabled: toggle.checked });
  await refresh();
});
async function refresh() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  try {
    const result = await chrome.tabs.sendMessage(tab.id, { type: "supercopy-status" });
    status.textContent = `${toggle.checked ? "Active" : "Paused"}. ${result.messages} loaded messages.`;
  } catch {
    status.textContent = "Open Teams Web, then reload its tab once.";
  }
}
void refresh();
