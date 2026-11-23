# Zedge Studio — Flutter (Android + Windows)

Full Flutter + Kotlin port of the **Gemini HD Studio v2.5.3 Chrome extension**
(Wallpaper Set Designer, AI Metadata & Panel Uploader). One codebase builds:

- **Android release APK** — `GeminiHDStudio-v1.0.0-release.apk`
- **Windows** — the artifact holds exactly two files:
  `GeminiHDStudio-Setup-1.0.0.exe` (Inno Setup installer) and
  `GeminiHDStudio.exe` (the app executable; install via the Setup
  exe — the bare exe needs the support files the installer lays
  down).

Run workflow offers a build choice: **all** / **android** /
**windows**. Build from GitHub Actions — see **BUILD-GITHUB.md**
(Bangla guide).

Package: `com.geminihd.studio` · Flutter **3.35.x** · Android side **Kotlin** · JDK **17**

---

## Gemini Login — how it works (the important part)

The extension worked because Chrome was already signed into Google and it
reused the browser's cookies. A standalone app has no browser cookie jar, so
this app keeps its **own cookie jar per account (u/0–u/5)** and does the same
thing the extension did:

1. **Sign in (Android)** — the Login screen's **Sign in** opens a
   full-screen **built-in Firefox browser** (Mozilla GeckoView, the
   engine inside Firefox for Android) on Google's sign-in page. You
   sign in **on Google's own page** — the app never sees or stores
   your password. Google allows this sign-in because GeckoView is a
   real browser engine, not an embedded WebView (the Android system
   WebView gets "This browser or app may not be secure"). When
   Gemini opens signed in, the screen closes itself and a tiny
   **built-in extension** hands the session cookies
   (`__Secure-1PSID`, `SID`, …) to the app — connecting is
   automatic. The browser profile lives in the app's private data,
   so **Refresh** can later renew the session silently the same way.
   (An app still cannot read the separate Chrome app's cookies —
   the OS forbids it — which is why the sign-in browser is built in.
   Pattern adapted from the AI Image Studio source; see
   `lib/gecko_signin.dart` and `android/.../GeckoBridge.kt`.)
   **Sign in (Windows)** — the app opens its OWN Chrome / Edge
   window (a real browser window on the app's own profile, not an
   embedded frame) plainly for sign-in; the window closes itself
   once Gemini opens signed in, and the session cookies are read
   from that profile — automatic, exactly like Android (see
   `lib/chromium_studio_browser.dart`). The Image Search browser
   on Windows is the same window, driven over the DevTools
   protocol with the same picture-selection overlay.
2. The cookies land in the slot's jar (the **Session cookies** box
   in the "Gemini web session" card can also take a manual paste of
   `__Secure-1PSID` + `__Secure-1PSIDTS`, a full Cookie header, or a
   cookies.txt export — on desktop Chrome: F12 > Application >
   Cookies). **Test** verifies the login exactly like the
   extension: it fetches `gemini.google.com/u/<n>/app`, extracts the
   **SNlM0e token**, build (`bl`), `f.sid` and your account email.
3. All generation then runs over pure Dart HTTP with that cookie jar:
   `StreamGenerate` RPC, resumable image upload to
   `push.clients6.google.com` + `ProcessFile` for image-to-image,
   HD fetch (`=s0`), with Origin/Referer headers mirroring the extension's
   `rules.json`.
4. **Multi-account**: Scan probes the saved jars u/0–u/5, the header
   dropdown switches accounts, **Add Gmail** starts another sign-in,
   and on a quota/limit reply the generator **auto-switches** to the next
   account (extension behaviour).

Cookies live only in the app's on-device storage and are only ever sent to
`gemini.google.com` / Google upload hosts. Sign out from the login screen
clears the WebView and the saved jar.

**The login stays saved — and renews itself.** Once connected, the cookie
jar persists on the device (no re-login on restart). Google rotates the
session cookie (`__Secure-1PSIDTS`) via `Set-Cookie` on its responses; the
app absorbs those rotations into the saved jar on every session fetch,
account scan and generation call — the same thing a browser jar does
silently. On top of that, the app silently renews all saved accounts once
at startup and every 15 minutes while it is open, so the saved login keeps
itself alive with normal use.

---

## Dashboard UI

Modern dark dashboard shell (all screens share the one theme):

