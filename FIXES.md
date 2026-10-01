# Fixes — model pool pruning + Telegram spam (2026-08-31)

## Problem
`🪦 Hermes: auto-pruned dead model(s) mid-run: nvidia/nemotron-3-ultra-550b-a55b, mistral-large-latest`
kept arriving on Telegram over and over.

### Root cause (loop)
1. The config website keeps the dead models ticked in the Firebase vault (`MODEL_POOL`).
2. `scripts/fbpool.py` re-syncs the vault → `pool.json` **every 60s**, re-adding the models the pruner just removed.
3. `pool/poolctl.py --watch` prunes them again **every 30 min** → sends the exact same Telegram message. Forever.

### Second bug: false pruning of LIVE models
`probe()` fired a `max_tokens: 1` test call and treated **any** HTTP 4xx as "dead".
Reasoning models (e.g. `nvidia/nemotron-3-ultra-550b-a55b`, `mistral-large-latest` → Mistral Large 3)
can reject such a request with HTTP 400 for request-shape reasons even though they work fine —
so perfectly healthy models could be pruned.

## Changes

### `pool/poolctl.py`
- **Smarter probe**: `max_tokens` 1 → 16; the error body is parsed. A model is dead only on a
  definitive model-level error (401/402/403/404, or 400/422 whose message names the model —
  unknown / retired / not entitled). Request-shape 400s, 429 and 5xx fail OPEN (model stays).
  The prune reason is recorded and shown in the alert.
- **Graveyard (bench)**: pruned models are written to `~/.hermes/graveyard.json` with timestamp +
  reason. Benched models are skipped by `load_pool()` and by both vault-sync scripts, so they can
  no longer bounce back in. A grave expires after `GRAVEYARD_TTL_H` (default 24h) → automatic retry.
- **Smart Telegram alerts**: one digest message per NEW death (model + reason + what happens next).
  Per-model dedupe state in `~/.hermes/prune_notified.json` with `PRUNE_NOTIFY_COOLDOWN_H`
  (default 24h) — the same dead model is never announced twice within the cooldown. `tg_notify()`
  also supports `silent=True` (Telegram `disable_notification`).
- Updated the `MISTRAL_MODELS` reference list to the current 2026 aliases
  (adds `magistral-medium-latest`, `magistral-small-latest`).

### `scripts/fbpool.py` + `scripts/model_pool_init.py`
- Both now apply the graveyard filter when taking `MODEL_POOL` from the website vault:
  - benched + fresh → kept out silently (no re-prune, no re-alert)
  - grave older than TTL → allowed back for one retry
  - **pool re-applied on the website after the burial** (`MODEL_POOL_UPDATED` newer than the
    grave) → un-buried immediately: pressing *Apply pool* on the panel is always respected.

### `scripts/firebase_vault.py`
- Forwards `MODEL_POOL_UPDATED` from the vault so the startup init can honour the re-apply rule.

## New env knobs (optional)
- `GRAVEYARD_TTL_H` — hours a pruned model stays benched before auto-retry (default 24)
- `PRUNE_NOTIFY_COOLDOWN_H` — hours before the same dead model may be announced again (default 24)

## Behaviour now
- A model dies mid-run → **one** Telegram digest with the reason, then silence about it.
- The pool keeps running with the healthy models; benched ones auto-retry after the TTL.
- To retry sooner or swap models: config website → Model pool → *Apply pool*.
- No workflow (`hermes.yml`) or panel changes required — everything is backward compatible.

## Web→API (custom) provider — use any OpenAI-compatible bridge like a normal model

