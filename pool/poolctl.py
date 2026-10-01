import os, json, subprocess, sys, time, hmac, secrets, urllib.request, urllib.error, urllib.parse

HERMES_HOME = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
POOL = os.path.join(HERMES_HOME, "pool.json")
# ── graveyard: models pruned mid-run are BENCHED here, so the 60s
# website->runner sync can't resurrect them and the pruner can't
# announce the same corpse on Telegram every 30 minutes. A grave
# expires after GRAVEYARD_TTL_H (default 24h) => the model gets one
# fresh chance; re-applying the pool on the website un-buries it
# immediately (handled in fbpool.py / model_pool_init.py).
GRAVEYARD = os.path.join(HERMES_HOME, "graveyard.json")
NOTIFIED = os.path.join(HERMES_HOME, "prune_notified.json")
GRAVE_TTL = float(os.environ.get("GRAVEYARD_TTL_H", "24")) * 3600
NOTIFY_COOLDOWN = float(os.environ.get("PRUNE_NOTIFY_COOLDOWN_H", "24")) * 3600
CFG = "/tmp/litellm.yaml"
KEY_NAMES = sorted(k for k in os.environ if k.startswith("NVIDIA_KEY_") and os.environ[k])
BASE = "https://integrate.api.nvidia.com/v1"


def _load_json(path, default):
    try:
        v = json.load(open(path))
        return v if isinstance(v, type(default)) else default
    except Exception:
        return default


def _save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(obj, open(path, "w"), indent=1)


def tg_notify(text, silent=False):
    # best-effort Telegram alert; never crash the panel over it
    try:
        tk = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        uid = os.environ.get("TELEGRAM_USER_ID", "")
        if tk and uid:
            payload = {"chat_id": uid, "text": text}
            if silent:
                payload["disable_notification"] = "true"
            urllib.request.urlopen(
                "https://api.telegram.org/bot" + tk + "/sendMessage",
                data=urllib.parse.urlencode(payload).encode(),
                timeout=10)
    except Exception:
        pass


def bury(removed):
    """Record pruned models so they stay benched (removed = [{id, provider, reason}])."""
    g = _load_json(GRAVEYARD, {})
    now = time.time()
    for r in removed:
        g[r["provider"] + "::" + r["id"]] = {"ts": now, "reason": r["reason"]}
    _save_json(GRAVEYARD, g)


