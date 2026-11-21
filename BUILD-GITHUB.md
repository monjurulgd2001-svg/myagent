# GitHub দিয়ে Build — Gemini HD Studio

## যা যা পাবে
- **Android:** `GeminiHDStudio-v1.0.0-release.apk` (release APK)
- **Windows:** artifact-এ ঠিক **২টা file** —
  `GeminiHDStudio-Setup-1.0.0.exe` (full setup/installer) আর
  `GeminiHDStudio.exe` (app-এর exe)। PC-তে চালাতে **Setup exe
  install করো** — খালি exe টা একা চলবে না, ওর পাশের DLL/data
  file গুলো installer-ই বসিয়ে দেয়।

## ধাপে ধাপে

1. **নতুন GitHub repo বানাও — অবশ্যই Private রাখো** (app-এর source-এর
   ভিতরে Cloudinary API key আছে, extension-এর মতোই; public repo হলে
   যে কেউ key টা নিয়ে নিতে পারবে)।
2. **পুরো project টা upload করো — সবচেয়ে জরুরি কথা:**
   - শুধু `lib/` folder upload করলে হবে **না**।
   - লুকানো **`.github`** folder টা অবশ্যই সহ upload করতে হবে (Windows-এ
     File Explorer-এ "Hidden items" on করে দেখে নাও; GitHub Desktop /
     `git push` ব্যবহার করলে অটোমেটিক যাবে)।
   - **`installer/`** folder টাও লাগবে — না হলে Windows Setup .exe বানাবে না,
     workflow লাল error দিয়ে থামবে।
   - সহজ রাস্তা: এই project-এর ZIP টা extract করে সব ফাইল repo-তে push করো।
3. Repo-তে **Actions** tab → বামে **"Build Gemini HD Studio (APK + Windows)"**
   → **Run workflow** → dropdown-এ **Ki build korba?** — `all` (APK +
   Windows দুটোই), `android` (শুধু APK) বা `windows` (শুধু Windows)
   বেছে সবুজ **Run workflow** বাটন।
4. ৫–১০ মিনিট পর run-টা খুললে নিচে **Artifacts**-এ download পাবে
   (যেটা build করেছো শুধু সেটাই):
   - `gemini-hd-studio-android-apk` (ভিতরে ১টা APK)
   - `gemini-hd-studio-windows` (ভিতরে ঠিক ২টা file: Setup .exe +
     GeminiHDStudio.exe)
5. চাইলে **Release**-এও পাঠানো যাবে: `v1.0.0` নামে tag push করলেই
   workflow আবার চলবে আর APK + Setup দুটোই Release-এ attach হবে।

## Build configuration (যা আগে থেকে ঠিক করা আছে)
- Flutter **3.35.x**, Android job-এ **JDK 17** (temurin)। Toolchain
  AI Image Studio source app-er shathe milano (v17): AGP **8.9.1**,
  Gradle **8.12**, Kotlin **2.3.21**, compileSdk **36**,
  GeckoView **152**। GeckoView 154+ nite hole AGP 9.1 lagbe — ekhon na।
- Windows job **`windows-2022`** runner-এ চলে — `windows-latest` নিলে
  Visual Studio 2026 আসে; 3.35.x VS 2022 দিয়েই proven। Flutter
  version কোনোদিন আপগ্রেড করলে এই লাইনটা আবার যাচাই করো।
- flutter_inappwebview **নেই** (v17-এ সরানো হয়েছে — ব্যবহারই হতো না),
  তাই Windows build-এ আলাদা NuGet step-ও লাগে না।
- APK আপাতত **debug key** দিয়ে signed — সরাসরি install হবে। Play Store-এ
  দিতে চাইলে নিজের keystore লাগবে (README দেখো)।

## প্রথমবার app চালিয়ে যা করবে (Gemini Login)
1. App খুলে ডানদিকের উপরে **account আইকন** → **Gemini Login** screen।
2. App-এর ভিতরের **Chromium browser**-এ নিজের **Google account দিয়ে sign in** করো
   (password শুধু Google-এর পেজেই যাবে, app দেখে না)।
