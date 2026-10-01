import datetime, json, os, sys, time, urllib.request

api = os.environ.get("FIREBASE_API_KEY", "").strip()
url = os.environ.get("FIREBASE_DB_URL", "").strip().rstrip("/")
email = os.environ.get("FIREBASE_EMAIL", "").strip()
pw = os.environ.get("FIREBASE_PASSWORD", "")
home = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
path = os.path.join(home, "pool.json")
GRAVEYARD = os.path.join(home, "graveyard.json")
GRAVE_TTL = float(os.environ.get("GRAVEYARD_TTL_H", "24")) * 3600
if not (api and url and email and pw):
    print("fbpool: vault not configured"); sys.exit(1)
try:
    signin = ("https://identitytoolkit.googleapis.com/v1/"
              "accounts:signInWithPassword?key=" + api)
    body = json.dumps({"email": email, "password": pw,
                       "returnSecureToken": True}).encode()
    req = urllib.request.Request(signin, data=body,
          headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        tok = json.load(r)
    node = (url + "/secrets/" + tok["localId"] +
            ".json?auth=" + tok["idToken"])
    with urllib.request.urlopen(node, timeout=30) as r:
        data = json.load(r) or {}
except Exception as e:
    print("fbpool: " + str(e)); sys.exit(1)

raw = data.get("MODEL_POOL") or "[]"
try:
    items = json.loads(raw) if isinstance(raw, str) else raw
except Exception as e:
    print("fbpool: MODEL_POOL unreadable: %s" % e); sys.exit(1)
pool = [{"id": x["id"], "provider": x["provider"]} for x in (items or [])
        if isinstance(x, dict) and x.get("id")
        and x.get("provider") in ("nvidia", "custom")]
if not pool:
    print("fbpool: no models applied on the website yet"); sys.exit(1)

# ── graveyard filter ──
# poolctl benches dead models in graveyard.json. Without this filter the
# 60s vault sync kept RE-ADDING them, poolctl re-pruned them 30 min later
# and Telegram got the same 🪦 alert forever. Rules:
#  • buried + still fresh  -> keep it OUT of pool.json (silently)
#  • grave older than TTL  -> let it back in for one retry
#  • pool re-applied on the website AFTER the burial -> un-bury
#    immediately (the user explicitly asked to retry it)
def _grave_load():
    try:
        g = json.load(open(GRAVEYARD))
        return g if isinstance(g, dict) else {}
    except Exception:
        return {}

def _iso_ts(s):
    try:
        return datetime.datetime.fromisoformat(
            str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0

grave = _grave_load()
if grave:
    applied_ts = _iso_ts(data.get("MODEL_POOL_UPDATED") or "")
    now = time.time()
    kept, benched, unburied = [], [], False
    for x in pool:
        e = grave.get(x["provider"] + "::" + x["id"])
        if not e:
            kept.append(x); continue
        ts = float(e.get("ts", 0) or 0)
        if applied_ts and applied_ts > ts:
            del grave[x["provider"] + "::" + x["id"]]
            unburied = True
            kept.append(x)
        elif now - ts >= GRAVE_TTL:
            kept.append(x)          # grave expired -> one fresh chance
        else:
            benched.append(x["id"])
    if unburied:
        os.makedirs(home, exist_ok=True)
        json.dump(grave, open(GRAVEYARD, "w"), indent=1)
    if benched:
        print("fbpool: benched (recently pruned, skipping): " + ", ".join(benched))
    pool = kept
if not pool:
    print("fbpool: every applied model is currently benched — "
          "re-apply the pool on the website to force a retry"); sys.exit(1)

try:
    old = json.load(open(path))
except Exception:
    old = None
if old != pool:
    os.makedirs(home, exist_ok=True)
    json.dump(pool, open(path, "w"), indent=1)
    print("CHANGED pool from website (%d): %s"
          % (len(pool), ", ".join(x["id"] for x in pool)))
else:
    print("fbpool: pool unchanged (%d models)" % len(pool))
sys.exit(0)
