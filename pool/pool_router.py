import json, os, random, socket, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
POOL = os.path.join(HOME, "pool.json")
BASES = {"nvidia": "https://integrate.api.nvidia.com/v1"}

# ── custom "web→API" provider ──
# Any OpenAI-compatible endpoint (e.g. the ChatGPT browser-bridge
# workflow behind a Cloudflare quick tunnel) joins the pool as
# provider "custom". Tunnel URLs change on every bridge run, so the
# base/key are re-read LIVE from ~/.hermes/.env (vault_sync mirrors
# panel/vault changes there within ~45s) - no restart needed.
ENVF = os.path.join(HOME, ".env")
_ENV_CACHE = {"mtime": -1.0, "vals": {}}

def _live_env(name):
    try:
        mt = os.path.getmtime(ENVF)
        if mt != _ENV_CACHE["mtime"]:
            vals = {}
            for ln in open(ENVF, encoding="utf-8", errors="replace"):
                if "=" in ln and not ln.lstrip().startswith("#"):
                    k, v = ln.split("=", 1)
                    vals[k.strip()] = v.strip()
            _ENV_CACHE["mtime"] = mt
            _ENV_CACHE["vals"] = vals
        v = _ENV_CACHE["vals"].get(name, "")
    except Exception:
        v = ""
    return v or os.environ.get(name, "")

def base_for(provider):
    if provider == "custom":
        # the LOCAL bridge (started by hermes.yml on this same runner) always
        # wins; the panel/vault CUSTOM_API_BASE is only a remote fallback
        local = _live_env("CUSTOM_API_BASE_LOCAL").strip().rstrip("/")
        if local:
            return local
        return _live_env("CUSTOM_API_BASE").strip().rstrip("/")
    return BASES.get(provider, "")
KEYS = {p: [v for k, v in sorted(os.environ.items())
            if k.startswith(pref) and v]
        for p, pref in (("nvidia", "NVIDIA_KEY_"),)}
LOCK = threading.Lock()
COOL = {}      # key -> unix ts until which it is cooling down (429)
DEAD = set()   # keys that failed auth mid-run (401/403)
RR = {"nvidia": 0, "pool": 0}
KSTRIKE = {}   # key -> consecutive 429 strikes (reset on success)
KLAST = {}     # key -> unix ts of last use (least-recently-used spread)
COOLDOWN = 30
# ── first-token timeout ──
# If a streaming model emits NOTHING for FT seconds, abort and fail
# over to the next model/key instead of hanging ("waiting on
# pool-auto - 150s with no output yet"). Once the first token has
# arrived, the stream may pause up to STALL seconds (reasoning
# models think mid-stream). A model that hit the FT limit is skipped
# by pool-auto for MCOOLDOWN seconds.
FT = int(os.environ.get("FIRST_TOKEN_TIMEOUT", "12"))
# non-streaming calls: max seconds to hold ONE model before
# failing over (was 180 - way too long with this many keys)
NST = int(os.environ.get("NONSTREAM_TIMEOUT", "60"))
STALL = int(os.environ.get("STREAM_STALL_TIMEOUT", "180"))
MCOOLDOWN = 300
MCOOL = {}     # model id -> unix ts until which pool-auto skips it

# ── smart latency routing ──
# EMA of observed first-token latency per model. pool-auto sends
# every request to the fastest model first; slower ones are only
# fallback. New models start from a size/provider-based guess.
LAT = {}

def seed_latency(mid):
    m = mid.lower()
    if any(t in m for t in ("nano", "mini", "tiny", "small")):
        return 4.0
    if any(t in m for t in ("medium",)):
        return 8.0
    if any(t in m for t in ("ultra", "large", "405b", "550b")):
        return 25.0
    return 10.0

def note_latency(mid, secs):
    with LOCK:
        prev = LAT.get(mid, seed_latency(mid))
        LAT[mid] = prev * 0.7 + secs * 0.3

def load_pool():
    try:
        return [x for x in json.load(open(POOL))
                if (x.get("provider") in BASES or x.get("provider") == "custom")
                and x.get("id")]
    except Exception:
        return []

