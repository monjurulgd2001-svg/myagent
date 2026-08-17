import json, os, sys, urllib.request

api = os.environ.get("FIREBASE_API_KEY", "").strip()
url = os.environ.get("FIREBASE_DB_URL", "").strip().rstrip("/")
email = os.environ.get("FIREBASE_EMAIL", "").strip()
pw = os.environ.get("FIREBASE_PASSWORD", "")
home = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
path = os.path.join(home, "pool.json")
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
        and x.get("provider") in ("nvidia", "mistral")]
if not pool:
    print("fbpool: no models applied on the website yet"); sys.exit(1)
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
