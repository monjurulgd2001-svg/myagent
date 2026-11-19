// Built-in extension of the app's Android built-in browser (GeckoView).
//  * Gemini session: answers "get" with ONLY the Google session cookies
//    gemini.google.com uses. They go straight to the app on this device.
//  * Image Search: relays the picture overlay (content.js) <-> app:
//    selections and prompt requests go to the app; the app pushes the
//    selection ("basket"), per-picture status and toasts back.
//  * Picture download for the app (fallback when the app's own download
//    fails because of CORS / hot-link rules). No cookies are sent.
const NAMES = new Set([
  "SID", "HSID", "SSID", "APISID", "SAPISID", "SIDCC", "NID", "AEC",
  "__Secure-1PSID", "__Secure-3PSID",
  "__Secure-1PSIDTS", "__Secure-3PSIDTS",
  "__Secure-1PSIDCC", "__Secure-3PSIDCC",
  "__Secure-1PAPISID", "__Secure-3PAPISID",
]);
const DOMAINS = new Set([".google.com", "google.com", "gemini.google.com", ".gemini.google.com"]);
let port = null;
const tabs = new Set();
let basket = { srcs: [], v: 0, pages: 0 };
// v89: a video job sent before any tab has connected (the browser
// page is still loading — on a slow network that is minutes) was
// silently dropped by toTabs() and the app waited the full 6 min
// for a driver that never got the job. Queue it instead and
// deliver it to the first Gemini tab that connects.
let pendingVideo = null;
function isGeminiTab(p) {
  try {
    const u = p.sender && p.sender.tab && p.sender.tab.url;
    return !u || u.indexOf('gemini.google.com') !== -1;
  } catch (e) { return true; }
}

function toTabs(m) {
  for (const t of tabs) {
    try { t.postMessage(m); } catch (e) {}
  }
}

async function cookies(msg) {
  try {
    const all = await browser.cookies.getAll({ url: "https://gemini.google.com/app" });
    const c = all.filter((x) => NAMES.has(x.name) && DOMAINS.has(x.domain));
    port && port.postMessage({ id: msg.id, cookies: c });
  } catch (e) {
    port && port.postMessage({ id: msg.id, error: String(e) });
  }
}

async function fetchPic(msg) {
  try {
    const r = await fetch(msg.src, { credentials: "omit" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const blob = await r.blob();
    if (blob.size > 25 * 1024 * 1024) throw new Error("picture too large");
    const data = await new Promise((ok, bad) => {
      const fr = new FileReader();
      fr.onload = () => ok(fr.result);
      fr.onerror = () => bad(fr.error);
      fr.readAsDataURL(blob);
    });
    port && port.postMessage({ id: msg.id, data: data });
  } catch (e) {
    port && port.postMessage({ id: msg.id, error: String(e) });
  }
}

function fromApp(msg) {
  if (!msg) return;
  switch (msg.cmd) {
    case "get": cookies(msg); break;
    case "fetch": fetchPic(msg); break;
    case "basket":
      basket = { srcs: msg.srcs || [], v: msg.v || 0, pages: msg.pages || 0 };
      toTabs({ type: "basket", srcs: basket.srcs, v: basket.v, pages: basket.pages });
      break;
    case "status": toTabs({ type: "status", src: msg.src, state: msg.state, message: msg.message || "" }); break;
    case "toast": toTabs({ type: "toast", msg: msg.msg || "" }); break;
    case "video":
      // v89: queue when no tab is connected yet (page still
      // loading) — dropping the job made the app time out with
      // no driver ever running.
      if (tabs.size === 0) {
        pendingVideo = msg;
      } else {
        toTabs({ type: "video", prompt: msg.prompt, model: msg.model, jobId: msg.jobId });
      }
      break;
  }
}

browser.runtime.onConnect.addListener((p) => {
  if (p.name !== "ais-tab") return;
  tabs.add(p);
  p.postMessage({ type: "basket", srcs: basket.srcs, v: basket.v, pages: basket.pages });
  // v89: deliver a queued video job to the first Gemini tab.
  if (pendingVideo && isGeminiTab(p)) {
    try { p.postMessage({ type: "video", prompt: pendingVideo.prompt, model: pendingVideo.model, jobId: pendingVideo.jobId }); } catch (e) {}
    pendingVideo = null;
  }
  p.onMessage.addListener((m) => {
    if (m && m.type === "q" && port) port.postMessage(m);
  });
  p.onDisconnect.addListener(() => tabs.delete(p));
});

function connect() {
  try {
    port = browser.runtime.connectNative("ais");
  } catch (e) {
    port = null;
    setTimeout(connect, 1000);
    return;
  }
  port.onMessage.addListener(fromApp);
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, 1000);
  });
}

connect();
