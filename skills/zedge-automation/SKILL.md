---
name: zedge-automation
description: >-
  Manage and run the user's Zedge wallpaper & ringtone publishing pipeline
  (3 instances) fully on this machine. Queue wallpapers (auto-resized to
  1620x2880 JPG) and MP3 ringtones, edit title/tags/category/description,
  requeue or delete items, check daily upload state (3 uploads/day,
  alternating WALLPAPER/AUDIO days) and run the inbuilt Playwright upload
  bot locally to publish to zedge.net - no external repo or token needed.
---

# Zedge Automation Skill

The user runs 3 independent Zedge upload pipelines ("Zedge 1/2/3"). Each
instance has its own Firebase Realtime DB queue and its own Zedge account.
The INBUILT upload bot (scripts/zedge_bot.js - Playwright chromium with
anti-fingerprint hardening, consent-popup handling, publish verification
and Telegram notifications) runs LOCALLY on this machine via `zedge run`.

## How the pipeline works (A to Z)

1. Files live in Cloudflare R2 via the gateway worker (ZEDGE_R2_WORKER_URL -
   ONE worker shared by all accounts; files separated by zedgeN/ prefix):
   POST body = raw file bytes, headers X-File-Name: zedge<N>/<ts>_<name>,
   X-File-Type: <mime>. Response JSON contains the public `url`.
   DELETE with X-File-Name removes a stored file.
2. A queue entry is pushed to <DB_URL>/wallpaperQueue.json:
   name, type, size, isMp3, fileUrl, title, tags, category, description,
   status "queued", createdAt server timestamp.
3. `zedge run` starts the LOCAL bot: it picks the OLDEST queued item
   matching today's type, sets status "processing", logs into zedge.net,
   uploads, fills the meta dialog (title / tags / category / description),
   publishes, then deletes the queue entry AND the R2 file. Failures set
   status "failed" + error text. The bot sends Telegram notifications
   itself.
4. State lives at <DB_URL>/uploadState.json:
   - uploadDayType: "AUDIO" (mp3 ringtone day) or "WALLPAPER" (image day),
     alternates automatically every new day (Asia/Dhaka time)
   - totalUploadsToday: hard max 3/day per instance (Zedge limit)
   - profileUploadCounts + lastUsedProfileIndex: browser-profile rotation

## Commands (`zedge` terminal command)

    zedge status [--all | -i N]      # day type, uploads left, queue counts
    zedge queue -i N [--filter queued|processing|failed|all]
    zedge add <file-or-url> -i N [--title T] [--tags "a,b,c"]
              [--category CAT] [--description D]     # jpg/png/webp or mp3
    zedge distribute <files...>      # images round-robin across 1->2->3
    zedge edit <id> -i N [--title ...] [--tags ...] [--category ...] [--description ...]
    zedge requeue <id> -i N          # failed/stuck -> queued again
    zedge delete <id> -i N           # removes queue entry + R2 file
    zedge run [-i N | --all] [--bg] [--no-vpn] [--profiles 3] [--ua random]
              [--headless true] [--proxy-server URL --proxy-user U --proxy-pass P]
    zedge vpn up|down|status -i N    # browser-only WireGuard (netns)
    zedge runs -i N [--limit 3] [--tail 25]   # local run logs / progress

## Rules for the agent

1. ALWAYS run `zedge status` first: it shows today's type (AUDIO vs
   WALLPAPER) and how many of the 3 daily uploads remain. An mp3 queued on
   a WALLPAPER day simply waits for the next AUDIO day - tell the user.
2. Wallpapers: jpg/png/webp accepted, auto-converted to 1620x2880 JPG
   (cover crop). Ringtones: mp3 only.
3. Always set a good title, 5-10 comma-separated tags and a category when
   adding. If the user gave no metadata, write sensible metadata yourself
   from the filename/content and say so.
4. `zedge run` runs the bot ON THIS MACHINE. It only needs the instance's
   line in ZEDGE_ACCOUNTS ("email : password"). NO GitHub repo or token.
   If the login line is missing the tool names it exactly - tell the user
   to fill it in the config panel (Zedge section). Never ask otherwise.
5. A run takes ~5-15 minutes; the very first run also installs chromium
   (~2 min extra). Prefer `zedge run -i N --bg`, then poll
   `zedge runs -i N` and report PUBLISHED / IN REVIEW / REJECTED / failed
   honestly.
6. Files the user sends in chat land in ~/.hermes/work/inbox/ - `zedge add`
   directly from there.
7. PROXY - ONE PER ACCOUNT: ZEDGE_PROXIES in the config panel; line N
   is the proxy for instance N (matching ZEDGE_ACCOUNTS line N).
   Line formats: host:port | scheme://user:pass@host:port |
   host:port|user|pass. Empty line or "-" = direct for that one.
   NEVER run multiple accounts through the same proxy or the same
   IP - Zedge can link and suspend them; the tool prints a WARNING
   if proxies repeat. --proxy-server/--proxy-user/--proxy-pass
   override for a single run. The bot verifies the proxy BEFORE
   uploading and aborts if it is dead - it never silently falls
   back to a direct connection (no IP leak).
8. VPN - BROWSER-ONLY (WireGuard): paste each account's WireGuard
   .conf into ZEDGE_WG_1/2/3 (no username/password needed - the
   keys live inside the .conf). `zedge run` then
   starts that instance's VPN inside an ISOLATED Linux network
   namespace: ONLY the bot's browser traffic goes through the
   tunnel - Hermes itself and everything else stays on the normal
   connection. The exit IP is printed and verified before any
   upload; if the tunnel fails the run ABORTS (no direct fallback,
   no IP leak). When both a WireGuard conf and a proxy line exist, the VPN
   wins; --no-vpn skips it; --proxy-server overrides everything.
   Manage manually: zedge vpn up|down|status -i N.
