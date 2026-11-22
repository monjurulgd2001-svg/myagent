// v153 — Windows (CDP) twin of the Android video driver.
//
// The video logic is the Android content.js driver (v86–v152)
// VERBATIM — Task mode mandatory, Neon model picker, rich-text
// typing with read-back, the v152 wait decision (4 idle polls
// before the turn is over), truncated MP4 chip detection, keyframe
// follow-ups, blob -> dataUrl download. Only the TRANSPORT differs:
// Android talks to its WebExtension over the 'ais-gemini' port;
// Windows has no extension, so the driver reports into
// window.__ghsVideoOutbox and the app polls window.__ghsVideoTake()
// over CDP (same {q: [...]} shape as the picture overlay's
// __aisTake), starts jobs via window.__ghsVideoStart(jobJson) and
// cancels via window.__ghsVideoCancel(jobId).
//
// The app injects this into the headless Chrome Gemini tab with
// Page.addScriptToEvaluateOnNewDocument + Runtime.evaluate (see
// windows_video_driver.dart). Do NOT hand-edit the driver logic
// here without the matching Android change in content.js — keep
// the two in sync.

const String windowsVideoDriverScript = r'''
(() => {
  try {
    if (window.top !== window.self) return;
    if (!/\.?gemini\.google\.com$/.test(location.hostname)) return;
    if (window.__ghsVideoInstalled) return;
    window.__ghsVideoInstalled = true;
  } catch (e) { return; }

  let running = null; // current jobId, or null
  let cancelledJob = null; // v151: jobId the app asked to stop

  function send(action, data) {
    try { outbox.push(JSON.stringify({ action, data: data || {} })); } catch (e) {}
  }

  // The app collects events by polling window.__ghsVideoTake()
  // (same {q: [...]} shape as the picture overlay's __aisTake, so
  // one Dart parser serves both transports).
  const outbox = [];
  Object.defineProperty(window, '__ghsVideoTake', {
    value: () => { try { return JSON.stringify({ q: outbox.splice(0) }); } catch (e) { return '{"q":[]}'; } },
    configurable: false, enumerable: false, writable: false,
  });
  // The app starts a job by calling this with the job JSON — no
  // extension port on Windows (CDP has no chrome.runtime).
  window.__ghsVideoStart = (jobJson) => {
    try { onJob(JSON.parse(jobJson)); return 'ok'; } catch (e) { return 'error'; }
  };
  // The app cancels a job the same way (v151 cancel chain).
  window.__ghsVideoCancel = (jobId) => {
    try { if (running && (!jobId || jobId === running)) cancelledJob = running; } catch (e) {}
  };

  // v98: page-side fetch — one backend HTTP exchange, run HERE in
  // the Gemini page, so the request IS the browser's own: its
  // cookies, Origin, Referer, sec-fetch headers, HTTP/2 and TLS all
  // come from the real browser. The app only passes method/URL/
  // extra headers/body and gets {status, data} back (base64 data
  // URL, same shape as the picture download). Forbidden headers
  // (Origin/Referer/Cookie/User-Agent/sec-fetch-*) are stripped —
  // fetch sets them from the page itself, and setting them throws.
  
  // v121: read the Gemini session token from THIS page — the
  // browser already loaded /app signed in, so no HTTP fetch is
  // needed at all. (Dart's raw fetch of /u/<n>/app gets a Google
  // bot-check page instead of Gemini — live 2026-11-21: the
  // sign-in itself worked, the verify fetch was what got
  // blocked.) Only the extracted fields leave the page — never
  // the whole HTML. Same field set as Dart's _parseSessionHtml.
  // v125: resilient sessionPage extraction — reads from both GeckoView's
  // window.wrappedJSObject.WIZ_global_data and document innerHTML, and
  // briefly polls on /app when a slow network hydrates WIZ data after
  // document_end.
  
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const norm = (s) => (s || '').toLowerCase();
  const visible = (el) => {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const btns = () => [...document.querySelectorAll('button, [role="button"], a')].filter(visible);
  const textOf = (el) => ((el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || '')).replace(/\s+/g, ' ').trim();
  const findBtn = (needles) => {
    const ns = needles.map((n) => norm(n));
    return btns().find((b) => { const t = norm(textOf(b)); return ns.some((n) => t.includes(n)); }) || null;
  };
  // v90: exact visible-text match — the Chat | Task toggle pill
  // says exactly "Task"; substring matching would also catch
  // "Tasks", "Task settings", "Describe a task", etc.
  const findBtnExact = (label) => {
    const n = norm(label);
    return btns().find((b) => norm((b.textContent || '').replace(/\s+/g, ' ').trim()) === n) || null;
  };
  // v90: is Gemini Task mode on? The selected pill (aria-pressed /
  // selected / active class) or the composer placeholder saying
  // "Describe a task" (Chat mode says "Ask Gemini"). v165: on a
  // finished task thread the composer shows a mode-picker dropdown
  // instead of pills ("Open mode picker, currently …") — when its
  // label says Task, Task mode is on.
  function taskModeOn() {
    try {
      const pill = findBtnExact('Task');
      if (pill) {
        const ap = (pill.getAttribute('aria-pressed') || '') + ' ' + (pill.getAttribute('aria-selected') || '');
        if (/true/i.test(ap)) return true;
        if (/(selected|active|checked)/i.test((pill.className || '').toString())) return true;
      }
      const picker = findBtn(['mode picker']);
      if (picker && /currently\s+task/i.test(textOf(picker))) return true;
      const eds = [...document.querySelectorAll('div[contenteditable="true"], textarea')].filter(visible);
      return eds.some((el) => {
        const ph = (el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('data-placeholder') || '') + ' ' + (el.getAttribute('aria-label') || '');
        return /task/i.test(ph);
      });
    } catch (e) { return false; }
  }
  // v165 — pick Task out of the composer's mode-picker dropdown
  // (finished task thread: "Open mode picker, currently Gemini…",
  // no Chat | Task pills). Same option hunt as ensureModel: open
  // the menu, take the short "Task" option, wait for Task mode to
  // show. Strict: unlike the pill click below, an unverified menu
  // pick is NOT trusted — the caller falls through to New Chat.
  async function pickTaskFromModePicker() {
    try {
      const picker = findBtn(['mode picker']);
      if (!picker) return false;
      picker.click();
      let opt = null;
      const end = Date.now() + 4000;
      while (Date.now() < end && !opt) {
        await sleep(300);
        opt = [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="option"], [role="radio"], li, button, [role="button"]')]
          .filter(visible)
          .filter((el) => el !== picker && !picker.contains(el) && !el.contains(picker))
          .find((el) => {
            const t = norm((el.textContent || '').replace(/\s+/g, ' ').trim());
            return t.length > 0 && t.length <= 120 && (t === 'task' || /^task[\s—-]/.test(t));
          }) || null;
      }
      if (!opt) { try { picker.click(); } catch (e) {} return false; }
      opt.click();
      const end2 = Date.now() + 10000;
      while (Date.now() < end2) {
        if (taskModeOn()) return true;
        await sleep(500);
      }
      return false;
    } catch (e) { return false; }
  }
  // v165 — one attempt on the current page: the Chat | Task pill,
  // then the mode-picker menu. Gives the composer a moment to
  // rebuild after the previous task (slow network) before
  // declaring either absent. No navigation here.
  async function ensureTaskModeOnce() {
    if (taskModeOn()) return true;
    const settleEnd = Date.now() + 4000;
    while (Date.now() < settleEnd) {
      if (findBtnExact('Task') || findBtn(['mode picker'])) break;
      await sleep(500);
    }
    const pill = findBtnExact('Task');
    if (pill) {
      pill.click();
      const end = Date.now() + 10000;
      while (Date.now() < end) {
        if (taskModeOn()) return true;
        await sleep(500);
      }
      return true;
    }
    return await pickTaskFromModePicker();
  }
  // v90: make sure Task mode is on. Returns true when on (or when
  // the Task pill was clicked — a segmented control does not no-op
  // on its inactive option, so the click means the mode switched
  // even if the page gives no detectable confirmation). Returns
  // false only when no Task toggle exists at all. v103: Task mode
  // is MANDATORY (user order 2026-11-20, "must task mode lagbe") —
  // the caller fails the job when this returns false; there is no
  // Chat fallback anymore (a Task prompt in a Chat composer gets a
  // plain-chat image answer, not a video). v165 (live 2026-11-23
  // 00:13): bulk line 2 failed "__notask__" — the driver reuses
  // one headless tab, and on the finished task thread the composer
  // has a mode picker and no Task pill, so the old one-shot pill
  // lookup failed. Now: pill, then the mode-picker menu, then a
  // fresh chat ("New Chat" — each bulk line is its own task thread
  // anyway) and one more try on the fresh composer. Only when all
  // of that fails does the job report task_mode with the picker's
  // actual contents in the button dump.
  async function ensureTaskMode() {
    try {
      if (taskModeOn()) return true;
      if (await ensureTaskModeOnce()) return true;
      const newChat = findBtn(['New Chat']);
      if (!newChat) return false;
      newChat.click();
      await sleep(2500);
      const end = Date.now() + 20000;
      while (Date.now() < end) {
        const eds = [...document.querySelectorAll('div[contenteditable="true"], textarea')].filter(visible);
        if (eds.length) break;
        await sleep(500);
      }
      await sleep(1500);
      if (taskModeOn()) return true;
      return await ensureTaskModeOnce();
    } catch (e) { return false; }
  }
  // v151 — model picker. The Gemini composer has a model chip on the
  // right ("Neon v" in the user's 2026-11-22 screenshot) next to the
  // Chat | Task pill. The job needs BOTH: Task mode AND the chosen
  // model (Neon by default) selected before the prompt is typed.
  // v103 had dropped the model step ("the task agent picks its own
  // model") — the user says Task + Neon is what makes the video.
  const MODEL_TEXTS = {
    auto: ['Auto'],
    hydrogen: ['Hydrogen', 'Everyday help'],
    neon: ['Neon', 'Deeper analysis'],
    carbon: ['Carbon', 'Code & complex work'],
  };
  const MODEL_WORDS = ['auto', 'hydrogen', 'neon', 'carbon'];
  const flat = (el) => ((el.textContent || '')).replace(/\s+/g, ' ').trim();
  const lastEditor = () => {
    const eds = [...document.querySelectorAll('div[contenteditable="true"], textarea')].filter(visible);
    return eds.length ? eds[eds.length - 1] : null;
  };
  // The composer's model chip: a short button whose text starts with a
  // model word, preferably the one level with the prompt box.
  function modelChip() {
    const ed = lastEditor();
    const er = ed ? ed.getBoundingClientRect() : null;
    const cands = btns().filter((b) => {
      if (b.closest('[role="menu"], [role="listbox"]')) return false;
      const t = norm(flat(b));
      return t.length > 0 && t.length <= 40 && !/^automat/.test(t) && MODEL_WORDS.some((w) => t === w || t.startsWith(w));
    });
    if (!cands.length) return null;
    if (er) {
      const near = cands.filter((b) => {
        const r = b.getBoundingClientRect();
        return Math.abs((r.top + r.height / 2) - (er.top + er.height / 2)) < 160;
      });
      // With a prompt box on screen, only a chip level with it counts
      // (a sidebar button must never be taken for the model picker).
      return near.length ? near[near.length - 1] : null;
    }
    return cands[cands.length - 1];
  }
  const chipHas = (chip, modelId) => {
    const t = norm(textOf(chip));
    return (MODEL_TEXTS[modelId] || [modelId]).some((x) => t.includes(norm(x)));
  };
  // Returns 'ok' (selected / already selected), 'nochip' (picker not
  // found — carry on with what the page shows) or 'fail'.
  async function ensureModel(modelId) {
    try {
      const texts = (MODEL_TEXTS[modelId] || [modelId]).map(norm);
      let chip = null;
      for (let i = 0; i < 10 && !chip; i++) { chip = modelChip(); if (!chip) await sleep(500); }
      if (!chip) return 'nochip';
      if (chipHas(chip, modelId)) return 'ok';
      for (let attempt = 0; attempt < 2; attempt++) {
        chip = modelChip() || chip;
        chip.click();
        let opt = null;
        const end = Date.now() + 4000;
        while (Date.now() < end && !opt) {
          await sleep(300);
          opt = [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="option"], [role="radio"], li, button, [role="button"]')]
            .filter(visible)
            .filter((el) => el !== chip && !chip.contains(el) && !el.contains(chip))
            .find((el) => {
              const t = norm(flat(el));
              return t.length > 0 && t.length <= 120 && texts.some((x) => t.includes(x));
            }) || null;
        }
        if (!opt) { try { chip.click(); } catch (e) {} await sleep(300); continue; }
        opt.click();
        await sleep(700);
        const now = modelChip();
        if (now && chipHas(now, modelId)) return 'ok';
      }
      return 'fail';
    } catch (e) { return 'fail'; }
  }
  const dumpButtons = () => btns().slice(0, 30).map((b) => textOf(b).slice(0, 40)).filter(Boolean).join(' | ');
  async function waitFor(fn, ms, label) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = fn();
      if (v) return v;
      await sleep(500);
    }
    throw new Error(label);
  }
  function fail(jobId, step, message) {
    send('video_error', { jobId, step, message, buttons: dumpButtons() });
  }
  function progress(jobId, phase, message) {
    send('video_progress', { jobId, phase, message: message || '' });
  }

  // v103: MODEL_MATCH removed with the Chat fallback — Task mode
  // is mandatory, so the driver never picks a model anymore.

  async function onJob(m) {
    const jobId = (m.jobId || '').toString();
    const prompt = (m.prompt || '').toString();
    const model = (m.model || 'neon').toString();
    if (!jobId || !prompt) return;
    // v151 — a cancelled job needs up to ~0.5s to wind down.
    if (running && cancelledJob === running) {
      for (let i = 0; i < 12 && running; i++) await sleep(300);
    }
    if (running) { fail(jobId, 'busy', 'Ekta animation already cholche.'); return; }
    running = jobId;
    cancelledJob = null;
    try {
      // 1. Chat UI ready (or sign-in wall). v89: 60s, not 30s — on a
      // slow network (9 KB/s seen live) the Gemini page alone can
      // take a minute to load.
      progress(jobId, 'opening', '');
      await waitFor(() => {
        if (findBtn(['Sign in', 'Log in'])) throw new Error('__signin__');
        return document.querySelector('div[contenteditable="true"], textarea') ||
          findBtn(['Gemini', 'Auto', 'Hydrogen', 'Neon', 'Carbon']);
      }, 60000, 'Gemini chat khulche na — net / login check koro.');
      // 2. v90: Task mode — user live-tested: Task mode-e video hoy.
      // Toggle-ta composer-er niche Chat | Task. Already on thakle
      // skip. v103: Task mode MANDATORY (user order "must task mode
      // lagbe") — toggle na pele job fail korbe, Chat diye cholbe
      // na. Task mode-e model pick + tool open lage na: the task
      // agent picks its own model + tool from the description.
      progress(jobId, 'task_mode', 'Task mode khulche…');
      const inTask = await ensureTaskMode();
      if (!inTask) throw new Error('__notask__');
      // v151 — Task AND the chosen model (Neon by default), in that
      // order, then confirm Task is still on (switching the model
      // can rebuild the composer).
      progress(jobId, 'selecting_model', 'Model select korche…');
      const modelState = await ensureModel(model);
      if (modelState === 'fail') throw new Error('__nomodel__');
      if (modelState === 'nochip') progress(jobId, 'selecting_model', 'Model chip pelam na — page-e ja ache seta diye cholche…');
      // Re-check only when the page SHOWS Task as off (aria false) —
      // never click blind a second time (a toggle would switch off).
      const taskPill = findBtnExact('Task');
      const taskShownOff = taskPill && /false/i.test((taskPill.getAttribute('aria-pressed') || '') + ' ' + (taskPill.getAttribute('aria-selected') || '')) && !taskModeOn();
      if (taskShownOff && !(await ensureTaskMode())) throw new Error('__notask__');
      // v101 — the "make a VIDEO, not an image/keyframe" lead now
      // comes from the app (AnimationEngine), on the one prompt the
      // backend and the driver both send, so they can never disagree.
      const sendText = prompt;
      progress(jobId, 'task_mode', 'Task mode-e video banacche…');
      // 3. Type the prompt (rich-text editor) and send. v101 —
      // sendChatText is shared with the keyframe follow-up below.
      // v102 — TYPE, then READ BACK, then PROVE IT LEFT. Gemini's
      // composer is a framework-controlled editor: setting
      // textContent alone often never reaches the app, so Send stays
      // disabled and the click below does nothing — live 2026-11-20
      // the page showed Neon selected with an EMPTY composer while
      // the driver waited 7 min for a video nobody had asked for.
      // Every silent step now fails fast as 'typing' instead.
      const sendChatText = async (text) => {
        const editor = await waitFor(() => {
          const eds = [...document.querySelectorAll('div[contenteditable="true"], textarea')].filter(visible);
          return eds.length ? eds[eds.length - 1] : null;
        }, 15000, 'Prompt box pelam na.');
        const editorText = () => norm((editor.textContent || '') + ' ' + (editor.value || ''));
        const probe = norm(text).slice(0, 24);
        const typeOnce = () => {
          editor.focus();
          let typed = false;
          try { typed = document.execCommand('insertText', false, text); } catch (e) {}
          if (!typed) {
            editor.textContent = text;
            editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          }
        };
        typeOnce();
        await sleep(400);
        if (!editorText().includes(probe)) {
          // Second try: select-all first — a stale caret/selection
          // is the usual reason insertText no-ops.
          try { editor.focus(); document.execCommand('selectAll', false, null); } catch (e) {}
          typeOnce();
          await sleep(400);
        }
        if (!editorText().includes(probe)) throw new Error('__notyped__');
        await sleep(400);
        const sendBtn = findBtn(['Send', 'Start task', 'Create task']) ||
          document.querySelector('button[type="submit"]') ||
          document.querySelector('button[aria-label*="Send"]');
        if (!sendBtn) throw new Error('__nosend__');
        // A disabled Send button is a no-op click: the text never
        // registered with the app (visible() never checked disabled).
        if (sendBtn.disabled || (sendBtn.getAttribute('aria-disabled') || '') === 'true') {
          throw new Error('__notyped__');
        }
        sendBtn.click();
        // Prove the message LEFT: the composer must clear (or the
        // turn must start, "Stop response" on the page) within 3s.
        // A replaced composer node (detached old node) counts too.
        const sentEnd = Date.now() + 3000;
        while (Date.now() < sentEnd) {
          if (!editor.isConnected || !editorText().includes(probe) || findBtn(['Stop response'])) return;
          await sleep(400);
        }
        throw new Error('__nosend__');
      };
      // Remember the videos AND images already on the page, so a
      // stale clip (or an old keyframe) from an earlier turn is never
      // mistaken for the new one.
      const seenSrcs = new Set([...document.querySelectorAll('video')].map((x) => x.src).filter(Boolean));
      const seenImgs = new Set([...document.querySelectorAll('img')].map((x) => x.src).filter(Boolean));
      // v100: same guard for the Task-mode file chip — remember the
      // .mp4 names already on the page before this turn starts.
      const mp4Name = (el) => {
        const t = ((el.textContent || '') + ' ' + (el.getAttribute('title') || '') + ' ' + (el.getAttribute('aria-label') || '')).trim();
        const m = t.match(/[\w\-. ]+\.mp4\b/i);
        return m ? m[0] : '';
      };
      // v152 — the file card's name is truncated ("fire_magnetic_…")
      // with an "MP4" type label underneath, so no ".mp4" is visible
      // at all. Take the filename-like stem off the small card (its
      // text is short — ≤80 chars — so a whole message bubble can
      // never count as a chip).
      const chipStem = (card) => {
        const t = (card.textContent || '').replace(/\s+/g, ' ').trim();
        if (t.length > 80) return '';
        const toks = t.split(' ').filter((w) => /^[\w\-.…]+$/.test(w) && !/^(mp4|open)$/i.test(w) && w.replace(/[.…]+/g, '').length >= 4);
        if (!toks.length) return '';
        return toks.sort((a, b) => b.length - a.length)[0].replace(/[…]+$/, '');
      };
      const isMp4Label = (el) => el.children.length === 0 && /^mp4$/i.test((el.textContent || '').trim());
      const seenChipNames = new Set(
        [...document.querySelectorAll('div, span, a, button')]
          .filter((el) => el.children.length === 0)
          .map(mp4Name).filter(Boolean));
      // v152 — same guard for truncated names: remember the stems
      // already on the page before this turn starts.
      const seenChipStems = new Set();
      [...document.querySelectorAll('div, span')].filter(isMp4Label).forEach((label) => {
        let node = label;
        for (let i = 0; i < 5 && node; i++) {
          const s = chipStem(node);
          if (s) { seenChipStems.add(s); break; }
          node = node.parentElement;
        }
      });
      await sendChatText(sendText);
      // 4. Wait for the finished video. v100: Task 7 min, Chat 5 min
      // (was 5.5 / 4) — live 2026-11-20 the driver gave up at 330s
      // while Gemini was STILL generating ("Stop response" visible)
      // and the video finished a minute later. So the soft deadline
      // now EXTENDS by a minute at a time while "Stop response" is
      // on the page, up to a hard cap 3 min past the soft deadline.
      // Heartbeat every 30s, so the app can tell "driver alive,
      // video slow" apart from "driver dead".
      progress(jobId, 'creating', '');
      // v103: Task only — 7 min (the Chat 5-min wait died with the
      // Chat fallback; Task mode is mandatory).
      // v136 — effectively unlimited wait (10h) per user request.
      const videoWaitMs = 36000000;
      let waitStart = Date.now();
      let deadline = waitStart + videoWaitMs;
      let hardDeadline = waitStart + videoWaitMs + 3600000;
      let lastBeat = 0;
      let found = null;
      let openedChip = null;
      // v101 — the agent sometimes answers a video request with a
      // still keyframe image first (live 2026-11-20: a flame image +
      // "I can adjust the keyframe's framing…"). When the turn
      // finishes with a NEW image but no video, ask it to make the
      // video now (max 2 follow-ups) instead of failing the job.
      let sawStop = false;
      let followUps = 0;
      // v152 — idle tracking for the wait decision below.
      let lastPageSig = '';
      let idlePolls = 0;
      const hasNewImage = () => [...document.querySelectorAll('img')]
        .some((x) => x.src && x.src.startsWith('http') && !seenImgs.has(x.src));
      const sendFollowUp = async () => {
        followUps++;
        [...document.querySelectorAll('img')]
          .forEach((x) => { if (x.src) seenImgs.add(x.src); });
        progress(jobId, 'creating', 'Keyframe pelam — video banate bolchi…');
        await sendChatText('Now create the animation video from this keyframe image — an MP4 video file, 1620x2880, 9:16 vertical, 60fps, seamless loop, cinematic, original unique concept, no text, logo or watermark. Do not make another image.');
        waitStart = Date.now();
        deadline = waitStart + videoWaitMs;
        hardDeadline = waitStart + videoWaitMs + 180000;
        lastBeat = 0;
        sawStop = false;
        idlePolls = 0;
        lastPageSig = '';
      };
      // v100: the Task agent attaches the MP4 as a file chip (a
      // filename, no <video> tag and no mp4 anchor until the viewer
      // opens). Find a NEW .mp4 filename leaf, click its card once
      // so the player renders, then the <video> poll above catches
      // it on the next rounds.
      // v152 — truncated-name chip: the card shows "fire_magnetic_…"
      // plus an "MP4" type label, no visible ".mp4". Find the label,
      // climb to its small card, and take a NEW filename stem.
      const findTruncatedMp4Chip = () => {
        const labels = [...document.querySelectorAll('div, span')].filter(isMp4Label);
        for (const label of labels) {
          let node = label;
          for (let i = 0; i < 5 && node; i++) {
            const stem = chipStem(node);
            if (stem && !seenChipStems.has(stem)) {
              let target = node;
              for (let j = 0; j < 4 && target; j++) {
                if (/^(BUTTON|A)$/.test(target.tagName) || target.getAttribute('role') === 'button') return target;
                target = target.parentElement;
              }
              return node;
            }
            node = node.parentElement;
          }
        }
        return null;
      };
      const findMp4Chip = () => {
        const leaf = [...document.querySelectorAll('div, span, a, button')]
          .find((el) => el.children.length === 0 &&
            mp4Name(el) && !seenChipNames.has(mp4Name(el)));
        if (leaf) {
          let node = leaf;
          for (let i = 0; i < 4 && node; i++) {
            if (/^(BUTTON|A)$/.test(node.tagName) ||
                node.getAttribute('role') === 'button') return node;
            node = node.parentElement;
          }
          return leaf;
        }
        // v152 — no visible ".mp4": try the truncated-name card.
        return findTruncatedMp4Chip();
      };
      // v152 — pure wait decision (no DOM access, so it is unit
      // testable): the loop NEVER breaks on the first Stop-absence
      // again. Live 2026-11-22 12:35 the page showed "2/3 steps"
      // with no "Stop response" and the driver gave up ~2 min before
      // the MP4 rendered. Only 'fail' after idleLimit consecutive
      // idle polls: no Stop, no step indicator, no page change.
      const STEP_RE = /\b\d+\s*\/\s*\d+\s*steps?\b|\bstep\s+\d+\s+of\s+\d+\b/i;
      const IDLE_LIMIT = 4;
      const pageSig = () => {
        try {
          return (document.body ? document.body.innerText.length : 0) + ':' + document.querySelectorAll('video, img, a[href]').length;
        } catch (e) { return ''; }
      };
      const videoWaitDecision = ({ stopPresent, stepPresent, pageChanged, idlePolls: idle, idleLimit, followUps: ups, hasNewImage: img }) => {
        if (stopPresent || stepPresent || pageChanged) return 'wait';
        if (idle < idleLimit) return 'wait';
        if (ups < 2 && img) return 'followup';
        return 'fail';
      };
      while (Date.now() < hardDeadline && !found) {
        if (cancelledJob === jobId) throw new Error('__cancelled__');
        const v = [...document.querySelectorAll('video')].find((x) => x.src && (x.src.startsWith('http') || x.src.startsWith('blob:')) && !seenSrcs.has(x.src));
        if (v) { found = { el: v, url: v.src }; break; }
        const a = [...document.querySelectorAll('a[href]')].find((x) => (/\.mp4(\?|$)/i.test(x.href) || /googlevideo\.com/i.test(x.href)) && !seenSrcs.has(x.href));
        if (a) { found = { el: null, url: a.href }; break; }
        if (!openedChip) {
          const chip = findMp4Chip();
          if (chip) {
            openedChip = chip;
            try { chip.click(); } catch (e) {}
            progress(jobId, 'creating', 'Video file pelam — khulche…');
          }
        }
        if (Date.now() - lastBeat > 30000) {
          lastBeat = Date.now();
          progress(jobId, 'creating', 'Video banacche… (' + Math.round((Date.now() - waitStart) / 1000) + 's)');
        }
        // v101 — generation state. "Stop response" on the page means
        // Gemini is still working: past the soft deadline it buys
        // another minute (up to the hard cap).
        // v152 — the turn is NOT over just because Stop disappeared.
        // Between agent steps ("2/3 steps") Stop briefly goes away
        // while Gemini is still rendering; the old code broke here
        // on the first such poll. videoWaitDecision only calls it
        // over after IDLE_LIMIT consecutive idle polls (no Stop, no
        // step indicator, no page change); then a NEW keyframe image
        // means the agent went image-first (follow up), otherwise
        // fail with the buttons dump.
        const stopBtn = findBtn(['Stop response']);
        if (stopBtn) sawStop = true;
        const stepPresent = STEP_RE.test(document.body ? (document.body.innerText || '') : '');
        const sig = pageSig();
        const pageChanged = sig !== lastPageSig;
        lastPageSig = sig;
        if (stopBtn && Date.now() >= deadline && Date.now() < hardDeadline) {
          deadline = Math.min(Date.now() + 60000, hardDeadline);
          progress(jobId, 'creating', 'Ekhono banacche… (' + Math.round((Date.now() - waitStart) / 1000) + 's) — Gemini ekhono kaaj korche');
        }
        const decision = videoWaitDecision({
          stopPresent: !!stopBtn,
          stepPresent,
          pageChanged,
          idlePolls,
          idleLimit: IDLE_LIMIT,
          followUps,
          hasNewImage: hasNewImage(),
        });
        if (decision === 'wait') {
          if (!stopBtn && !stepPresent && !pageChanged) idlePolls++;
          else idlePolls = 0;
        } else if (decision === 'followup') {
          idlePolls = 0;
          await sendFollowUp();
        } else {
          // Turn confirmed over with no video and nothing to follow
          // up on — fail now instead of waiting out the clock.
          break;
        }
        await sleep(500);
      }
      if (!found) throw new Error('Video toiri hoyni — limit sesh hote pare, ba Gemini error diyeche.');
      let url = found.url;
      let dataUrl = '';
      let durationSec = 0, width = 1620, height = 2880;
      if (found.el) {
        try { durationSec = found.el.duration || 0; width = found.el.videoWidth || 1620; height = found.el.videoHeight || 2880; } catch (e) {}
      }
      if (url.startsWith('blob:')) {
        const blob = await (await fetch(url)).blob();
        if (blob.size > 25 * 1024 * 1024) throw new Error('Video 25 MB-r beshi — download kora jayni.');
        dataUrl = await new Promise((ok, bad) => {
          const fr = new FileReader();
          fr.onload = () => ok(fr.result);
          fr.onerror = () => bad(fr.error);
          fr.readAsDataURL(blob);
        });
        url = '';
      }
      send('video_ready', { jobId, url, dataUrl, durationSec, width, height });
    } catch (e) {
      const msg = String((e && e.message) || e);
      if (msg === '__cancelled__') { /* the app cancelled this job: no event back */ }
      else if (msg === '__signin__') fail(jobId, 'opening', 'Gemini-te sign in kora nei — age Login tab theke sign in koro.');
      else if (msg === '__nomodel__') fail(jobId, 'selecting_model', 'Model select hoyni — composer-er model chip (Neon) khule option pelam na. Gemini web UI bodle geche hote pare.');
      else if (msg === '__notask__') fail(jobId, 'task_mode', 'Task mode pelam na — Task mode chara animation hobe na. Gemini web UI bodle geche hote pare.');
      else if (msg === '__notyped__') fail(jobId, 'typing', 'Prompt box-e lekha bosheni — text type hoyni, tai video-r request jayni.');
      else if (msg === '__nosend__') fail(jobId, 'typing', 'Send button pelam na.');
      else fail(jobId, 'creating', msg);
    } finally {
      running = null;
      cancelledJob = null;
    }
  }
})();
''';
