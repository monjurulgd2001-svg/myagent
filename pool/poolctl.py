import os, json, subprocess, sys, time, hmac, secrets, urllib.request, urllib.error, urllib.parse

def tg_notify(text):
    # best-effort Telegram alert; never crash the panel over it
    try:
        tk = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        uid = os.environ.get("TELEGRAM_USER_ID", "")
        if tk and uid:
            urllib.request.urlopen(
                "https://api.telegram.org/bot" + tk + "/sendMessage",
                data=urllib.parse.urlencode({"chat_id": uid, "text": text}).encode(),
                timeout=10)
    except Exception:
        pass
HERMES_HOME = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
POOL = os.path.join(HERMES_HOME, "pool.json")
CFG = "/tmp/litellm.yaml"
KEY_NAMES = sorted(k for k in os.environ if k.startswith("NVIDIA_KEY_") and os.environ[k])
MISTRAL_KEY_NAMES = sorted(k for k in os.environ if k.startswith("MISTRAL_KEY_") and os.environ[k])
MISTRAL_MODELS = ["mistral-large-latest", "mistral-medium-latest",
                  "mistral-small-latest", "codestral-latest"]
BASE = "https://integrate.api.nvidia.com/v1"

def fetch_models(base, key):
    r = urllib.request.Request(base + "/models",
        headers={"Authorization": "Bearer " + os.environ[key]})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return sorted(set(m["id"] for m in json.load(resp)["data"]))

def load_pool():
    try:
        return [x for x in json.load(open(POOL)) if x.get("provider") in ("nvidia", "mistral")]
    except Exception:
        return []

def save_pool(pool):
    os.makedirs(HERMES_HOME, exist_ok=True)
    json.dump(pool, open(POOL, "w"), indent=1)