3. Gemini-এর chat screen দেখা গেলে **Connect Gemini** চাপো —
   "Connected! ... তোমার ইমেইল" দেখলেই login হয়ে গেছে।
4. একাধিক Gmail থাকলে **Add Gmail** দিয়ে আরেকটা যোগ করে header-এর
   **Scan** চাপো — u/0–u/5 সব account দেখাবে, dropdown থেকে switch করা যাবে।
5. **যদি** Google "This browser or app may not be secure" দেখায়:
   Chrome-এ gemini.google.com-এ sign in করে F12 → Application → Cookies
   থেকে `__Secure-1PSID` আর `__Secure-1PSIDTS`-এর value কপি করে
   login screen-এর **"Login blocked? Paste cookie instead"** বাক্সে
   paste করে **Connect with pasted cookie** চাপো — একইভাবে কাজ করবে।
6. Generation-এর আগে **Panel Settings**-এ গিয়ে (cloud-upload আইকন):
   - R2 Worker URL + Firebase account(s) দাও (panel upload চাইলে)।
   - Cloudinary upscale-এর API key app-এর ভিতরেই দেওয়া আছে (extension-এর
     মতোই) — কিছু paste করতে হবে না, সরাসরি কাজ করবে।

## সমস্যা হলে
- **Workflow-তে installer error:** repo-তে `installer/` folder upload হয়নি।
  পুরো project আবার upload করো।
- **APK install হয় না (পুরনো version ছিল):** আগেরটা uninstall করে নতুনটা
  install করো (debug key বদলায় না, তবে অন্য source-এর একই package
  থাকলে conflict হয়)।
- **Login verify fail:** cookie expire হয়েছে — Gemini Login screen থেকে
  আবার Connect করো, অথবা paste পদ্ধতিতে নতুন cookie দাও।

## নতুন dashboard UI
App এখন modern dark dashboard: উপরে gradient header (title, account
switcher, stat chip), desktop-এ বামে navigation rail আর mobile-এ নিচে
bottom navigation — **Studio · Showcase** (কয়টা set আছে তার badge) ·
**Search · Login** (কয়টা Gmail আছে তার badge)। Set Designer
এখন পরিষ্কার card-এর ভিতরে, Generate বাটন gradient (violet → cyan),
আর screen বদলালে smooth fade-slide animation হয়। আগের সব feature
ঠিক আগের মতোই কাজ করে — শুধু look টা বদলেছে।

## নতুন feature (Image Search + Image to Prompt — integrated)
- **Image to Prompt এখন Image Search-এর ভিতরেই:** আলাদা Image to
  Prompt screen আর নেই। Set Designer-এ **Image to Prompt** বা
  **Search images** বাটন — দুটোই একই screen খোলে।
- Screen-এ app-এর Chromium browser-এ **Google Images** / **Pinterest**
  search হবে। উপরে **Mobile / Desktop** chip আছে — Mobile-ই default,
  তাই site গুলো phone-এর responsive layout দেখায়।
- পছন্দের ছবিটা বড় করে খুলে **Pick image from this page** চাপলে
  সবচেয়ে বড় ছবিগুলোর list আসবে; একটা বাছলে download হয়ে sheet
  আসবে — **Use as Reference**, **Save a copy**, আর ওই sheet-এর ভিতরেই
  **Generate prompt** (তোমার sign-in করা Gemini session ছবি দেখে
  বিস্তারিত prompt লিখে দেবে; **Use in Set Designer** চাপলেই prompt
  field-এ বসে যাবে)। Device-এ থাকা ছবির জন্য উপরে gallery বাটনও আছে।
  Pinterest-এ মাঝে মাঝে login চাইতে পারে — browser-এর ভিতরেই sign in
  করে নিলেই হবে।
