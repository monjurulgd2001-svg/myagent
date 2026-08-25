import json, os, subprocess, sys, urllib.request


def sync_providers():
    """Refresh the /model picker providers in config.yaml after a panel
    change (model lists / pool). Best-effort - never breaks the poll."""
    for p in ("/tmp/model_providers.py",
              os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "model_providers.py")):
        if os.path.exists(p):
            try:
                subprocess.run([sys.executable, p], timeout=30)
            except Exception as e:
                print("fbpool: provider sync failed: %s" % e)
            return

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
        and x.get("provider") in ("nvidia", "mistral", "openrouter")]

# routing mode (pool | openrouter). The `ai` command is the primary way
# to switch and writes ~/.hermes/route_mode directly. The panel can also
# switch via the vault, so we only apply the VAULT value when it CHANGED
# since our last poll (tracked in a side file) - otherwise this 60s loop
# would keep overwriting a switch the user just made with the command.
# panel's full "OpenRouter models" textarea -> ~/.hermes/or_models.txt
# (router + `ai` command read it; refreshed every poll so a model typed on
# the panel is usable within ~60s without any run restart)
or_raw = str(data.get("OR_MODELS") or "").strip()
if or_raw:
    os.makedirs(home, exist_ok=True)
    orf = os.path.join(home, "or_models.txt")
    try:
        old_or = open(orf).read()
    except Exception:
        old_or = None
    if old_or != or_raw + "\n":
        open(orf, "w").write(or_raw + "\n")
        print("openrouter model list updated (%d lines)"
              % len([l for l in or_raw.splitlines() if l.strip()]))
        sync_providers()   # keep the /model picker in step with the panel

mode = str(data.get("ROUTE_MODE") or "").strip().lower()
if mode in ("pool", "openrouter"):
    mpath = os.path.join(home, "route_mode")
    seen = os.path.join(home, ".route_mode_vault")
    try:
        last_vault = open(seen).read().strip()
    except Exception:
        last_vault = None
    if last_vault != mode:              # panel actually flipped the switch
        os.makedirs(home, exist_ok=True)
        open(mpath, "w").write(mode + "\n")
        open(seen, "w").write(mode + "\n")
        print("route mode -> " + mode + " (panel)")

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
    sync_providers()   # keep the /model picker in step with the panel
else:
    print("fbpool: pool unchanged (%d models)" % len(pool))
sys.exit(0)