def probe(provider, mid):
    # Fire a REAL 1-token completion. Catalog presence does NOT mean
    # the model is callable on your plan (free tier can SEE premier/
    # labs models in /models but gets 4xx when calling them).
    # Returns False only on a definitive 4xx = "not usable on this
    # plan/key". 429 (busy) and 5xx/network issues fail open.
    base = BASE if provider == "nvidia" else "https://api.mistral.ai/v1"
    keys = KEY_NAMES if provider == "nvidia" else MISTRAL_KEY_NAMES
    if not keys:
        return False
    body = json.dumps({"model": mid, "max_tokens": 1,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body,
        headers={"Authorization": "Bearer " + os.environ[keys[0]],
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            r.read()
        return True
    except urllib.error.HTTPError as e:
        return e.code == 429 or e.code >= 500
    except Exception:
        return True

def prune_pool(pool):
    # Two-stage check so bad models can never poison pool-auto:
    #  1. LIVE catalog — drops retired/EOL models (HTTP 410).
    #  2. probe() — drops models your PLAN cannot actually call.
    # Fail-open: if a catalog fetch fails, stage 1 keeps entries.
    live = {}
    try:
        if KEY_NAMES:
            live["nvidia"] = set(fetch_models(BASE, KEY_NAMES[0]))
    except Exception:
        pass
    try:
        if MISTRAL_KEY_NAMES:
            live["mistral"] = set(fetch_models("https://api.mistral.ai/v1", MISTRAL_KEY_NAMES[0]))
    except Exception:
        pass
    kept, removed = [], []
    for it in pool:
        # a provider with ZERO working keys has zero deployments:
        # its pool entries are useless, drop them
        keys_for = KEY_NAMES if it["provider"] == "nvidia" else MISTRAL_KEY_NAMES
        if not keys_for:
            removed.append(it["id"])
            continue
        cat = live.get(it["provider"])
        if cat is not None and it["id"] not in cat:
            removed.append(it["id"])
            continue
        if probe(it["provider"], it["id"]):
            kept.append(it)
        else:
            removed.append(it["id"])
        time.sleep(1.1)  # respect the 1 req/sec free-tier limit
    return kept, removed

def auto_prune_loop():
    # every 30 min: drop models retired MID-RUN and hot-reload router
    while True:
        time.sleep(1800)
        try:
            kept, removed = prune_pool(load_pool())
            if removed and kept:
                save_pool(kept)
                write_config(kept)
                # the built-in pool router re-reads pool.json on
                # EVERY request - no restart needed
                print("auto-pruned dead/EOL models: " + ", ".join(removed), flush=True)
                tg_notify("🪦 Hermes: auto-pruned dead model(s) mid-run: " + ", ".join(removed) + ". Pool keeps running with the rest.")
        except Exception as e:
            print("auto-prune error: " + str(e), flush=True)

def write_config(pool):
    L = ["model_list:"]
    def dep(alias, provider, mid):
        keys = KEY_NAMES if provider == "nvidia" else MISTRAL_KEY_NAMES
        prefix = "nvidia_nim/" if provider == "nvidia" else "mistral/"
        rpm = "40" if provider == "nvidia" else "30"
        for k in keys:
            L.append('  - model_name: "%s"' % alias)
            L.append("    litellm_params:")
            L.append('      model: "%s%s"' % (prefix, mid))
            L.append("      api_key: os.environ/" + k)
            L.append("      rpm: " + rpm)
            # tokens-per-minute budget: with pre-call checks on, the
            # router SKIPS keys whose TPM quota is spent this minute
            # instead of firing a request that will 429
            L.append("      tpm: " + ("400000" if provider == "nvidia" else "500000"))
    for it in pool:
        # each selected model is callable by its own name...
        dep(it["id"], it["provider"], it["id"])
        # ...AND is a deployment of the auto-rotating "pool-auto" group:
        # every request to pool-auto round-robins across ALL selected
        # models x ALL keys automatically (no manual switching)
        dep("pool-auto", it["provider"], it["id"])
    L += ["router_settings:",
          "  routing_strategy: simple-shuffle",
          "  num_retries: 5",
          "  retry_after: 5",
          "  allowed_fails: 1",
          "  cooldown_time: 30",
          "  enable_pre_call_checks: true",
          "  timeout: 90",
          # NVIDIA NIM sometimes returns HTTP 400 for INFRA problems
          # ("DEGRADED function cannot be invoked") which is really a
          # deployment-specific outage, not a bad request. Retry
          # BadRequestError too so rotation moves to a healthy
          # model/key instead of instantly failing the user's turn.
          "  retry_policy:",
          "    BadRequestErrorRetries: 4",
          "    TimeoutErrorRetries: 5",
          "    RateLimitErrorRetries: 5",
          "    InternalServerErrorRetries: 5",
          "    ContentPolicyViolationErrorRetries: 2"]
    # NO fallbacks: the router NEVER silently swaps to a different
    # model. Rate limits are handled by rotating API keys of the
    # SAME model: 1 fail -> that key cools 30s -> next key, 5 retries.
    L += ["litellm_settings:",
          "  drop_params: true",
          "  request_timeout: 90"]
    # LiteLLM's per-worker parallel-request counter LEAKS: it counts
    # requests in but never back out (github.com/BerriAI/litellm
    # issues #27900 / #20256), so any small limit is eventually hit
    # (39 -> 272 -> 472 out of 32). Raise the ceiling so high that a
    # 5.5h run can never reach it; the watchdog restart is the
    # backstop if it somehow does.
    L += ["general_settings:",
          "  global_max_parallel_requests: 100000"]
    open(CFG, "w").write("\n".join(L) + "\n")

if __name__ == "__main__":
    if "--watch" in sys.argv:
        auto_prune_loop()      # forever: drop models retired mid-run
        sys.exit(0)
    # default / --init: prune the website pool and rebuild the
    # LiteLLM config. No server, no token, no panel.
    pool, removed = prune_pool(load_pool())
    if removed:
        save_pool(pool)
        print("pruned dead/EOL models: " + ", ".join(removed))
    write_config(pool)
    sys.exit(0)