- Sheet-এ **Similarity target** আছে: slider (20–90%) বা preset chip
  (Fresh 30 / Inspired 45 / Balanced 60 / Close 75 / Near copy 90) —
  যত বেশি %, নতুন ছবি reference-এর তত কাছাকাছি থাকবে। নিচে live
  দেখায় কোন কোন দিক (subject, style, lighting, palette ইত্যাদি —
  মোট 11টা) **একই থাকবে** আর কোনগুলো **বদলাবে**। Gemini-কে পাঠানো
  instruction টাই senior prompt-engineer template (9 layer analysis,
  120–200 word, `[PROMPT]` format) — **Gemini instruction** অংশ
  খুললেই পুরোটা দেখা যায়। আরও দুটো toggle: **Auto-add to Prompts
  list** (on থাকলে prompt টা field-এ replace না হয়ে নতুন line
  হিসেবে যোগ হয়) আর **Avoid repeating earlier prompts** (আগের
  prompt-এর মতো হয়ে গেলে একবার rewrite হয়)। Option গুলো save
  থাকে।

## Image to Prompt — নতুন card layout (reference design)
- Screen টা এখন তিনটা card-এ সাজানো: **Browser** card (engine naam,
  Open/Closed pill, start URL, Pinterest/Unsplash/Google Images/
  Lexica chip, **Open browser** + **Sign in** button, How it works),
  **Prompts** card (generate হওয়া prompt গুলো এখানে জমা হয় — edit/
  copy/remove করা যায়; Auto-add ON থাকলে সোজা Batch Sets-এ চলে
  যায়, OFF থাকলে **Send … prompts to Batch Sets** চাপলেই যাবে),
  **Options** card (Auto-add switch, **Gemini web cookies** dropdown
  — Auto অথবা নির্দিষ্ট account, তারপর Similarity Target panel)।
- Browser টা এখন আলাদা page: Open browser চাপলে খোলে, Back দিলে
  Prompts card-এ ফল আসে। ভিতরের সব কাজ (search, Select pictures,
  tray, Pick image) আগের মতোই।

## Multi-select gallery (Pinterest থেকে একসাথে অনেক ছবি)
- Source chip এখন চারটা: **Pinterest · Unsplash · Google Images ·
  Lexica**।
- App bar-এর **checkbox button** চাপলে selection mode on হয় — তখন
  page-এর ছবিতে tap করলে pin খুলবে না, ছবিটা select হবে (violet
  outline + "✓ Selected" badge)। নিচে tray-তে **"N selected"** —
  thumbnail, প্রতি ছবির X (remove), **Select all on page**, **Clear**।
  Page বদলালেও selection থেকে যায় ("kept while you browse")।
- Tray-র **Generate prompts** চাপলে batch sheet আসে: আগে
  **Similarity Target** ঠিক করো, তারপর সব ছবির জন্য একে একে prompt
  generate হবে (প্রতি ছবির status আলাদা, fail হলে Retry remaining)।
  Prompt edit করা যায়। শেষে **Send N prompts to Batch Sets** —
  prompt গুলো designer-এর prompt box-এ line হিসেবে বসবে আর Batch
  mode auto on হয়ে যাবে, ব্যাস batch চালালেই set generate হবে।

## Browser — Login + Search দুটোই app browser-এ (Android: Gecko, Windows: Chrome/Edge window)
- **Gemini Login (Android)** — Sign in চাপলে app-এর **built-in
  Firefox browser (GeckoView)** খোলে: Google-এর নিজের page-এ
  sign-in শেষ হলে screen নিজে নিজেই বন্ধ হয়ে যায় আর ছোট
  built-in extension টা session cookie app-কে দিয়ে দেয় —
  **automatic connect**, paste লাগে না। Profile টা app-এর ভিতরেই
  থেকে যায়, তাই **Refresh** চাপলে browser profile নিজেই session
  renew করে fresh cookie দিয়ে দেয়। (কারণসহ pattern: তুমি যে AI
  Image Studio source দিয়েছিলে, সেখান থেকে নেওয়া। Google
  Android WebView-তে sign-in block করে, Firefox engine-এ করে না;
  আর অন্য browser app-এর cookie কোনো app-ই পড়তে পারে না।)