def notify_pruned(removed, kept_count):
    """Smart Telegram digest: one message per NEW death, never repeats
    the same model within NOTIFY_COOLDOWN. Kills the every-30-min spam."""
    state = _load_json(NOTIFIED, {})
    now = time.time()
    fresh = [r for r in removed
             if now - float(state.get(r["provider"] + "::" + r["id"], 0)) >= NOTIFY_COOLDOWN]
    if not fresh:
        print("prune: all removed models were already announced - staying quiet", flush=True)
        return
    for r in fresh:
        state[r["provider"] + "::" + r["id"]] = now
    _save_json(NOTIFIED, state)
    lines = ["🪦 Hermes: benched %d dead model(s):" % len(fresh)]
    for r in fresh:
        lines.append("• %s — %s" % (r["id"], r["reason"]))
    lines.append("")
    lines.append("Pool keeps running with %d model(s). Benched models are "
                 "retried automatically in %dh — no more alerts about them "
                 "until then. To retry sooner (or swap them out), press "
                 "Apply pool on the config website."
                 % (kept_count, int(GRAVE_TTL // 3600)))
    tg_notify("\n".join(lines))


def fetch_models(base, key):
    r = urllib.request.Request(base + "/models",
        headers={"Authorization": "Bearer " + os.environ[key]})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return sorted(set(m["id"] for m in json.load(resp)["data"]))


def load_pool(include_buried=False):
    try:
        pool = [x for x in json.load(open(POOL)) if x.get("provider") in ("nvidia", "custom")]
    except Exception:
        return []
    if include_buried:
        return pool
    g = _load_json(GRAVEYARD, {})
    now = time.time()
    out = []
    for x in pool:
        e = g.get(x["provider"] + "::" + x["id"])
        if e and now - float(e.get("ts", 0)) < GRAVE_TTL:
            continue        # still benched - skip silently
        out.append(x)
    return out


def save_pool(pool):
    os.makedirs(HERMES_HOME, exist_ok=True)
    json.dump(pool, open(POOL, "w"), indent=1)


# error-body fragments that PROVE the model itself is unusable
# (vs. a merely malformed request, which must NOT kill the model)
_DEAD_HINTS = ("model_not_found", "unknown model", "invalid model",
               "does not exist", "not found", "decommission", "retired",
               "no longer", "not available", "not supported on",
               "no access", "not entitled", "accept the terms")


def probe(provider, mid):
    """Fire a REAL small completion. Catalog presence does NOT mean the
    model is callable on your plan (free tier can SEE premier/labs models
    in /models but gets 4xx when calling them).

    Returns (alive, reason). Dead ONLY on a definitive model-level 4xx:
      401/402/403/404          -> key/plan cannot use this model
      400/422 naming the MODEL -> unknown/retired/not entitled
    A 400 caused by request shape (e.g. reasoning models that reject
    tiny max_tokens) keeps the model ALIVE - this used to false-prune
    live models like nemotron-3-ultra.
    429 (busy), 5xx and network issues fail open."""
    if provider == "custom":
        # web→API bridges (browser ChatGPT behind a Cloudflare tunnel)
        # restart often and their URL churns - NEVER bench them from a
        # probe. If the bridge is down the router simply skips it.
        return True, ""
    base = BASE
    keys = KEY_NAMES
    if not keys:
        return False, "no %s API keys configured" % provider
    body = json.dumps({"model": mid, "max_tokens": 16,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body,
        headers={"Authorization": "Bearer " + os.environ[keys[0]],
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            r.read()
        return True, ""
    except urllib.error.HTTPError as e:
        if e.code == 429 or e.code >= 500:
            return True, ""
        msg = ""
        try:
            raw = e.read().decode("utf-8", "replace")
            try:
                j = json.loads(raw)
                msg = str((j.get("error") or {}).get("message") or
                          j.get("message") or j.get("detail") or raw)
            except Exception:
                msg = raw
        except Exception:
            pass
        msg = " ".join(msg.split())[:160]
        if e.code in (401, 402, 403, 404):
            return False, "HTTP %d - not callable on this key/plan%s" % (
                e.code, (": " + msg) if msg else "")
        if e.code in (400, 422):
            low = msg.lower()
            if any(h in low for h in _DEAD_HINTS):
                return False, "HTTP %d - %s" % (e.code, msg or "model rejected")
            # request-shape complaint, not a dead model -> fail open
            return True, ""
        return True, ""
    except Exception:
        return True, ""


def prune_pool(pool):
    # Two-stage check so bad models can never poison pool-auto:
    #  1. LIVE catalog — drops retired/EOL models (HTTP 410).
    #  2. probe() — drops models your PLAN cannot actually call.
    # Fail-open: if a catalog fetch fails, stage 1 keeps entries.
    # Returns (kept, removed) where removed = [{id, provider, reason}].
    live = {}
    try:
        if KEY_NAMES:
            live["nvidia"] = set(fetch_models(BASE, KEY_NAMES[0]))
    except Exception:
        pass
    kept, removed = [], []
    for it in pool:
        # a provider with ZERO working keys has zero deployments:
        # its pool entries are useless, drop them
        if it["provider"] == "custom":
            kept.append(it)   # web-API entries are never pruned here
            continue
        keys_for = KEY_NAMES
        if not keys_for:
            removed.append({"id": it["id"], "provider": it["provider"],
                            "reason": "no %s API keys configured" % it["provider"]})
            continue
        cat = live.get(it["provider"])
        if cat is not None and it["id"] not in cat:
            removed.append({"id": it["id"], "provider": it["provider"],
                            "reason": "gone from the provider catalog (retired/EOL)"})
            continue
        alive, reason = probe(it["provider"], it["id"])
        if alive:
            kept.append(it)
        else:
            removed.append({"id": it["id"], "provider": it["provider"], "reason": reason})
        time.sleep(1.1)  # respect the 1 req/sec free-tier limit
    return kept, removed


def auto_prune_loop():
    # every 30 min: drop models retired MID-RUN and hot-reload router
    while True:
        time.sleep(1800)
        try:
            kept, removed = prune_pool(load_pool())
            if not removed:
                continue
            bury(removed)   # bench them: fbpool/model_pool_init won't re-add
            ids = [r["id"] for r in removed]
            if kept:
                save_pool(kept)
                write_config(kept)
                # the built-in pool router re-reads pool.json on
                # EVERY request - no restart needed
                print("auto-pruned dead/EOL models: " + ", ".join(ids), flush=True)
            else:
                print("auto-prune: ALL pool models look dead: " + ", ".join(ids), flush=True)
            # smart notify: digest + per-model cooldown, never spams
            notify_pruned(removed, len(kept))
        except Exception as e:
            print("auto-prune error: " + str(e), flush=True)


def write_config(pool):
    L = ["model_list:"]
    def dep(alias, provider, mid):
        if provider == "custom":
            base = (os.environ.get("CUSTOM_API_BASE") or "").strip().rstrip("/")
            if not base:
                return
            L.append('  - model_name: "%s"' % alias)
            L.append("    litellm_params:")
            L.append('      model: "openai/%s"' % mid)
            L.append('      api_base: "%s"' % base)
            if os.environ.get("CUSTOM_API_KEY"):
                L.append("      api_key: os.environ/CUSTOM_API_KEY")
            else:
                L.append('      api_key: "dummy"')
            L.append("      rpm: 20")
            return
        keys = KEY_NAMES
        prefix = "nvidia_nim/"
        rpm = "40"
        for k in keys:
            L.append('  - model_name: "%s"' % alias)
            L.append("    litellm_params:")
            L.append('      model: "%s%s"' % (prefix, mid))
            L.append("      api_key: os.environ/" + k)
            L.append("      rpm: " + rpm)
            # tokens-per-minute budget: with pre-call checks on, the
            # router SKIPS keys whose TPM quota is spent this minute
            # instead of firing a request that will 429
            L.append("      tpm: 400000")
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
        bury(removed)
        save_pool(pool)
        print("pruned dead/EOL models: " + ", ".join(r["id"] for r in removed))
    write_config(pool)
    sys.exit(0)