def keys_for(provider):
    if provider == "custom":
        # a web-bridge endpoint has ONE (often optional) key
        return [_live_env("CUSTOM_API_KEY").strip()] if base_for("custom") else []
    now = time.time()
    with LOCK:
        ks = [k for k in KEYS.get(provider, ())
              if k not in DEAD and COOL.get(k, 0) <= now]
        # smart key ordering: healthiest keys first (fewest recent 429
        # strikes), then least-recently-used, so the load spreads evenly
        # across EVERY key instead of hammering the same few in order
        ks.sort(key=lambda k: (KSTRIKE.get(k, 0), KLAST.get(k, 0.0)))
    return ks

def is_err_payload(buf):
    """True when a 200 response actually carries an ERROR payload - NVIDIA
    relays upstream failures (e.g. 'ResourceExhausted: worker limit') INSIDE
    the body/stream with HTTP 200, which used to reach the client as-is and
    surface as 'retrying API call after error' in the gateway."""
    s = buf.lstrip()[:1024]
    if s.startswith(b"data:"):
        s = s[5:].lstrip()
    if not s.startswith(b"{"):
        return False
    head = s[:600]
    return (b'"error"' in head and b'"choices"' not in head
            and b'"delta"' not in head)


def _custom_msg(out):
    """(content, tool_calls, finish_reason, id, model) from a custom web-API
    chat.completion JSON body. tool_calls MUST survive the JSON->SSE
    conversion - dropping them is what made the ChatGPT web model chat-only
    (no terminal / browser / files / vision tools for Hermes)."""
    try:
        j = json.loads(out)
        ch = (j.get("choices") or [{}])[0]
        msg = ch.get("message") or {}
        content = msg.get("content") or ""
        calls = msg.get("tool_calls") or None
        fin = ch.get("finish_reason") or ("tool_calls" if calls else "stop")
        return (content, calls, fin, j.get("id") or "chatcmpl-custom",
                j.get("model") or "custom")
    except Exception:
        return (out.decode("utf-8", "replace"), None, "stop",
                "chatcmpl-custom", "custom")


def _tool_call_deltas(calls):
    """OpenAI streaming shape for tool calls (index + full args at once)."""
    return [{"index": i, "id": c.get("id") or "call_%d_%d" % (int(time.time()), i),
             "type": "function",
             "function": {"name": (c.get("function") or {}).get("name", ""),
                          "arguments": (c.get("function") or {}).get("arguments")
                          or "{}"}}
            for i, c in enumerate(calls)]


# ── TWO-WAY AUTO-FAILOVER ──
# ChatGPT web-API fails (bridge offline / still logging in / error / rate
# limit / timeout)  -> INSTANTLY continue on the NVIDIA key pool.
# EVERY NVIDIA model / key fails                     -> continue on ChatGPT.
# Works for pool-auto AND for an explicitly picked model (/model chatgpt or
# /model <nvidia-id>): the picked model is always tried first, the rest of
# the pool follows as fallback. AUTO_FAILOVER=0 restores the old strict mode.
def _custom_names():
    names = [n.strip() for n in _live_env("CUSTOM_MODELS").split(",") if n.strip()]
    return names or ["chatgpt"]


def _by_speed(items, pref_custom=True):
    cpref = float(os.environ.get("CUSTOM_PREFER", "3.0")) if pref_custom else 1.0
    with LOCK:
        return sorted(items, key=lambda x: LAT.get(x["id"],
            seed_latency(x["id"])) * random.uniform(0.9, 1.1)
            * (cpref if x["provider"] == "custom" else 1.0))