- **Palette**: deep-space backgrounds (`#070A14` / `#121830`) with a
  vibrant **violet primary** (`#7C6CFF`), **cyan secondary** (`#22D3EE`)
  and pink badge accent (`#FF7AC6`) — high-contrast text and controls
  throughout, gradient header banner (indigo → violet → teal) and a
  gradient **Generate set** call-to-action.
- **Layout**: prominent header with the app title, quick actions,
  account switcher and live stat chips (sets / Gmail accounts / output
  size). The Set Designer lives in a clean rounded **card**; the
  Showcase is a card gallery.
- **Badge navigation**: a navigation rail (desktop/tablet) or bottom
  navigation bar (phones) — **Studio · Showcase** (badge = number of
  sets) · **Search** · **Login** (badge = signed-in Gmail
  count). Search / Login open as routes; Studio / Showcase
  switch in place.
- **Motion**: fade + slide page transitions on every route and an
  animated cross-fade when switching Studio ↔ Showcase.

## Features (ported from the extension)

- **Set modes**: Single 9:16 · 9:16 + Foldable · Dual (Lock + Home) ·
  24-Hour (4 JPG) · Battery Level (6 JPG) — all at 1620×2880 JPG, ≤8 MB,
  Zedge size rules enforced.
- **Prompt batch mode** (1 line = 1 set), optional **reference image**
  (anchor), per-stage custom prompt fields, story arcs
  (Light/Bloom/Rhythm, Energy/Growth/Awakening), variation strength,
  display target, colour boost, negative prompt, **AI Set Director**.
- **Cloudinary AI upscale** (`e_upscale`) with the extension's
  sign → upload → archive/poll flow, **falling back to local resize** on
  any failure. The Cloudinary **API key** from the original extension
  (`background.js` → `CLOUDINARY_API_KEY`) is **embedded in the app**,
  same as the extension, so upscale works out of the box. The
  credentials are backend-only — they are not shown or editable in
  any settings screen. ⚠️ Because the key lives in the source
  (exactly like the extension), keep the GitHub repo **private**.
- **Image Search + Image to Prompt (integrated)**: search **Google
  Images** and **Pinterest** inside the app's built-in Chromium browser
  (same toolbar as the login browser). A **Mobile / Desktop UA switch**
  controls the browser's user agent — Mobile is the default, so the
  sites serve their responsive phone layouts. Open a picture, tap
  **Pick image from this page** (or the gallery button for an image
  already on the device) — the app reads the page's images (og:image +
  `<img>`), lists the biggest candidates, downloads your pick, and
  opens the actions sheet right there: **Use as Reference**, **Save a
  copy** (to `<app documents>/GeminiHDStudio/Search/`), and **Image to
  Prompt** — the signed-in Gemini web session writes ONE detailed
  production prompt (120–200 words, vertical 9:16 framing) from a
  senior prompt-engineer instruction that analyses 9 layers (subject,
  setting, composition, camera, lighting, colour, style, texture,
  mood) and returns a `[PROMPT]...[/PROMPT]` block (the app extracts
  the prompt). An **Options** panel in the sheet sets the
  **Similarity target** (slider 20–90% + preset chips Fresh 30 /
  Inspired 45 / Balanced 60 / Close 75 / Near copy 90) which decides,
  live, which of the 11 picture aspects **stay the same** and which
  **will change**; toggles for **Auto-add to Prompts list** (append
  the finished prompt to the designer's prompt list instead of
  replacing it) and **Avoid repeating earlier prompts** (a prompt
  that reads like an earlier one from this session is rewritten
  once); and a collapsible preview of the exact Gemini instruction.
  With an optional style note, an editable result, Copy, or the
  designer button to drop it straight into the prompt field. This
  integrated flow replaces the old standalone Image-to-Prompt screen
  and its separate input field. Prompt generation uses the same
  upload + attachment StreamGenerate channel as img2img.
- **Multi-select gallery flow** (sources now Pinterest · Unsplash ·
  Google Images · Lexica): the app-bar checkbox turns on selection
  mode — tapping images right on the page highlights them (violet
  outline + "✓ Selected" badge) instead of navigating, and the picks
  collect in a tray under the browser ("N selected", thumbnails with
  per-image remove, Select all on page, Clear) that is **kept while
  you browse** across pages. **Generate prompts** opens a batch
  sheet: choose the Similarity Target once, generate one prompt per
  selected image (sequential, per-image status, Stop after current,
  retry the failures), edit any prompt, then **Send N prompts to
  Batch Sets** — they land in the designer prompt box as lines with
  Batch mode switched on, ready for the batch queue.
