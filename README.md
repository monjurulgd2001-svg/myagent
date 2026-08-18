# Hermes Agent — Repo Layout

আগে পুরো এজেন্ট এক বিশাল `hermes.yml` (~9,700 লাইন) এ inline heredoc হিসেবে ছিল।
এখন প্রতিটা inbuilt feature-এর কোড/ফাইল আলাদা করে repo-তে রাখা হয়েছে, আর workflow
শুধু orchestrate করে (checkout → copy/run)।

## Structure

```
.github/workflows/hermes.yml   ← Action workflow (only orchestration, no embedded code)
scripts/                       ← Workflow helper scripts
  firebase_vault.py            ← Firebase secret-vault loader (step 0)
  fbpub.py, fbpool.py          ← Facebook publish/pool helpers
  camofox_keepalive.py         ← Camoufox keepalive
  model_pool_init.py           ← Model pool bootstrap
  model_alias.py               ← Model alias setup
  session_restore.py           ← Session priming/restore
skills/                        ← Hermes skills (each feature in its own folder)
  ringtone-generator/          ← SKILL.md + ringtone_generator.js
  hermesa-phone/               ← SKILL.md + scripts/hermesa_bot.py
  zedge-automation/            ← SKILL.md + scripts/zedge_tool.py + zedge_bot.py.b64
  telegram-group-manager/      ← SKILL.md + scripts/tg_group.py
  facebook-page-manager/       ← SKILL.md + scripts/fb_page.py
bin/                           ← CLI shims installed to ~/.local/bin (+ pdf2md)
  hermesa, zedge, tg, fb, mailshim, skill, pdf2md
pool/                          ← NVIDIA/Mistral model pool
  poolctl.py, pool_router.py
email/email_tool.py            ← Gmail/email tool
agents/                        ← Agent instructions
  AGENTS.md, MEMORY.md (appended)
jarvis/                        ← Dashboard/HUD
  index.html, app.py
system/                        ← Runner lifecycle scripts
  statesave.sh, sync.sh, sweeper.sh, watchdog.sh
config/searxng-settings.yml    ← SearXNG config
```

## কীভাবে কাজ করে

1. Workflow-এর প্রথম step `actions/checkout@v4` — পুরো repo `$GITHUB_WORKSPACE`-এ আসে।
2. আগের প্রতিটা `cat > file <<'HEREDOC'` ব্লক এখন এক লাইনের
   `cp "$GITHUB_WORKSPACE/<path>" <target>` — runtime behavior হুবহু আগের মতোই।
3. Inline `python3 - <<'X'` স্ক্রিপ্টগুলো এখন `python3 "$GITHUB_WORKSPACE/scripts/<name>.py"`।
4. `chmod +x`, secrets, env, cache — সবকিছু আগের মতোই workflow-এ আছে।

## Notes

- **Runtime-expansion heredoc গুলো inline-ই আছে** (`.env`, desktop/fluxbox/tint2 config,
  status.sh): এগুলোতে `$VAR` runtime-এ expand হয়, তাই ফাইলে আলাদা করা যায় না।
- `zedge_bot.py.b64` base64 রাখা হয়েছে (decoded content plain UTF-8 text না) —
  workflow আগের মতোই এটা `/tmp/zedge_bot.b64`-এ কপি করে decode করে।
- কোনো feature edit করতে চাইলে এখন শুধু সেই feature-এর ফাইল edit করে push করলেই হবে —
  workflow yml-এ হাত দিতে হবে না।
