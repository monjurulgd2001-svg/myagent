import json, os, random, socket, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
POOL = os.path.join(HOME, "pool.json")
BASES = {"nvidia": "https://integrate.api.nvidia.com/v1",
         "mistral": "https://api.mistral.ai/v1"}
KEYS = {p: [v for k, v in sorted(os.environ.items())
            if k.startswith(pref) and v]
        for p, pref in (("nvidia", "NVIDIA_KEY_"),
                        ("mistral", "MISTRAL_KEY_"))}
LOCK = threading.Lock()
COOL = {}      # key -> unix ts until which it is cooling down (429)
DEAD = set()   # keys that failed auth mid-run (401/403)
RR = {"nvidia": 0, "mistral": 0, "pool": 0}
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
    if m.startswith(("mistral", "codestral", "magistral", "pixtral",
                     "ministral", "open-mi", "devstral")):
        return 5.0   # Mistral production API is always fast
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
                if x.get("provider") in BASES and x.get("id")]
    except Exception:
        return []

def keys_for(provider):
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


def candidates(model):
    pool = load_pool()
    if model in ("", None, "pool-auto"):
        if not pool:
            return []
        now = time.time()
        fresh = [x for x in pool if MCOOL.get(x["id"], 0) <= now]
        use = fresh or pool
        # smart routing: fastest model (learned first-token latency)
        # goes first; small jitter keeps occasionally probing the
        # slower ones so their stats stay fresh.
        # provider preference: Mistral's production API is far more
        # stable than the free NVIDIA endpoint, so its models get their
        # effective score multiplied by MISTRAL_PREFER (<1 = preferred).
        # With the 0.5 default a Mistral model wins unless it is more
        # than 2x slower than the best NVIDIA one.
        mpref = float(os.environ.get("MISTRAL_PREFER", "0.5"))
        with LOCK:
            use = sorted(use, key=lambda x: LAT.get(x["id"],
                seed_latency(x["id"])) * random.uniform(0.9, 1.1)
                * (mpref if x["provider"] == "mistral" else 1.0))
        return [(x["provider"], x["id"]) for x in use]
    for x in pool:
        if x["id"] == model:
            return [(x["provider"], x["id"])]
    mist = ("mistral", "codestral", "magistral", "pixtral",
            "ministral", "open-mistral", "open-mixtral", "devstral")
    prov = "mistral" if model.startswith(mist) else "nvidia"
    return [(prov, model)]

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
        for provider, mid in cands:
            if time.time() - t_req > req_budget:
                last += " (request time budget spent)"
                break
            url = BASES[provider] + "/chat/completions"
            tries = keys_for(provider)
            if not tries:
                last = "all %s keys cooling down or dead" % provider
                continue
            body = dict(payload)
            body["model"] = mid
            # fix: Mistral models only accept reasoning_effort
            # "high" or "none" - Hermes sends "medium" by default,
            # which makes Mistral 400 every request. Drop the
            # unsupported value so the call goes through.
            if provider == "mistral" and body.get("reasoning_effort") not in (None, "high", "none"):
                body.pop("reasoning_effort", None)
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
            model_down = False
            model_skip = False
            # per-model time budget: one model may NEVER eat more than
            # this many seconds in total (across all its keys) before we
            # move on to the next model in the pool
            m_start = time.time()
            m_budget = max(ftmo * 2.0, 25.0)
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
                if not stream:
                    out = resp.read()
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
    print("pool-router on :4000 (nvidia keys: %d, mistral keys: %d)"
          % (len(KEYS["nvidia"]), len(KEYS["mistral"])), flush=True)
    srv.serve_forever()