def candidates(model):
    pool = load_pool()
    failover = os.environ.get("AUTO_FAILOVER", "1") != "0"
    now = time.time()
    fresh = lambda x: MCOOL.get(x["id"], 0) <= now
    if model in ("", None, "pool-auto"):
        # healthy models first (fastest first), cooled-down ones stay as a
        # LAST resort instead of being dropped
        order = (_by_speed([x for x in pool if fresh(x)])
                 + _by_speed([x for x in pool if not fresh(x)]))
    else:
        sel = next((x for x in pool if x["id"] == model), None)
        if sel is None:
            prov = "custom" if model in _custom_names() else "nvidia"
            sel = {"provider": prov, "id": model}
        if not failover:
            return [(sel["provider"], sel["id"])]
        others = [x for x in pool if x["id"] != model]
        nv = [x for x in others if x["provider"] != "custom"]
        cu = [x for x in others if x["provider"] == "custom"]
        nv = _by_speed([x for x in nv if fresh(x)]) + _by_speed([x for x in nv if not fresh(x)])
        cu = _by_speed(cu, False)
        rest = nv + cu  # NVIDIA pool first, ChatGPT web last
        # a picked model that just failed (cooling) goes BEHIND the fallbacks
        # -> the switch is instant on the next request too
        order = ([sel] + rest) if fresh(sel) else (rest + [sel])
    out, seen = [], set()
    for x in order:
        k = (x["provider"], x["id"])
        if k not in seen:
            seen.add(k)
            out.append(k)
    # NVIDIA-only pool but a web bridge is configured -> ChatGPT is still
    # the final safety net when every NVIDIA model/key has failed
    if (failover and base_for("custom")
            and not any(p == "custom" for p, _ in out)):
        out.append(("custom", _custom_names()[0]))
    return out


# ── instant bridge health check (cached) ──
# The ChatGPT bridge HOLDS requests while it is still logging in (minutes).
# Ask /health first: offline or "initializing" -> skip it instantly.
_HEALTH = {}

def custom_ready(base):
    now = time.time()
    hit = _HEALTH.get(base)
    if hit and now - hit[0] < float(os.environ.get("CUSTOM_HEALTH_TTL", "5")):
        return hit[1]
    root = base[:-3] if base.endswith("/v1") else base
    ok = True
    try:
        r = urllib.request.urlopen(root + "/health", timeout=float(
            os.environ.get("CUSTOM_HEALTH_TIMEOUT", "3")))
        try:
            st = (json.loads(r.read(2000) or b"{}") or {}).get("status")
            if st and st != "ready" and st != "ok":
                ok = False
        except Exception:
            pass  # not our bridge / no JSON -> unknown, assume usable
    except urllib.error.HTTPError:
        ok = True   # endpoint alive, just has no /health route
    except Exception:
        ok = False  # connection refused / DNS / timeout = bridge offline
    _HEALTH[base] = (now, ok)
    return ok


_BAD_WEB = ("you've reached", "you have reached", "usage limit",
            "message limit", "something went wrong", "network error",
            "an error occurred", "too many requests", "unusual activity",
            "please try again later", "hmm...something seems to have gone wrong")