- **Gemini Login (Windows)** — Sign in চাপলে app-এর **নিজের
  Chrome / Edge window** খোলে (আসল browser window, app-এর নিজের
  profile-এ — তোমার প্রতিদিনের Chrome না): sign-in শেষে Gemini
  খুললেই window নিজে নিজেই বন্ধ হয়ে যায় আর session cookie
  profile থেকে পড়ে **automatic connect** হয় — paste লাগে না,
  Android-এর মতোই। PC-তে Chrome/Edge/Brave যেকোনো একটা install
  থাকলেই হবে। **Session cookies** box টা manual backup হিসেবে
  দুই platform-এই আছে।
- **Image Search (Android)** — **Open browser** চাপলে একই built-in
  Firefox browser খোলে, ভিতরে **Select pictures** overlay সহ:
  ছবিতে tap করলেই select (page বদলালেও selection থাকে), dock-এর
  **Generate prompts** চাপলে prompt app-এ তৈরি হয়ে Prompts
  card-এ জমে; একটা ছবির জন্য তার **Prompt** button, video/canvas
  ছবির জন্য capture-ও আছে। Source chip চাপলে browser ওই source-এ
  navigate হয়।
- **Image Search (Windows)** — **Open browser** চাপলে একই app
  browser window (Chrome / Edge) খোলে, ভিতরে একই **selection
  overlay** সহ: ছবিতে hover করে tick করলেই select, নিচের
  dock-এর **Generate prompts** চাপলে prompt app-এ তৈরি হয়ে
  Prompts card-এ জমে; একটা ছবির জন্য তার **Prompt** button,
  video/canvas ছবির জন্য capture-ও আছে। Manual **Collect image
  links & prompts** panel (Paste link) টা backup হিসেবে আছেই।

## Build note — GeckoView (Android)
- প্রথম Android build-এ Gradle Mozilla-র Maven থেকে **GeckoView
  128** (Firefox engine, arm64) download করবে — সময় একটু বেশি
  লাগতে পারে, স্বাভাবিক।
- APK আগের চেয়ে **বড়** হবে (engine ভিতরে) আর শুধু **64-bit
  (arm64) phone**-এ চলবে; min Android version এখন **8.0 (26)**।

## Batch queue
- Set Designer-এ **Batch** on করলে নিচে **Batch queue** panel আসে —
  প্রতি line একটা job, পাশে status (waiting / running / done /
  failed) আর কয়টা শেষ হলো তার counter। একটা set fail করলে batch
  থামে না, পরেরটা চলতে থাকে; **Stop after current** চাপলে চলমান
  set টা শেষ করে বাকিগুলো বাদ যায়।

## Login — cookie paste (backup)
- Login screen-এর "Gemini web session" card-এর **Session cookies**
  box টা manual backup: Windows-এ এটাই প্রধান পথ, Android-এ Gecko
  sign-in কোনো কারণে না হলে এখানে paste করেও connect করা যায়
  (Save → Test)।

## Login save + auto cookie renew
- একবার login করলেই cookie device-এ save থেকে যায় — app বন্ধ করে
  আবার খুললেও login থাকবে, আবার sign in করতে হবে না।
- Google মাঝে মাঝে session cookie (__Secure-1PSIDTS) বদলে দেয় —
  app এখন প্রতিটা response থেকে নতুন cookie টা নিজে নিজেই save করে
  নেয় (browser যেভাবে করে)। প্লাস app খোলা থাকলে প্রতি 15 মিনিটে
  আর চালু হওয়ার সময় একবার করে সব saved account চুপচাপ renew হয়।
  মানে স্বাভাবিক ব্যবহারে login নিজে নিজেই বেঁচে থাকবে।
