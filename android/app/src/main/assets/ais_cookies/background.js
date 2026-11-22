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
// v151 — a queued video job older than this is dropped (Dart gave up
// long before; it must not start hours later on its own).
const VIDEO_QUEUE_MAX_MS = 240000;
// v98: same queue for page-transport fetches (backendFetch): the
// headless Gemini tab may still be loading when the first backend
// job arrives. Jobs are delivered to ONE tab only — a setup/task
// POST must never run twice.
let pendingBackendFetch = [];
// v121: same queue for session-page reads: the sign-in tab may
// not have connected yet when the app asks for the token.
let pendingSessionPage = [];
// v125: track sessionPage request ids already retried once after a stale
// existing tab replied with an error (no token), so a newly opening
// refresh() tab gets a chance to answer instead of failing early.
const retriedSessionPages = new Set();
function backendFetchTab() {
  for (const t of tabs) {
    if (isGeminiTab(t)) return t;
  }
  return null;
}
// v121: the session-page read goes to the MOST RECENTLY connected
// Gemini tab — the sign-in tab connected last (it loaded /app
// most recently); an older image-search tab would answer with
// the same profile's session, but the newest tab is the one
// whose page the sign-in just settled on.
function sessionPageTab() {
  let found = null;
  for (const t of tabs) {
    if (isGeminiTab(t)) found = t;
  }
  return found;
}
// v151 — a Gemini tab is a port the Gemini page's VIDEO DRIVER opened
// ("ais-gemini"). The old test (tab url unknown => true) also matched
// the picture overlay's "ais-tab" port — which every page (the Gemini
// page too) opens first and which ignores video / backendFetch /
// sessionPage messages — so a video job was posted to a port that
// silently dropped it (live 2026-11-22: 21080s of silence).
function isGeminiTab(p) {
  return p && p.isGemini === true;
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

// v125: import user-saved/pasted Google session cookies into GeckoView's
// own cookie store so headless refresh() and Animation PageBackendTransport
// work with pasted cookies too (no Dart HTTP bot-check).
async function setCookies(msg) {
  try {
    const list = Array.isArray(msg.cookies) ? msg.cookies : [];
    let count = 0;
    for (const item of list) {
      if (!item || !item.name || !item.value) continue;
      if (!NAMES.has(item.name)) continue;
      await browser.cookies.set({
        url: "https://gemini.google.com/",
        name: String(item.name),
        value: String(item.value),
        domain: ".google.com",
        path: "/",
        secure: true,
      });
      count++;
    }
    port && port.postMessage({ id: msg.id, ok: true, count: count });
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
    case "setCookies": setCookies(msg); break;
    case "fetch": fetchPic(msg); break;
    case "basket":
      basket = { srcs: msg.srcs || [], v: msg.v || 0, pages: msg.pages || 0 };
      toTabs({ type: "basket", srcs: basket.srcs, v: basket.v, pages: basket.pages });
      break;
    case "status": toTabs({ type: "status", src: msg.src, state: msg.state, message: msg.message || "" }); break;
    case "toast": toTabs({ type: "toast", msg: msg.msg || "" }); break;
    case "video":
      // v136: deliver ONLY to a connected Gemini tab (never an Image Search
      // tab). If the headless Gemini tab is still loading, queue in
      // pendingVideo so onConnect delivers it as soon as /app attaches.
      const vTab = backendFetchTab();
      if (vTab) {
        try {
          vTab.postMessage({ type: "video", prompt: msg.prompt, model: msg.model, jobId: msg.jobId });
        } catch (e) {
          pendingVideo = Object.assign({}, msg, { at: Date.now() });
        }
      } else {
        pendingVideo = Object.assign({}, msg, { at: Date.now() });
      }
      break;
    case "videoCancel":
      // v151: drop the queued job (if it is that one) and tell every
      // Gemini driver to stop the running job.
      if (pendingVideo && (!msg.jobId || pendingVideo.jobId === msg.jobId)) pendingVideo = null;
      for (const t of tabs) {
        if (!isGeminiTab(t)) continue;
        try { t.postMessage({ type: "videoCancel", jobId: msg.jobId }); } catch (e) {}
      }
      break;
    case "backendFetch":
      // v98: one backend HTTP exchange, run by the Gemini page
      // itself (content.js fetch). Sent to ONE Gemini tab only.
      // Queued when no tab is connected yet (headless tab still
      // loading); the app's own timeout bounds the wait.
      const tab = backendFetchTab();
      const job = { type: "backendFetch", id: msg.id, method: msg.method, url: msg.url, headers: msg.headers || {}, body: msg.body || "" };
      if (tab) {
        try { tab.postMessage(job); } catch (e) { pendingBackendFetch.push(job); }
      } else {
        pendingBackendFetch.push(job);
      }
      break;
    case "sessionPage":
      // v121: read the session token from the Gemini page the
      // browser itself loaded — no HTTP fetch, so no bot check.
      // One Gemini tab only (the newest); queued when none is
      // connected yet; the app's own timeout bounds the wait.
      const sTab = sessionPageTab();
      const sJob = { type: "sessionPage", id: msg.id };
      if (sTab) {
        try { sTab.postMessage(sJob); } catch (e) { pendingSessionPage.push(sJob); }
      } else {
        pendingSessionPage.push(sJob);
      }
      break;
  }
}

browser.runtime.onConnect.addListener((p) => {
  if (p.name !== "ais-tab" && p.name !== "ais-gemini") return;
  p.isGemini = p.name === "ais-gemini";
  tabs.add(p);
  p.postMessage({ type: "basket", srcs: basket.srcs, v: basket.v, pages: basket.pages });
  // v89: deliver a queued video job to the first Gemini tab.
  if (pendingVideo && isGeminiTab(p)) {
    const pv = pendingVideo;
    pendingVideo = null;
    if (Date.now() - (pv.at || 0) <= VIDEO_QUEUE_MAX_MS) {
      try { p.postMessage({ type: "video", prompt: pv.prompt, model: pv.model, jobId: pv.jobId }); } catch (e) {}
    }
  }
  // v98: deliver queued page-transport fetches to this Gemini tab.
  if (pendingBackendFetch.length > 0 && isGeminiTab(p)) {
    const queued = pendingBackendFetch;
    pendingBackendFetch = [];
    for (const job of queued) {
      try { p.postMessage(job); } catch (e) {}
    }
  }
  // v121: deliver queued session-page reads to this Gemini tab.
  if (pendingSessionPage.length > 0 && isGeminiTab(p)) {
    const queued = pendingSessionPage;
    pendingSessionPage = [];
    for (const job of queued) {
      try { p.postMessage(job); } catch (e) {}
    }
  }
  p.onMessage.addListener((m) => {
    if (m && m.type === "sessionPage" && m.error && m.id != null && !retriedSessionPages.has(m.id)) {
      retriedSessionPages.add(m.id);
      if (retriedSessionPages.size > 50) retriedSessionPages.clear();
      pendingSessionPage.push({ type: "sessionPage", id: m.id });
      return;
    }
    if (m && (m.type === "q" || m.type === "backendFetch" || m.type === "sessionPage") && port) port.postMessage(m);
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