- **New provider `custom`** across the whole stack (router, poolctl, fbpool, model_pool_init, vault, panel). Any OpenAI-compatible endpoint — e.g. the ChatGPT browser bridge behind a Cloudflare quick tunnel — joins the pool exactly like an NVIDIA/Mistral model.
- **Live URL pickup**: tunnel URLs change every bridge run, so `pool_router.py` re-reads `CUSTOM_API_BASE` / `CUSTOM_API_KEY` from `~/.hermes/.env` (mtime-cached) on every request. vault_sync mirrors the vault there within ~45s → a new bridge URL goes live mid-run with NO restart.
- **Streaming shim**: web bridges answer plain JSON; when the client asked for SSE, the router converts the JSON completion into a minimal OpenAI SSE stream (`_sse_from_json`), so Hermes streaming works unchanged.
- **Sane scheduling**: `CUSTOM_PREFER` (default 3.0) keeps slow browser bridges as fallback in pool-auto (set <1 to prefer). `CUSTOM_TIMEOUT` (default 300s) replaces the first-token gate for custom models.
- **Never falsely pruned**: probe/prune skip `custom` entries entirely — a bridge being down just means the router skips it for that request.
- **New workflow `.github/workflows/chatgpt-api.yml`**: runs the ChatGPT web→API bridge and AUTO-CONNECTS it: publishes `$TUNNEL_URL/v1` to the Firebase vault as `CUSTOM_API_BASE`, adds `{"id":"chatgpt","provider":"custom"}` to `MODEL_POOL` if missing (without bumping `MODEL_POOL_UPDATED`, so graves stay), sets `CUSTOM_MODELS=chatgpt` if empty, and sends a Telegram heads-up. Needs the same `FIREBASE_*` secrets as hermes.yml (+ optional `TELEGRAM_*`). Manual dispatch only — the push trigger was removed so it doesn't start on every commit.
- **Panel**: new "Web-API models / base URL / key" fields in Model pool; custom models appear in the catalog, can be ticked into the pool, and "Test" calls the bridge directly from the browser (bridges send their own CORS headers).

### Vision (image) support on the web→API bridge

- The ChatGPT **website** understands images natively, so the bridge now accepts the standard **OpenAI vision format**: `messages[].content` parts with `{ "type": "image_url", "image_url": { "url": ... } }` — both `data:image/...;base64,...` URLs and plain `http(s)` image links (downloaded server-side, redirects followed).
- Images are saved to temp files and **attached to the ChatGPT composer** exactly like a human upload (`input[type=file]`), the bridge waits until the upload finishes (send button re-enabled, up to 60s), sends the prompt, returns the reply, then deletes the temp files.
- Up to **4 images per request** (ChatGPT-safe cap). Text-only requests behave exactly as before; an image-only request gets a default "Describe the attached image(s)." prompt.
- No router change needed — vision payloads pass through the `custom` provider untouched, so `chatgpt` in the pool is now effectively a **vision model** to every client.

### Fix: local bridge endpoint was wiped by the .env rewrite (502 'custom web-API URL not configured')

- **Problem**: the local bridge step wrote `CUSTOM_API_BASE_LOCAL` into
  `~/.hermes/.env`, but the NEXT step ('Write .env') rebuilds that file from
  scratch with `cat > .env` - the line was deleted before the gateway ever
  started, so the router answered 502 for every chatgpt request.
- **Fix**: the bridge step now also drops `/tmp/chatgpt_bridge_local`, and
  the 'Write .env' step re-appends that line right after the rewrite
  (logs `CUSTOM_API_BASE_LOCAL re-applied after .env rewrite`).

### Fix: requests during ChatGPT login no longer fail (503 -> event-driven wait)

- **Problem**: while the browser was still logging in (first 1-5 minutes of a
  run), every chatgpt request got `503 ChatGPT browser is still initializing`,
  so the gateway burned all its retries and the user saw errors.
- **Fix**: matched the behavior of the proven `chatgpt-login.js` - every wait
  is event-driven. Requests that arrive during login are now HELD until the
  composer is ready, then answered normally. If login itself fails, held
  requests are rejected with the real error. Applied to both
  `bridge/chatgpt_server.js` (local mode) and `chatgpt-api.yml` (remote mode).

### Fix: ChatGPT was detecting the bridge browser as a bot at login

- **Problem**: the bridge launched Chrome with a fixed 1280x800 viewport and
  extra flags (`--no-sandbox`, `--disable-setuid-sandbox`,
  `--disable-dev-shm-usage`). Those are classic automation fingerprints, so
  the ChatGPT login flow flagged the browser and login kept failing.