def custom_bad(out):
    """True when a 200 answer from the web bridge is useless: empty, or
    just a ChatGPT website error / rate-limit notice."""
    content, calls, _f, _i, _m = _custom_msg(out)
    if calls:
        return False
    t = (content or "").strip()
    if not t:
        return True
    low = t.lower()
    return len(t) < 400 and any(b in low for b in _BAD_WEB)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:
            pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/health", "/health/liveliness",
                    "/health/readiness"):
            return self._json(200, {"status": "ok"})
        if path in ("/models", "/v1/models"):
            ids = ["pool-auto"] + [x["id"] for x in load_pool()]
            return self._json(200, {"object": "list", "data": [
                {"id": i, "object": "model", "owned_by": "pool-router"}
                for i in ids]})
        return self._json(404, {"error": {"message": "not found: " + path}})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path not in ("/chat/completions", "/v1/chat/completions"):
            return self._json(404, {"error": {"message": "not found: " + path}})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json(400, {"error": {"message": "invalid JSON body"}})
        model = payload.get("model") or "pool-auto"
        stream = bool(payload.get("stream"))
        cands = candidates(model)
        if not cands:
            return self._json(503, {"error": {"message":
                "no models in the pool - apply a pool on the config website"}})
        last = "exhausted all models/keys"
        t_req = time.time()
        # hard per-request budget: NEVER keep one request grinding through
        # models/keys until the client-side watchdog fires ("waiting on
        # pool-auto - 150s with no output yet"). Give up well before that
        # with a clean 502 so the gateway retries a fresh request instead.
        req_budget = float(os.environ.get("POOL_REQUEST_BUDGET", "110"))
        # big prompts legitimately need more total time (long prefill on
        # every model we try): +1s per 6KB of request body, capped at +240s
        req_budget += min(n / 1024.0 / 6.0, 240.0)
        for idx, (provider, mid) in enumerate(cands):
            if time.time() - t_req > req_budget:
                # budget spent on NVIDIA: still let the ChatGPT web model
                # (streamed with heartbeats) act as the final fallback
                if provider != "custom" or not stream:
                    last += " (request time budget spent)"
                    continue
            base = base_for(provider)
            if not base:
                last = ("custom web-API URL not configured - start the "
                        "web-API workflow or set it on the config website")
                continue
            if idx > 0:
                print("pool-router: failover -> %s %s (%s)" % (provider, mid,
                      last[:160]), flush=True)
            if provider == "custom" and not custom_ready(base):
                last = ("custom %s: bridge offline / still logging in - "
                        "instant failover" % mid)
                continue
            url = base + "/chat/completions"
            tries = keys_for(provider)
            if not tries:
                last = "all %s keys cooling down or dead" % provider
                continue
            body = dict(payload)
            body["model"] = mid
            if provider == "custom":
                # web bridges (browser ChatGPT) don't stream - fetch a
                # plain JSON completion and convert it to SSE ourselves
                body.pop("stream", None)
            data = json.dumps(body).encode()
            # adaptive timeouts: fast models get a SHORT first-token gate
            # (quicker failover = snappier chat), slow models keep room;
            # huge payloads (vision images / base64 files) get extra
            # upload + processing time instead of a false timeout
            ema = LAT.get(mid, seed_latency(mid))
            # the first-token gate must scale with PROMPT SIZE: a big agent
            # context (hermes sends 100k+ tokens) needs a long PREFILL before
            # any token comes out. A flat 12-20s gate kills models that are
            # actually working fine on a big request - they get cooled down
            # one by one until the request burns its whole budget and 502s
            # ("model time budget spent ... request time budget spent").
            # So: +1s of gate per 10KB of payload, capped at 90s.
            kb = len(data) / 1024.0
            ftmo = min(max(5.0, ema * 2.0) + kb / 10.0, 90.0)
            nstmo = min(NST + kb / 5.0, NST * 3.0)
            tmo = ftmo if stream else nstmo
            if provider == "custom":
                # a browser bridge legitimately takes minutes on a long
                # answer - give it a big flat window instead of the
                # first-token gate
                tmo = float(os.environ.get("CUSTOM_TIMEOUT", "300"))
            model_down = False
            model_skip = False
            # per-model time budget: one model may NEVER eat more than
            # this many seconds in total (across all its keys) before we
            # move on to the next model in the pool
            m_start = time.time()
            m_budget = max(ftmo * 2.0, 25.0)
            if provider == "custom":
                m_budget = tmo + 30.0
            for key in tries:
                if time.time() - m_start > m_budget:
                    last = ("%s %s: model time budget spent - next model"
                            % (provider, mid))
                    break
                if key:
                    with LOCK:
                        KLAST[key] = time.time()
                hdrs = {"Content-Type": "application/json", "Accept": "*/*"}
                if key:
                    hdrs["Authorization"] = "Bearer " + key
                if provider == "custom" and stream:
                    # web bridge sends NOTHING until it finishes (minutes on
                    # a long answer); stream heartbeats meanwhile so agent
                    # harness stale timers don't abort the wait
                    done = self._sse_keepalive_fetch(url, data, hdrs, tmo, mid,
                                                     payload, cands[idx + 1:])
                    if done:
                        return
                    # failed FAST (before anything was sent) -> next model
                    with LOCK:
                        MCOOL[mid] = time.time() + MCOOLDOWN
                    last = "custom %s: bridge failed - instant failover" % mid
                    break
                resp = None
                t0 = time.time()
                for attempt in (0, 1):
                    try:
                        resp = urllib.request.urlopen(
                            urllib.request.Request(url, data=data, headers=hdrs),
                            timeout=tmo)
                        break
                    except urllib.error.HTTPError as e:
                        try:
                            err_txt = e.read(300).decode("utf-8", "replace")
                        except Exception:
                            err_txt = ""
                        if (attempt == 0 and e.code == 400
                                and "reasoning_effort" in err_txt
                                and "reasoning_effort" in body):
                            # model rejected this reasoning_effort
                            # value: strip it and retry once with
                            # the same key instead of failing over
                            body.pop("reasoning_effort", None)
                            data = json.dumps(body).encode()
                            continue
                        low = err_txt.lower()
                        if e.code == 400 and any(t in low for t in
                                ("context", "too long", "token limit",
                                 "maximum length", "tokens exceed",
                                 "input length")):
                            # the request is too BIG for this model's
                            # context window - jump straight to the next
                            # model (no cooldown: the model is healthy,
                            # only this request does not fit)
                            last = ("%s %s: context window too small for "
                                    "this request - trying a bigger model"
                                    % (provider, mid))
                            model_skip = True
                            break
                        if key and e.code in (401, 403):
                            with LOCK:
                                DEAD.add(key)
                        elif key and e.code == 429:
                            ra = 0
                            try:
                                ra = int(float((e.headers.get("Retry-After")
                                                or "0").strip() or 0))
                            except Exception:
                                ra = 0
                            with LOCK:
                                KSTRIKE[key] = KSTRIKE.get(key, 0) + 1
                                # honest cooldown: obey Retry-After when the
                                # provider sends it, else exponential
                                # backoff per strike (30s, 60s, ... max 5m)
                                COOL[key] = time.time() + (ra or min(
                                    COOLDOWN * (2 ** (KSTRIKE[key] - 1)), 300))
                        if (e.code >= 500 or e.code == 429
                                or "ResourceExhausted" in err_txt):
                            # the MODEL/provider is overloaded - cool the
                            # model and jump to the NEXT pool model instead
                            # of burning every key on the same broken one
                            with LOCK:
                                MCOOL[mid] = time.time() + MCOOLDOWN
                            model_down = True
                        last = "%s %s: HTTP %d %s" % (provider, mid,
                                                      e.code, err_txt)
                        break
                    except Exception as e:
                        last = "%s %s: %s" % (provider, mid, e)
                        emsg = str(e).lower()
                        if (isinstance(e, (socket.timeout, TimeoutError))
                                or "timed out" in emsg or "timeout" in emsg):
                            # the MODEL is hanging (connect / first-byte
                            # timeout - classic overload). Trying more keys
                            # of the SAME model burns the full timeout on
                            # every key and is exactly what caused
                            # "waiting on pool-auto - 150s with no output
                            # yet". Cool the model, jump to the next one.
                            with LOCK:
                                MCOOL[mid] = time.time() + MCOOLDOWN
                            model_down = True
                        break
                if resp is None:
                    if model_skip:
                        break  # next model - request too big for this one
                    if model_down:
                        print("pool-router: %s cooling down - next model (%s)"
                              % (mid, last[:200]), flush=True)
                        break  # next model - this one is overloaded
                    continue
                if not stream or provider == "custom":
                    out = resp.read()
                    if provider == "custom" and custom_bad(out):
                        with LOCK:
                            MCOOL[mid] = time.time() + MCOOLDOWN
                        last = ("custom %s: empty / ChatGPT error answer - "
                                "failing over: %s" % (mid,
                                out[:160].decode("utf-8", "replace")))
                        print("pool-router: " + last, flush=True)
                        break
                    if is_err_payload(out):
                        with LOCK:
                            MCOOL[mid] = time.time() + MCOOLDOWN
                        last = ("%s %s: error body despite HTTP 200 - "
                                "failing over: %s" % (provider, mid,
                                out[:200].decode("utf-8", "replace")))
                        print("pool-router: " + last, flush=True)
                        break  # next model
                    if key:
                        with LOCK:
                            KSTRIKE[key] = 0
                    note_latency(mid, time.time() - t0)
                    if stream:
                        # client asked for SSE but the custom bridge
                        # answered plain JSON - wrap it as one chunk
                        return self._sse_from_json(out)
                    return self._relay(resp, out)
                # ── first-token gate ── the FT socket timeout is
                # still active, so this read fails fast if the model
                # sits silent; nothing was sent to the client yet, so
                # we can still fail over cleanly.
                try:
                    head = resp.read1(65536)
                except Exception:
                    try:
                        resp.close()
                    except Exception:
                        pass
                    with LOCK:
                        MCOOL[mid] = time.time() + MCOOLDOWN
                    last = ("%s %s: no first token within %ds - "
                            "failing over" % (provider, mid, int(ftmo)))
                    print("pool-router: " + last, flush=True)
                    # the MODEL is slow, not the key - trying
                    # more keys of the same model just burns
                    # FT seconds each. Jump to the next model.
                    break
                if not head:
                    last = "%s %s: empty response" % (provider, mid)
                    continue
                if is_err_payload(head):
                    try:
                        resp.close()
                    except Exception:
                        pass
                    with LOCK:
                        MCOOL[mid] = time.time() + MCOOLDOWN
                    last = ("%s %s: in-stream error despite HTTP 200 - "
                            "failing over: %s" % (provider, mid,
                            head[:200].decode("utf-8", "replace")))
                    print("pool-router: " + last, flush=True)
                    # the error came from the MODEL/provider - jump to the
                    # next pool model instead of burning more keys here
                    break
                if key:
                    with LOCK:
                        KSTRIKE[key] = 0
                note_latency(mid, time.time() - t0)
                # first token arrived - relax the per-read timeout so
                # legit mid-stream thinking pauses don't kill the run
                try:
                    resp.fp.raw._sock.settimeout(STALL)
                except Exception:
                    pass
                return self._relay(resp, head)
        print("pool-router: request failed: " + last[:300], flush=True)
        self._json(502, {"error": {"message": "pool-router: " + last[:500]}})

    def _fallback_fetch(self, payload, cands):
        """Non-streaming try of the remaining pool models (used AFTER the SSE
        response already started, so the client still gets an answer when
        the ChatGPT bridge dies mid-request). Returns (json_bytes, model)."""
        for provider, mid in cands:
            base = base_for(provider)
            if not base:
                continue
            if provider == "custom" and not custom_ready(base):
                continue
            body = dict(payload)
            body["model"] = mid
            body.pop("stream", None)
            body.pop("stream_options", None)
            data = json.dumps(body).encode()
            tmo = (float(os.environ.get("CUSTOM_TIMEOUT", "300"))
                   if provider == "custom" else min(NST * 2.0 + len(data) / 5120.0, 240.0))
            for key in keys_for(provider)[:4]:
                hdrs = {"Content-Type": "application/json"}
                if key:
                    hdrs["Authorization"] = "Bearer " + key
                try:
                    out = urllib.request.urlopen(urllib.request.Request(
                        base + "/chat/completions", data=data, headers=hdrs),
                        timeout=tmo).read()
                except urllib.error.HTTPError as e:
                    if key and e.code == 429:
                        with LOCK:
                            COOL[key] = time.time() + COOLDOWN
                    if e.code == 429 or e.code in (401, 403):
                        continue  # next key
                    break  # model-level problem -> next model
                except Exception:
                    break
                if is_err_payload(out) or (provider == "custom" and custom_bad(out)):
                    break
                print("pool-router: in-stream failover answered by %s %s"
                      % (provider, mid), flush=True)
                return out, mid
            with LOCK:
                MCOOL[mid] = time.time() + MCOOLDOWN
        return None, None

    def _sse_keepalive_fetch(self, url, data, hdrs, tmo, mdl, payload=None,
                             rest=()):
        """Custom web bridges answer one JSON blob after MINUTES of silence.
        Agent harnesses abort a silent provider (stale timer ~1-2 min), so
        when the client asked for SSE we open the stream, emit an empty-delta
        heartbeat every 10s, and send the real content when the bridge
        finishes.
        AUTO-FAILOVER: a bridge that fails within the first seconds returns
        False BEFORE anything is sent (caller switches model normally). A
        bridge that fails LATER is replaced inside the open stream by the
        next pool models (NVIDIA first). Returns True when handled."""
        result = {}
        def _fetch():
            try:
                r = urllib.request.urlopen(
                    urllib.request.Request(url, data=data, headers=hdrs),
                    timeout=tmo)
                result["out"] = r.read()
            except Exception as e:
                result["err"] = e
        th = threading.Thread(target=_fetch, daemon=True)
        th.start()
        th.join(float(os.environ.get("CUSTOM_FASTFAIL_WINDOW", "4")))
        def _ok():
            return "out" in result and not custom_bad(result["out"])
        if not th.is_alive() and not _ok():
            print("pool-router: custom %s failed fast (%s) - switching"
                  % (mdl, str(result.get("err") or "bad/empty answer")[:160]),
                  flush=True)
            return False
        rid = "chatcmpl-custom-%d" % int(time.time())
        def _chunk(delta, fin=None):
            return (b"data: " + json.dumps(
                {"id": rid, "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": mdl,
                 "choices": [{"index": 0, "delta": delta,
                              "finish_reason": fin}]}).encode() + b"\n\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        try:
            self.wfile.write(_chunk({"role": "assistant", "content": ""}))
            self.wfile.flush()
        except Exception:
            return True
        def _wait(thread, limit):
            waited = 0.0
            while thread.is_alive() and waited < limit:
                thread.join(10.0)
                waited += 10.0
                if thread.is_alive():
                    try:
                        # empty delta = heartbeat for the client stale timer
                        self.wfile.write(_chunk({"content": ""}))
                        self.wfile.flush()
                    except Exception:
                        return False  # client hung up
            return True
        if not _wait(th, tmo + 30.0):
            return True
        out = result.get("out") if _ok() else None
        if out is None:
            with LOCK:
                MCOOL[mdl] = time.time() + MCOOLDOWN
            why = str(result.get("err") or "bad/empty answer / timeout")[:160]
            print("pool-router: custom %s failed mid-request (%s) - in-stream "
                  "failover to the NVIDIA pool" % (mdl, why), flush=True)
            if payload is not None and rest:
                fb = {}
                def _fb():
                    fb["out"], fb["mid"] = self._fallback_fetch(payload, rest)
                t2 = threading.Thread(target=_fb, daemon=True)
                t2.start()
                if not _wait(t2, 600.0):
                    return True
                out = fb.get("out")
        try:
            fin = "stop"
            if out is not None:
                content, calls, fin, _rid, _m = _custom_msg(out)
                if content:
                    self.wfile.write(_chunk({"content": content}))
                if calls:
                    self.wfile.write(_chunk(
                        {"tool_calls": _tool_call_deltas(calls)}))
                    fin = "tool_calls"
                    print("pool-router: -> tool_calls: %s" % ", ".join(
                        (c.get("function") or {}).get("name", "?")
                        for c in calls), flush=True)
                elif fin == "tool_calls":
                    fin = "stop"
            else:
                err = result.get("err")
                msg = ("custom bridge error: %s" % (err,)) if err else "custom bridge failed"
                self.wfile.write(_chunk({"content": "[" + msg + " - and every fallback model failed too]"}))
            self.wfile.write(_chunk({}, fin))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except Exception:
            pass
        return True

    def _sse_from_json(self, out):
        """Convert a plain chat.completion JSON body into a minimal
        OpenAI SSE stream (used for non-streaming custom web-APIs)."""
        content, calls, finr, rid, mdl = _custom_msg(out)
        now = int(time.time())
        def _c(delta, f=None):
            return (b"data: " + json.dumps(
                {"id": rid, "object": "chat.completion.chunk", "created": now,
                 "model": mdl, "choices": [{"index": 0, "delta": delta,
                 "finish_reason": f}]}).encode() + b"\n\n")
        data = _c({"role": "assistant", "content": content})
        if calls:
            data += _c({"tool_calls": _tool_call_deltas(calls)})
        data += _c({}, "tool_calls" if calls else "stop") + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        try:
            self.wfile.write(data)
            self.wfile.flush()
        except Exception:
            pass

    def _relay(self, resp, head=b""):
        ctype = resp.headers.get("Content-Type", "application/json")
        try:
            if "text/event-stream" in ctype:
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.close_connection = True
                self.end_headers()
                if head:
                    self.wfile.write(head)
                    self.wfile.flush()
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                out = head + resp.read()
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)
        except Exception:
            self.close_connection = True

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 4000), Handler)
    srv.daemon_threads = True
    print("pool-router on :4000 (nvidia keys: %d, custom web-API: %s)"
          % (len(KEYS["nvidia"]),
             base_for("custom") or "not set"), flush=True)
    srv.serve_forever()
