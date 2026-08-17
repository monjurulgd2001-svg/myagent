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
        if not ks:
            return []
        RR[provider] = (RR[provider] + 1) % len(ks)
        i = RR[provider]
    return ks[i:] + ks[:i]

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
        # slower ones so their stats stay fresh
        with LOCK:
            use = sorted(use, key=lambda x: LAT.get(x["id"],
                seed_latency(x["id"])) * random.uniform(0.9, 1.1))
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
        for provider, mid in cands:
            url = BASES[provider] + "/chat/completions"
            tries, tmo = keys_for(provider), (FT if stream else NST)
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
            for key in tries:
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
                        if key and e.code in (401, 403):
                            with LOCK:
                                DEAD.add(key)
                        elif key and e.code == 429:
                            with LOCK:
                                COOL[key] = time.time() + COOLDOWN
                        last = "%s %s: HTTP %d %s" % (provider, mid,
                                                      e.code, err_txt)
                        break
                    except Exception as e:
                        last = "%s %s: %s" % (provider, mid, e)
                        break
                if resp is None:
                    continue
                if not stream:
                    note_latency(mid, time.time() - t0)
                    return self._relay(resp)
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
                            "failing over" % (provider, mid, FT))
                    print("pool-router: " + last, flush=True)
                    # the MODEL is slow, not the key - trying
                    # more keys of the same model just burns
                    # FT seconds each. Jump to the next model.
                    break
                if not head:
                    last = "%s %s: empty response" % (provider, mid)
                    continue
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