- **Open in Chrome (browser intent)**: both built-in browsers have
  an "Open in Chrome" toolbar button that hands the current page to
  a **separate real Chrome window** — Android fires a Kotlin intent
  at the Chrome app (default-browser fallback), Windows launches
  Chrome (then Edge, then the default browser) with `--new-window`
  at a deliberate size: desktop 1400×920, or phone-sized 430×932
  when the search browser is in Mobile layout, so responsive pages
  render the same outside. Chrome runs the user's own Chrome
  profile/session (it cannot share the app's cookie jar); the
  in-app browser keeps its page, history and selection untouched,
  and on the login screen this doubles as the sign-in fallback —
  sign in in Chrome, then paste the cookies back.
- **Real popup windows**: in the built-in Chromium browser, links
  that open a new window (target=_blank / window.open — source-site
  sign-ins, "open in new tab") open as a full-screen in-app Chromium
  window sharing the same session/cookies, with its own close
  button; it closes itself when the site calls window.close().
  Selection mode also works inside popup windows. (The Gemini login
  browser has had the same popup support from the start.)
- **Batch queue**: with Batch on, the Set Designer shows a live queue
  panel — every prompt line is one job with a status (waiting /
  running / done / failed) and a done counter. A failed set no longer
  stops the batch, and **Stop after current** lets the running set
  finish and skips the rest.
- **Built-in Gemini sign-in**: the Chromium sign-in screen described
  above is the app's own — no external browser or extension needed.
- **AI listing metadata** via the Gemini web session (title ≤30 chars,
  8–12 tags, 20 official Zedge categories, description ≤200 chars) with
  copy title/tags, inline editor and Rewrite-with-AI.
- **Showcase**: set cards, image lightbox, phone **set-preview simulator**,
  **regenerate a single stage**, per-set or all-set **Ready ZIP**
  (`set-01/<slot>.jpg` + root `metadata.json` + `prompts/`), standalone
  `metadata.json`.
- **Import local set**: pick 2/4/6 images → formatted to 1620×2880 JPG,
  optional AI metadata, straight into the Showcase.
- **Upload to Panel**: R2 Worker upload with SHA-256 + Firebase Realtime
  Database queue push, Spread auto-rotation or a chosen account, Test DB —
  same record shape as the extension (`distribute.dart` port).

### Where files go (no browser downloads in an app)
- Generated sets: `<app documents>/GeminiHDStudio/Gemini_HD/<set folder>/`
- Ready ZIP / metadata.json: `<app documents>/GeminiHDStudio/Exports/`
  (the app shows the full path after export; on Windows that's under your
  Documents folder, on Android it's the app's documents directory).

## Differences from the extension (honest list)
- Images are saved as real files instead of `chrome.downloads`.
- History keeps the latest 20 sets, same as the extension.
- No background service worker: generation runs while the app is open.
- The extension zip is kept in `original-extension/` for reference.

## Signing
The release APK is signed with the **debug key** (same as the user's other
GitHub-built apps) so the artifact installs directly. For Play Store /
update-over-install with your own key, add a keystore and a release
`signingConfig` in `android/app/build.gradle`.

## Verified vs not verified
- ✅ `flutter pub get` (locked) · `flutter analyze` — **no issues** ·
  `flutter test` — **19/19 passed** (app boot, cookie-paste parsing, cookie
  rotation absorption (Set-Cookie merge), Zedge
  size rules, StreamGenerate response parsing, metadata JSON extraction,
  quota detection, image-search candidate parsing/ranking, search URL
  builders, generated-prompt cleanup, batch prompt parsing + the live
  batch-queue widget, mobile/desktop UA constants, plus **mobile responsiveness**: home screen rendered
  at 320×568 / 360×640 / 390×844 with Advanced settings open, and a
  Showcase card + set-preview dialog at 320 px — no layout overflows.
  Those tests caught real bugs, all fixed: dropdowns now expand instead
  of overflowing, the card's panel-upload row stacks on phones, the
  preview dialog scales/scrolls, and the login screen's bottom area
  scrolls instead of overflowing when the paste box opens).
- ✅ Also verified running natively: built as a desktop app and run
  live — home UI, prompt typing and the batch queue panel all exercised
  on screen (screenshots in the delivery chat).
- ⏳ The actual GitHub Actions APK/Windows builds and a live Gemini
  generation run are the first real end-to-end test — Google can change
  the Gemini web RPC or tighten WebView sign-in at any time; the cookie
  paste fallback covers the sign-in case.