- **Fix**: switched to the EXACT launch method of the proven
  `chatgpt-login.js`: real Chrome channel, persistent profile,
  `viewport: null` (real window size) and NO custom flags - the clean launch
  Patchright needs to stay undetected. Applied to both
  `bridge/chatgpt_server.js` (local mode) and `chatgpt-api.yml` (remote mode).

### ChatGPT bridge now uses Camoufox (the anti-detect browser already in the repo)

- **Problem**: even a clean Patchright Chrome launch was getting stuck at the
  ChatGPT login on GitHub runners (datacenter IP + Chrome automation checks) -
  the run log showed login never reaching the OTP page.
- **Fix**: the bridge now connects to the Camoufox server that this repo
  already starts for the built-in browser tools (ws://127.0.0.1:9222/hermes).
  Camoufox spoofs fingerprints at the C++ level, so ChatGPT cannot detect
  automation at all. Patchright Chrome remains only as a fallback when
  Camoufox is unreachable (e.g. the optional remote workflow).
- Also added while debugging: the OTP wait is no longer blind - every 15s the
  run log prints the current URL + page text (plus a /tmp screenshot), and a
  Cloudflare 'Verify you are human' checkbox is clicked automatically.

### Fix: login stalled on the PASSWORD page + Camoufox connect race

- **Problem 1**: the account has a password, so after the email step
  auth.openai.com shows the *password* page - not the OTP page. The bridge
  sat waiting for a code input that never appeared.
- **Fix 1**: the wait loop now detects the password page and clicks
  "Log in with a one-time code"
  (button[name="intent"][value="passwordless_login_send_otp"] - exact
  selector from the live page HTML) to force the OTP flow, then continues
  with the normal IMAP OTP pickup.
- **Problem 2**: the bridge tried Camoufox once, got ECONNREFUSED (server
  still booting or failed) and instantly fell back to Chrome.
- **Fix 2**: the bridge now retries the Camoufox connect for up to 2
  minutes before falling back, and /tmp/camoufox.log is streamed into the
  run log so a failed Camoufox startup is visible.

---

# Fix — every run died with "Hermes install is broken" (2026-09-27)

## Problem
Every `Hermes Agent` run failed at step 2 (*Install Hermes Agent*) with:

```
Error: Hermes install is broken (venv python missing or launcher fails). Failing fast so the chain does not spam failed runs.
Error: Process completed with exit code 1.
```

…even though the same log showed the install had **succeeded**:

```
✓ Install complete! [main @ 9bb2ea1b5]
✓ app products and hermes command ready
✓ Hermes Agent install complete. Run: hermes
```

and `hermes update` had run fine (`✓ Already up to date! [main @ 9bb2ea1b5]`), which proves the
launcher was never broken.

### Root cause
The workflow hard-coded the old environment path `$HERMES_HOME/hermes-agent/venv/bin/python`.
The current installer does not create it anymore — `install.sh` only bootstraps a tool Python
("*Keep the installer stage protocol; PM alone creates dependency environments*") and PM puts the
real environment under:

```
/home/runner/.hermes/installs/<hash>/environments/<hash>/{bin/python,workspace}
```

So every `-x .../hermes-agent/venv/bin/python` test was permanently false, which caused a cascade:

1. the "launcher + venv present → skip install" branch could never trigger → a full reinstall on every run;
2. the sanity check declared "Hermes launcher broken" → a **second** clean reinstall (visible twice
   in the log);
3. the next identical check failed again → `::error::` + `exit 1`;
4. the `edge-tts` upgrade and the **python-telegram-bot preflight** were guarded by the same dead
   path, so they silently never ran (the source of `NoAudioReceived` and
   "Any cannot be instantiated" / Telegram offline).

## Changes

### `scripts/hermes_venv.sh` (new)
- `resolve_hermes_py` — finds the Hermes application interpreter in **both** layouts: the legacy
  `hermes-agent/venv` (old caches) first, otherwise the newest
  `~/.hermes/installs/*/environments/*/bin/python`, preferring the environment that actually owns
  the app (has a `workspace` sibling or real app deps in `site-packages`) over PM's tiny bootstrap
  environment.
- `export_hermes_py` — exports `HERMES_VENV_PY` and persists it to `$GITHUB_ENV` for later steps.
- `hermes_py_install` — installs into that environment with the pip → `uv pip` → `ensurepip` →
  `get-pip.py` ladder (uv-built envs ship without pip).

### `.github/workflows/hermes.yml`
- Step 2 sources the resolver; skip/sanity/fail-fast checks now test **`hermes --help` + the agent
  code tree** (`run_agent.py`) instead of a guessed venv path.
- The deep `import model_tools` check uses `$HERMES_VENV_PY`, is re-resolved after a reinstall, and
  warns instead of failing the run when no interpreter path can be found.
- `edge-tts` upgrade and the Telegram dependency preflight use `$HERMES_VENV_PY` /
  `hermes_py_install`, so they actually run again.

Nothing else in the workflow (steps, order, secrets, state backup/restore) was changed.

---

# Change — Mistral support removed completely (2026-09-27)

Mistral is no longer a provider anywhere in this repo. The pool is now **NVIDIA + custom
(web→API bridge)** only.

### `.github/workflows/hermes.yml`
- Workflow name: "… NVIDIA/Mistral Pool" → "… NVIDIA Pool"; the ONLINE Telegram message says
  "NVIDIA pool".
- Removed `GH_MISTRAL_KEYS` from the Firebase-vault step (the `MISTRAL_KEYS` GitHub secret is no
  longer read at all).
- Removed the parallel Mistral key auth-check loop, its result collection (`MISTRAL_KEY_*` in
  `/tmp/litellm.env`) and the "Mistral key(s) dead" Telegram alert. NVIDIA key checking is
  unchanged.

### `pool/pool_router.py`
- `BASES`, `KEYS` and `RR` no longer contain `mistral`; `MISTRAL_KEY_*` env vars are ignored.
- Removed the Mistral latency seed, the `MISTRAL_PREFER` routing preference (only `CUSTOM_PREFER`
  remains) and the Mistral-specific `reasoning_effort` workaround.
- An unknown model name now resolves to the NVIDIA endpoint instead of being guessed as Mistral.

### `pool/poolctl.py`
- Removed `MISTRAL_KEY_NAMES` and the `MISTRAL_MODELS` catalog.
- `probe()`, `prune_pool()` and `write_config()` are NVIDIA-only (`nvidia_nim/` prefix, rpm 40,
  tpm 400000); the Mistral catalog fetch is gone.
- `load_pool()` accepts only providers `nvidia` and `custom`.

### `scripts/firebase_vault.py`, `scripts/fbpool.py`, `scripts/model_pool_init.py`
- `MISTRAL_KEYS` removed from the vault key list and the secret-masking set.
- The pool provider allowlist is `("nvidia", "custom")`, so any Mistral entry still ticked in the
  config website's `MODEL_POOL` is silently dropped instead of entering `pool.json`.

Nothing else was touched: NVIDIA rotation, the custom web-API bridge, graveyard/prune logic,
Telegram/Slack, Zedge and every other step work exactly as before.

### Fix: ChatGPT web→API model could only CHAT - no terminal / files / browser / vision tools (2026-09-27)

- **Problem**: Hermes sends its tools (`terminal`, `files`, `browser_*`, `web`, `vision`, `code`, `memory`, `skills`, `delegation`, `cron` ...) in the OpenAI `tools` field and expects `tool_calls` back. The bridge **ignored `tools` completely** and always answered plain text, and the pool router's JSON→SSE shim only forwarded `content`. Result: with `chatgpt` selected the agent could talk but never execute anything on the PC.
- **Fix - bridge (`bridge/chatgpt_server.js` + the inline copy in `chatgpt-api.yml`, kept identical)**:
  - Reads `tools` / legacy `functions` + `tool_choice`. When tools are present a compact **tool manual** (`### SYSTEM (TOOLS)`: names, descriptions, parameters, strict call protocol) is injected as the first SYSTEM block.
  - ChatGPT replies with `<tool_call>{"name":..., "arguments":{...}}</tool_call>` lines; the bridge parses them (string-aware JSON scanner, also tolerates code fences, unclosed tags, bare JSON objects naming a known tool, case-insensitive tool names) and returns **real OpenAI `tool_calls`** with `finish_reason: "tool_calls"`.
  - Previous assistant tool calls are replayed in the same `<tool_call>` format and tool results get their tool name from `tool_call_id`, so ChatGPT sees a consistent agent loop.
  - Delta cache stays working in tool loops (the stored assistant block matches what Hermes echoes back); delta sends add a short tool reminder.
  - `tool_choice: "none"` disables the manual; `"required"` / a named function forces a call.
  - Vision: images from **tool results** (screenshots) are attached too, and only NEW images (after the last assistant turn, newest 4) are uploaded - old images are no longer re-attached every turn.
- **Fix - router (`pool/pool_router.py`)**: `_sse_keepalive_fetch` and `_sse_from_json` now forward `tool_calls` as proper streaming deltas (`index/id/type/function`) and end with `finish_reason: "tool_calls"`. Logs `pool-router: custom -> tool_calls: <names>`.
- Knobs: `TOOL_DESC_MAX` (default 400) and `TOOL_PARAM_DESC_MAX` (default 160) clip tool/parameter descriptions to keep the manual small.

### Fix: install fails with `Failed to query Python interpreter ... tools/python-3.14.x/bin/python3 ... Permission denied (os error 13)`

- **Cause**: `system/statesave.sh` backed up ALL of `~/.hermes` (only `hermes-agent/` excluded) - including the installer's bundled Python (`~/.hermes/tools/`) and PM environments (`~/.hermes/installs/`). These are binaries, not user state. Coming back from the git `state` branch they lose the exec bit (files >90MB are split into `.gh-chunk.*` and re-joined with `cat` -> mode 644). The installer sees the existing `tools/python-3.14.x`, reuses it, and `uv venv` cannot execute it -> `pm install failed`.
- **Fix**:
  - `statesave.sh`: excludes `/tools`, `/installs`, `/.hermes-clone-*` from the state backup.
  - `hermes.yml` restore: never copies those dirs back (also cleans them out of an old state branch).
  - `hermes.yml` install: if the bundled Python can't run it is deleted before install; if the installer still fails it wipes `tools/ installs/ hermes-agent/` and retries once clean.

### Feature: two-way AUTO-FAILOVER between ChatGPT web-API and the NVIDIA pool (`pool/pool_router.py`)

- **ChatGPT web fails -> NVIDIA instantly.** Triggers: bridge offline (connection refused), still logging in (`/health` = `initializing`, checked first with a 3s timeout, cached 5s), HTTP error, empty answer, or a ChatGPT website error / rate-limit notice ("You've reached our limit", "Something went wrong", ...).
  - Fails fast (within `CUSTOM_FASTFAIL_WINDOW`, default 4s) -> the router moves to the next model before sending anything.
  - Fails later (after the stream started) -> the answer is fetched from the NVIDIA pool **inside the same open stream**, so Hermes still gets a normal reply (tool calls included).
- **All NVIDIA models / keys fail -> ChatGPT web.** ChatGPT is always the last safety net. If it is not in the pool but a bridge URL is configured, it is added automatically as the final fallback. It is allowed to run even after the NVIDIA time budget is spent (streamed with heartbeats).
- Works for `pool-auto` and for a model you picked yourself (`/model chatgpt` or `/model <nvidia-id>`): the picked model is tried first and the rest of the pool follows. A picked model that just failed is cooled down (5 min) and put behind the fallbacks, so the next requests switch instantly too.
- Cooled-down models are kept at the END of `pool-auto` as a last resort, no longer dropped.
- Log lines: `pool-router: failover -> <provider> <model> (reason)`, `custom ... failed fast`, `in-stream failover answered by ...`.
- Knobs: `AUTO_FAILOVER=0` (old strict behaviour), `CUSTOM_FASTFAIL_WINDOW`, `CUSTOM_HEALTH_TIMEOUT`, `CUSTOM_HEALTH_TTL`.
