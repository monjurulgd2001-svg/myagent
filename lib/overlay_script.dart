/// JavaScript injected into every tab of the controlled Chromium window
/// through the Chrome DevTools Protocol (`Page.addScriptToEvaluateOnNewDocument`).
///
/// It draws, inside a closed shadow root (so no site CSS leaks in or out):
///  * a floating toolbar on the hovered image: "Prompt" (generate now) and
///    a tick box (mark for batch);
///  * a coloured frame + status tag on every ticked / queued / running /
///    finished image;
///  * a dock at the bottom ("N selected · Generate prompts · Select all ·
///    Clear") while at least one image is ticked.
///
/// Requests are put in `window.__aisOutbox`; the app collects them by
/// calling `window.__aisTake()` every ~0.5 s. No `Runtime.enable` and no
/// CDP binding are used, because Google sign-in treats those as
/// automation ("This browser or app may not be secure"). The app pushes
/// status back by calling `window.__aisStatus({src, state, message})`.
///
/// The tick selection ("basket") lives in the **app**, not in the page, so
/// it survives navigation to other pages and other sites: every tab gets
/// the current basket pushed via `window.__aisBasket(srcs, version, pages)`.
const String overlayScript = r'''
(() => {
  try {
    if (window.top !== window.self) return;
    if (window.__aisInstalled) return;
    // No picture overlay on sign-in pages / login popups.
    if (/^accounts\.(google|youtube)\./.test(location.hostname) || window.opener) return;
    window.__aisInstalled = true;
  } catch (e) { return; }

  // Touch UI (Android built-in browser): no hover, so a "Select pictures"
  // button switches to a mode where tapping a picture ticks it.
  const TOUCH = !!window.__aisTouchUI;
  let selectMode = false, fab = null;
  const outbox = [];
  let lastSeen = 0;
  let basketVersion = -1;   // version of the app-side basket this tab shows
  let basketPages = 0;      // how many pages the basket pictures come from
  // Called by the app (poll). Marks the tab as connected.
  Object.defineProperty(window, '__aisTake', {
    value: () => { lastSeen = Date.now(); return JSON.stringify({ v: basketVersion, q: outbox.splice(0) }); },
    configurable: false, enumerable: false, writable: false,
  });
  const MIN = 72;
  let sel = new Map();     // src -> img element or null (app basket mirror)
  const stat = new Map();  // src -> {el, state, message}
  let hoverImg = null, host = null, root = null, bar = null, btnGen = null,
      btnSel = null, btnCap = null, snip = null, layer = null, dock = null, dockCount = null, toastEl = null;
  let lastX = -1, lastY = -1, moveRaf = 0, layoutRaf = 0, toastTimer = 0, ticker = 0;
  const frames = new Map(); // src -> frame element

  const svg = (d) => '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">' + d + '</svg>';
  const I_SPARK = svg('<path fill="currentColor" d="M11 2.5l1.8 5.2 5.2 1.8-5.2 1.8L11 16.5l-1.8-5.2L4 9.5l5.2-1.8zM18.5 14l.9 2.6 2.6.9-2.6.9-.9 2.6-.9-2.6-2.6-.9 2.6-.9z"/>');
  const I_BOX = svg('<rect x="4" y="4" width="16" height="16" rx="3" fill="none" stroke="currentColor" stroke-width="2"/>');
  const I_TICK = svg('<path fill="currentColor" d="M9.2 16.6 4.9 12.3l-1.4 1.4 5.7 5.7L20.6 8l-1.4-1.4z"/>');
  const I_ERR = svg('<path fill="currentColor" d="M11 6h2v8h-2zm0 10h2v2h-2z"/>');
  const I_CAM = svg('<path fill="currentColor" d="M9 4 7.2 6H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-3.2L15 4zm3 4.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zm0 2a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z"/>');
  const I_SNIP = svg('<path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><circle cx="12" cy="12" r="2.2" fill="currentColor"/>');
  const I_WAIT = svg('<path fill="currentColor" d="M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16zm1 8.4 3 1.8-.8 1.3L11 13V7h2z"/>');

  const CSS = `
    *{box-sizing:border-box;font-family:"Segoe UI",system-ui,-apple-system,sans-serif;}
    .bar{position:fixed;display:none;gap:6px;z-index:3;}
    .b{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:32px;padding:0 12px 0 10px;border:0;border-radius:16px;
       background:rgba(22,23,31,.84);color:#fff;font-size:12px;font-weight:600;cursor:pointer;box-shadow:0 2px 10px rgba(0,0,0,.35);
       backdrop-filter:blur(6px);transition:background .12s,transform .12s;}
    .b:hover{background:#6C5CE7;transform:translateY(-1px);}
    .b.sel{width:32px;padding:0;}
    .b.sel.on{background:#6C5CE7;}
    .layer{position:fixed;left:0;top:0;width:0;height:0;z-index:1;}
    .frame{position:fixed;border:3px solid #6C5CE7;border-radius:10px;pointer-events:none;box-shadow:0 0 0 1px rgba(255,255,255,.6) inset;}
    .frame.queued{border-color:#64748b;} .frame.running{border-color:#f59e0b;}
    .frame.done{border-color:#10b981;} .frame.error{border-color:#ef4444;}
    .tag{position:absolute;left:6px;top:6px;display:inline-flex;align-items:center;gap:5px;max-width:calc(100% - 12px);padding:3px 9px 3px 5px;
       border-radius:12px;background:#6C5CE7;color:#fff;font-size:11px;font-weight:600;pointer-events:auto;cursor:pointer;white-space:nowrap;overflow:hidden;
       box-shadow:0 2px 8px rgba(0,0,0,.3);}
    .queued .tag{background:#64748b;} .running .tag{background:#f59e0b;} .done .tag{background:#10b981;} .error .tag{background:#ef4444;}
    .tag svg{flex:none;width:14px;height:14px;}
    .spin{flex:none;width:12px;height:12px;margin:1px;border:2px solid rgba(255,255,255,.45);border-top-color:#fff;border-radius:50%;animation:s .8s linear infinite;}
    @keyframes s{to{transform:rotate(360deg);}}
    .dock{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);display:none;align-items:center;gap:8px;padding:8px 8px 8px 16px;
       border-radius:26px;background:rgba(22,23,31,.94);color:#fff;font-size:13px;font-weight:600;white-space:nowrap;max-width:calc(100vw - 24px);box-shadow:0 10px 30px rgba(0,0,0,.45);z-index:4;}
    .d{height:34px;padding:0 14px;white-space:nowrap;flex:none;border:0;border-radius:17px;background:rgba(255,255,255,.13);color:#fff;font-size:12px;font-weight:600;cursor:pointer;}
    .d:hover{background:rgba(255,255,255,.22);} .d.go{background:#6C5CE7;} .d.go:hover{background:#7D6EF0;}
    .toast{position:fixed;right:24px;bottom:90px;display:none;max-width:360px;padding:10px 14px;border-radius:12px;background:rgba(22,23,31,.94);
       color:#fff;font-size:12.5px;box-shadow:0 8px 24px rgba(0,0,0,.4);z-index:5;}
    .fab{position:fixed;right:14px;bottom:16px;display:inline-flex;align-items:center;gap:8px;height:46px;padding:0 18px 0 14px;
       border:1px solid rgba(255,255,255,.10);border-radius:23px;background:rgba(22,23,31,.94);color:#fff;font:600 14px/1 system-ui,-apple-system,Roboto,sans-serif;
       letter-spacing:.1px;box-shadow:0 8px 24px rgba(0,0,0,.45);z-index:4;-webkit-tap-highlight-color:transparent;transition:background .15s,transform .1s;}
    .fab:active{transform:scale(.96);}
    .fab.on{background:#6C5CE7;border-color:rgba(255,255,255,.18);} .fab svg{width:18px;height:18px;}
    .touch .dock{bottom:74px;flex-wrap:wrap;justify-content:center;white-space:normal;padding:12px;gap:8px;width:max-content;
       border-radius:20px;border:1px solid rgba(255,255,255,.08);font-family:system-ui,-apple-system,Roboto,sans-serif;}
    .touch .dock .cnt{width:100%;text-align:center;}
    .touch .d{height:42px;padding:0 18px;font-size:14px;border-radius:12px;font-family:inherit;-webkit-tap-highlight-color:transparent;}
    .touch .d:active{transform:scale(.97);}
    .touch .toast{left:50%;right:auto;transform:translateX(-50%);bottom:140px;max-width:calc(100vw - 32px);}
    .touch .tag{font-size:12.5px;padding:5px 11px 5px 7px;}
    .b.cap{width:32px;padding:0;}
    .snipBtn{position:fixed;left:14px;bottom:16px;display:inline-flex;align-items:center;justify-content:center;gap:7px;height:40px;padding:0 14px 0 12px;
       border:1px solid rgba(255,255,255,.10);border-radius:20px;background:rgba(22,23,31,.88);color:#fff;font-size:12.5px;font-weight:600;cursor:pointer;
       box-shadow:0 6px 18px rgba(0,0,0,.35);opacity:.82;z-index:4;transition:opacity .15s,background .15s;-webkit-tap-highlight-color:transparent;}
    .snipBtn:hover{opacity:1;background:#6C5CE7;} .snipBtn svg{width:17px;height:17px;}
    .touch .snipBtn{height:46px;width:46px;padding:0;border-radius:23px;opacity:.95;} .touch .snipBtn span{display:none;}
    .snip{position:fixed;left:0;top:0;right:0;bottom:0;cursor:crosshair;background:rgba(8,8,16,.28);z-index:6;touch-action:none;}
    .snipBox{position:fixed;display:none;border:2px solid #A79BFF;border-radius:6px;background:rgba(108,92,231,.10);box-shadow:0 0 0 9999px rgba(0,0,0,.38);pointer-events:none;}
    .snipHint{position:fixed;top:16px;left:50%;transform:translateX(-50%);padding:9px 14px;border-radius:12px;background:rgba(22,23,31,.94);color:#fff;
       font-size:13px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,.4);white-space:nowrap;pointer-events:none;}
  `;

  const srcOf = (img) => (img && (img.currentSrc || img.src)) || '';
  function usable(img) {
    if (!img || img.tagName !== 'IMG') return false;
    const s = srcOf(img);
    if (!s || s.startsWith('data:image/svg') || s.startsWith('data:image/gif;base64,R0lGOD')) return false;
    const r = img.getBoundingClientRect();
    return r.width >= MIN && r.height >= MIN;
  }
  // Largest picture of the srcset (Pinterest 236x thumbnail -> 736x /
  // originals), so the prompt is made from a sharp image.
  function bestSrc(img) {
    let best = srcOf(img), bw = 0;
    const ss = img.srcset || '';
    if (ss) {
      for (const part of ss.split(/,\s+(?=\S)/)) {
        const bits = part.trim().split(/\s+/);
        if (!bits[0]) continue;
        let v = 1;
        if (bits[1]) {
          const n = parseFloat(bits[1]);
          if (!isNaN(n)) v = bits[1].endsWith('w') ? n : n * 1000;
        }
        if (v > bw) { bw = v; try { best = new URL(bits[0], location.href).href; } catch (e) {} }
      }
    }
    return best.replace(/^(https:\/\/i\.pinimg\.com\/)(\d+x\d*)\//, (m, a) => a + '736x/');
  }
  const info = (img) => ({ src: srcOf(img), hi: bestSrc(img), alt: (img.alt || img.title || '').slice(0, 300),
                           w: img.naturalWidth || 0, h: img.naturalHeight || 0 });
  const bigEnough = (el) => { const r = el.getBoundingClientRect(); return r.width >= MIN && r.height >= MIN; };
  function bgUrl(el) {
    try {
      const b = getComputedStyle(el).backgroundImage || '';
      const m = /url\(["']?([^"')]+)["']?\)/.exec(b);
      if (!m || m[1].startsWith('data:image/svg')) return '';
      return new URL(m[1], location.href).href;
    } catch (e) { return ''; }
  }
  const isImg = (el) => el && el.tagName === 'IMG';
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const frame2 = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 30))));
  const stop = (e) => { e.stopPropagation(); };

  function ensure() {
    if (host && host.isConnected) return true;
    const parent = document.documentElement;
    if (!parent) return false;
    if (!host) {
      host = document.createElement('ais-image-prompt');
      host.style.cssText = 'all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
      root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = '<style>' + CSS + '</style>' +
        '<div class="layer"></div>' +
        '<div class="bar" style="pointer-events:auto">' +
          '<button class="b gen" title="Generate an image prompt from this picture">' + I_SPARK + '<span>Prompt</span></button>' +
          '<button class="b cap" title="Capture exactly what you see (locked pictures, video frames, canvas) and make a prompt">' + I_CAM + '</button>' +
          '<button class="b sel" title="Tick to add this picture to the batch">' + I_BOX + '</button>' +
        '</div>' +
        '<button class="snipBtn" style="pointer-events:auto" title="Snip any area of the page (Alt+Shift+S) and make a prompt from it">' + I_SNIP + '<span>Snip</span></button>' +
        '<div class="dock" style="pointer-events:auto"><span class="cnt"></span>' +
          '<button class="d go" title="Generate prompts for all ticked pictures, one by one">Generate prompts</button>' +
          '<button class="d all" title="Tick every picture on this page">Select all</button>' +
          '<button class="d clr">Clear</button></div>' +
        '<div class="toast"></div>' +
        (TOUCH ? '<button class="fab" style="pointer-events:auto"></button>' : '');
      if (TOUCH) {
        const wrap = document.createElement('div');
        wrap.className = 'touch';
        while (root.firstChild) wrap.appendChild(root.firstChild);
        root.appendChild(wrap);
      }
      layer = root.querySelector('.layer');
      bar = root.querySelector('.bar');
      btnGen = root.querySelector('.gen');
      btnSel = root.querySelector('.sel');
      btnCap = root.querySelector('.cap');
      root.querySelector('.snipBtn').addEventListener('click', (e) => { e.preventDefault(); startSnip(); });
      dock = root.querySelector('.dock');
      dockCount = root.querySelector('.cnt');
      toastEl = root.querySelector('.toast');
      fab = root.querySelector('.fab');
      if (fab) {
        fab.innerHTML = I_BOX + '<span>Select pictures</span>';
        fab.addEventListener('click', (e) => {
          e.preventDefault();
          selectMode = !selectMode;
          toast(selectMode ? 'Tap pictures to select them' : 'Selection mode off');
          schedule();
        });
      }
      for (const ev of ['pointerdown', 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'touchstart', 'touchend']) {
        root.addEventListener(ev, stop);
      }
      btnGen.addEventListener('click', (e) => { e.preventDefault(); if (hoverImg) promptFor(hoverImg); });
      btnCap.addEventListener('click', (e) => { e.preventDefault(); if (hoverImg) capture(hoverImg, kindOf(hoverImg)); });
      btnSel.addEventListener('click', (e) => { e.preventDefault(); if (hoverImg && isImg(hoverImg)) toggle(hoverImg); });
      root.querySelector('.go').addEventListener('click', (e) => { e.preventDefault(); sendSelected(); });
      root.querySelector('.all').addEventListener('click', (e) => { e.preventDefault(); selectAll(); });
      root.querySelector('.clr').addEventListener('click', (e) => {
        e.preventDefault();
        if (!connected()) return;
        sel.clear(); post('clear_basket', []); schedule();
      });
    }
    parent.appendChild(host);
    return true;
  }

  function toast(msg) {
    if (!ensure()) return;
    toastEl.textContent = msg;
    toastEl.style.display = 'block';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.style.display = 'none'; }, 2600);
  }

  const connected = () => {
    if (Date.now() - lastSeen > 4000) {
      toast('AI Image Studio is not connected to this tab. Reopen the browser from the app.');
      return false;
    }
    return true;
  };
  const post = (action, images) => outbox.push(JSON.stringify(
      { action, images, page: location.href, title: document.title }));

  function toggle(img) {
    const s = srcOf(img);
    if (!s || !connected()) return;
    if (sel.has(s)) { sel.delete(s); post('unselect', [{ src: s }]); }
    else { sel.set(s, img); stat.delete(s); post('select', [info(img)]); }
    schedule();
  }

  function unselectSrc(src) {
    if (!connected()) return;
    sel.delete(src); post('unselect', [{ src }]); schedule();
  }

  function selectAll() {
    if (!connected()) return;
    const add = [];
    for (const img of document.images) {
      if (add.length >= 300) break;
      if (!usable(img)) continue;
      const s = srcOf(img);
      if (sel.has(s)) continue;
      const st = stat.get(s);
      if (st && st.state !== 'error') continue; // already queued / done
      sel.set(s, img); add.push(info(img));
    }
    if (add.length) post('select', add);
    toast(add.length ? add.length + ' pictures ticked' : 'No new pictures found on this page');
    schedule();
  }

  function send(action, imgs) {
    if (!connected()) return false;
    const items = [], seen = new Set();
    for (const img of imgs) {
      const i = info(img);
      if (!i.src || seen.has(i.src)) continue;
      seen.add(i.src);
      items.push(i);
      stat.set(i.src, { el: img, state: 'queued', message: '' });
    }
    if (!items.length) return false;
    post(action, items);
    toast(items.length === 1 ? 'Sent to AI Image Studio' : items.length + ' pictures queued in AI Image Studio (one by one)');
    schedule();
    return true;
  }

  function sendSelected() {
    if (!sel.size || !connected()) return;
    const n = sel.size;
    for (const [src, el] of sel) stat.set(src, { el, state: 'queued', message: '' });
    sel.clear();
    post('generate_basket', []);
    toast(n === 1 ? 'Sent to AI Image Studio' : n + ' pictures queued in AI Image Studio (one by one)');
    schedule();
  }

  // Basket pushed by the app (all ticked pictures, from every page).
  window.__aisBasket = (srcs, v, pages) => {
    try {
      const next = new Map();
      for (const src of srcs || []) {
        const old = sel.get(src);
        next.set(src, old && old.isConnected ? old : findImg(src));
      }
      sel = next;
      basketVersion = v;
      basketPages = pages || 0;
      schedule();
    } catch (e) {}
  };

  function findImg(src) {
    for (const img of document.images) if (srcOf(img) === src) return img;
    return null;
  }

  window.__aisStatus = (o) => {
    try {
      if (!o || !o.src) return;
      capDone(o.src);
      const cur = stat.get(o.src) || { el: findImg(o.src) };
      cur.state = o.state || 'queued';
      cur.message = o.message || '';
      if (!cur.el || !cur.el.isConnected) cur.el = findImg(o.src);
      stat.set(o.src, cur);
      schedule();
    } catch (e) {}
  };
  window.__aisToast = (m) => { try { toast(String(m)); } catch (e) {} };

  // ---------------------------------------------------------------- hover
  function pickHover() {
    moveRaf = 0;
    if (lastX < 0) return;
    const found = imgAt(lastX, lastY);
    if (found !== hoverImg) { hoverImg = found; schedule(); }
  }

  // Finds the picture under the pointer even when the site covers it with
  // other layers (Pinterest pin cards, hover washes, transparent "protect"
  // divs, lazy wrappers, shadow DOM): 1) the stack of elements at the
  // point, 2) a geometric scan of every picture / video on the page (the
  // smallest one containing the point wins), 3) CSS background pictures.
  function imgAt(x, y) {
    let els = [];
    try { els = document.elementsFromPoint(x, y); } catch (e) {}
    const extra = [];
    for (const el of els.slice(0, 10)) {
      if (el !== host && el.shadowRoot) { try { extra.push(...el.shadowRoot.elementsFromPoint(x, y)); } catch (e) {} }
    }
    if (extra.length) els = extra.concat(els);
    const skip = (el) => el === host || el === document.body || el === document.documentElement;
    let n = 0;
    for (const el of els) {
      if (skip(el)) continue;
      if (isImg(el) && usable(el)) return el;
      if ((el.tagName === 'VIDEO' || el.tagName === 'CANVAS') && bigEnough(el)) return el;
      if (++n > 30) break;
    }
    const hit = (r) => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    let best = null, area = Infinity;
    const scan = (list, okFn) => {
      for (const el of list) {
        if (!okFn(el)) continue;
        const r = el.getBoundingClientRect();
        if (!hit(r)) continue;
        const a = r.width * r.height;
        if (a >= area) continue;
        const st = getComputedStyle(el);
        if (st.visibility === 'hidden' || st.display === 'none') continue;
        area = a; best = el;
      }
    };
    scan(document.images, usable);
    if (!best) scan(document.getElementsByTagName('video'), bigEnough);
    if (best) return best;
    n = 0;
    for (const el of els) {
      if (skip(el)) continue;
      if (++n > 14) break;
      if (bigEnough(el) && bgUrl(el)) return el;
    }
    return null;
  }

  const kindOf = (el) => isImg(el) ? 'image' : el.tagName === 'VIDEO' ? 'video' : el.tagName === 'CANVAS' ? 'canvas' : 'picture';

  // "Prompt" on the hover bar: pictures by URL (sharpest version), CSS
  // background pictures by their URL, videos / canvas as a captured frame.
  function promptFor(el) {
    if (isImg(el)) return send('single', [el]);
    const u = el.tagName === 'VIDEO' || el.tagName === 'CANVAS' ? '' : bgUrl(el);
    if (!u) return capture(el, kindOf(el));
    if (!connected()) return;
    stat.set(u, { el, state: 'queued', message: '' });
    post('single', [{ src: u, hi: u, alt: (el.getAttribute('aria-label') || el.title || '').slice(0, 300), w: 0, h: 0 }]);
    toast('Sent to AI Image Studio');
    schedule();
  }

  // ------------------------------------------------------------- capture
  // Takes the pixels exactly as shown (the app screenshots that area), so
  // it works for locked / protected pictures, video frames, canvas and
  // CSS art too. The overlay hides itself until the app has the shot.
  const capWait = new Map();
  const hideUi = (on) => { if (host) host.style.visibility = on ? 'hidden' : ''; };
  function capDone(id) {
    const t = capWait.get(id);
    if (t === undefined) return;
    clearTimeout(t); capWait.delete(id);
    if (!capWait.size) hideUi(false);
  }
  async function capture(el, kind, area) {
    if (!connected()) return;
    if (el) {
      const r0 = el.getBoundingClientRect();
      if (r0.top < 0 || r0.left < 0 || r0.bottom > innerHeight || r0.right > innerWidth) {
        try { el.scrollIntoView({ block: 'center', inline: 'center' }); } catch (e) {}
        await sleep(400);
      }
      if (el.tagName === 'VIDEO') { try { if (!el.paused) el.pause(); } catch (e) {} }
    }
    hideUi(true);
    await frame2();
    const r = el ? el.getBoundingClientRect() : area;
    const vv = window.visualViewport;
    const ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
    const vw = vv ? vv.width : innerWidth, vh = vv ? vv.height : innerHeight;
    const x0 = Math.max(r.left, ox), y0 = Math.max(r.top, oy);
    const x1 = Math.min(r.left + r.width, ox + vw), y1 = Math.min(r.top + r.height, oy + vh);
    if (x1 - x0 < 16 || y1 - y0 < 16) { hideUi(false); toast('Nothing visible to capture there'); return; }
    const id = 'capture:' + kind + ':' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
    const label = { video: 'Video frame', canvas: 'Canvas capture', picture: 'Captured picture', image: 'Captured picture', area: 'Snipped area' }[kind] || 'Capture';
    const alt = el ? ((el.alt || el.title || el.getAttribute('aria-label') || '') + '').slice(0, 300) : '';
    const item = {
      src: id, hi: '', alt: alt || label, kind,
      w: Math.round((x1 - x0) * devicePixelRatio), h: Math.round((y1 - y0) * devicePixelRatio),
      rect: { x: x0 + scrollX, y: y0 + scrollY, w: x1 - x0, h: y1 - y0, vx: x0, vy: y0 },
      frac: { x: (x0 - ox) / vw, y: (y0 - oy) / vh, w: (x1 - x0) / vw, h: (y1 - y0) / vh },
      dpr: devicePixelRatio,
    };
    if (el) stat.set(id, { el, state: 'queued', message: '' });
    capWait.set(id, setTimeout(() => capDone(id), 5000));
    post('capture', [item]);
  }
  window.__aisCapDone = (id) => { try { if (id) capDone(id); else { for (const k of [...capWait.keys()]) capDone(k); hideUi(false); } } catch (e) {} };
  // App fallback for pictures that cannot be downloaded: bring it on
  // screen, hide the overlay and report where it is (document px).
  window.__aisCapPrep = async (src) => {
    let el = findImg(src);
    if (!el) for (const x of document.querySelectorAll('*')) { if (bgUrl(x) === src) { el = x; break; } }
    if (!el) return '';
    el.scrollIntoView({ block: 'center', inline: 'center' });
    await sleep(450);
    hideUi(true);
    await frame2();
    const r = el.getBoundingClientRect();
    const x0 = Math.max(r.left, 0), y0 = Math.max(r.top, 0);
    const x1 = Math.min(r.right, innerWidth), y1 = Math.min(r.bottom, innerHeight);
    if (x1 - x0 < 16 || y1 - y0 < 16) { hideUi(false); return ''; }
    setTimeout(() => hideUi(false), 4000);
    return JSON.stringify({ x: x0 + scrollX, y: y0 + scrollY, w: x1 - x0, h: y1 - y0 });
  };

  // Snip: drag a rectangle over anything on the page.
  function startSnip() {
    if (snip || !ensure() || !connected()) return;
    selectMode = false;
    const box = (TOUCH ? root.firstChild : root);
    snip = document.createElement('div');
    snip.className = 'snip';
    snip.style.pointerEvents = 'auto';
    snip.innerHTML = '<div class="snipHint">' + (TOUCH ? 'Drag over the area to capture - tap to cancel'
        : 'Drag over the area to capture - Esc to cancel') + '</div><div class="snipBox"></div>';
    box.appendChild(snip);
    const sb = snip.querySelector('.snipBox');
    let st = null, cur = null;
    const rectOf = () => ({ left: Math.min(st.x, cur.x), top: Math.min(st.y, cur.y),
                            width: Math.abs(cur.x - st.x), height: Math.abs(cur.y - st.y) });
    const end = () => { if (snip) { snip.remove(); snip = null; } removeEventListener('keydown', onKey, true); schedule(); };
    const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); end(); } };
    addEventListener('keydown', onKey, true);
    snip.addEventListener('pointerdown', (e) => {
      e.preventDefault(); e.stopPropagation();
      st = cur = { x: e.clientX, y: e.clientY };
      try { snip.setPointerCapture(e.pointerId); } catch (er) {}
    });
    snip.addEventListener('pointermove', (e) => {
      if (!st) return;
      e.preventDefault();
      cur = { x: e.clientX, y: e.clientY };
      const r = rectOf();
      sb.style.display = 'block';
      sb.style.left = r.left + 'px'; sb.style.top = r.top + 'px';
      sb.style.width = r.width + 'px'; sb.style.height = r.height + 'px';
    });
    snip.addEventListener('pointerup', (e) => {
      e.preventDefault(); e.stopPropagation();
      if (!st) { end(); return; }
      cur = { x: e.clientX, y: e.clientY };
      const r = rectOf();
      end();
      if (r.width < 24 || r.height < 24) { toast('Snip cancelled'); return; }
      capture(null, 'area', r);
    });
  }

  // Touch: in selection mode a tap on a picture ticks it (and does not
  // follow the link around it).
  function onTap(e) {
    if (!selectMode) return;
    try { if (e.composedPath && e.composedPath().includes(host)) return; } catch (er) {}
    const img = imgAt(e.clientX, e.clientY);
    if (!img) return;
    e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
    if (isImg(img)) toggle(img);
    else promptFor(img); // video / canvas / CSS picture: capture it
  }

  function onMove(e) {
    lastX = e.clientX; lastY = e.clientY;
    if (!moveRaf) moveRaf = requestAnimationFrame(pickHover);
  }

  // --------------------------------------------------------------- layout
  function schedule() {
    if (!layoutRaf) layoutRaf = requestAnimationFrame(layout);
  }

  function frameFor(src) {
    let f = frames.get(src);
    if (!f) {
      f = document.createElement('div');
      f.className = 'frame';
      f.innerHTML = '<div class="tag"></div>';
      f.firstChild.addEventListener('click', (e) => {
        e.preventDefault();
        if (sel.has(src)) unselectSrc(src); else { stat.delete(src); schedule(); }
      });
      layer.appendChild(f);
      frames.set(src, f);
    }
    return f;
  }

  function layout() {
    layoutRaf = 0;
    if (!ensure()) return;
    const vw = innerWidth, vh = innerHeight;

    // hover toolbar
    if (hoverImg && hoverImg.isConnected) {
      const r = hoverImg.getBoundingClientRect();
      if (r.bottom > 0 && r.top < vh && r.width >= MIN) {
        const pic = isImg(hoverImg);
        btnSel.style.display = pic ? '' : 'none';
        btnGen.title = pic ? 'Generate a detailed image prompt from this picture'
            : (hoverImg.tagName === 'VIDEO' ? 'Capture this video frame and make a prompt' : 'Make a prompt from this picture');
        const ticked = pic && sel.has(srcOf(hoverImg));
        btnSel.classList.toggle('on', ticked);
        btnSel.innerHTML = ticked ? I_TICK : I_BOX;
        btnSel.title = ticked ? 'Untick' : 'Tick to add this picture to the batch';
        bar.style.display = 'flex';
        const bw = bar.offsetWidth || 120;
        const top = Math.max(r.top, 0) + 8;
        // Top-left corner: sites put their own buttons top-right (Pinterest "Save").
        const left = Math.min(Math.max(r.left, 0) + 8, vw - bw - 8);
        bar.style.top = top + 'px';
        bar.style.left = Math.max(left, 4) + 'px';
      } else bar.style.display = 'none';
    } else bar.style.display = 'none';

    // frames for ticked + tracked pictures
    const live = new Set();
    const draw = (src, el, state, message) => {
      if (!el || !el.isConnected) return;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) return;
      live.add(src);
      const f = frameFor(src);
      f.className = 'frame ' + state;
      f.style.left = r.left + 'px'; f.style.top = r.top + 'px';
      f.style.width = r.width + 'px'; f.style.height = r.height + 'px';
      const tag = f.firstChild;
      const label = {
        selected: I_TICK + 'Selected',
        queued: I_WAIT + 'Queued',
        running: '<span class="spin"></span>Analyzing...',
        done: I_TICK + 'Prompt ready',
        error: I_ERR + 'Failed',
      }[state] || state;
      if (tag.__l !== label) { tag.innerHTML = label; tag.__l = label; }
      tag.title = message || (state === 'selected' ? 'Click to untick' : 'Click to hide');
    };
    let onPage = 0;
    for (const [src, el0] of sel) {
      let el = el0;
      if (!el || !el.isConnected) { el = findImg(src); sel.set(src, el); }
      if (el) { onPage++; draw(src, el, 'selected', ''); }
    }
    for (const [src, st] of stat) if (!sel.has(src)) draw(src, st.el, st.state, st.message);
    for (const [src, f] of frames) if (!live.has(src)) { f.remove(); frames.delete(src); }

    // dock
    if (sel.size) {
      const other = sel.size - onPage;
      dockCount.textContent = sel.size + (sel.size === 1 ? ' picture selected' : ' pictures selected') +
          (other > 0 ? ' (' + other + ' on other pages)' : '');
      dock.style.display = 'flex';
    } else dock.style.display = 'none';

    if (fab) {
      fab.classList.toggle('on', selectMode);
      const lbl = selectMode ? I_TICK + '<span>Done</span>' : I_BOX + '<span>Select pictures</span>';
      if (fab.__l !== lbl) { fab.innerHTML = lbl; fab.__l = lbl; }
    }

    const busy = sel.size || stat.size;
    if (busy && !ticker) ticker = setInterval(schedule, 400);
    if (!busy && ticker) { clearInterval(ticker); ticker = 0; }
  }

  addEventListener('keydown', (e) => {
    if (e.altKey && e.shiftKey && (e.key === 'S' || e.key === 's')) { e.preventDefault(); startSnip(); }
  }, true);
  if (TOUCH) addEventListener('click', onTap, { capture: true });
  else addEventListener('pointermove', onMove, { capture: true, passive: true });
  addEventListener('scroll', schedule, { capture: true, passive: true });
  addEventListener('resize', schedule, { passive: true });
  document.addEventListener('pointerleave', () => { lastX = -1; hoverImg = null; schedule(); });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => ensure());
  else ensure();
})();
''';
