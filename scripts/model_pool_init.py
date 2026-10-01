import datetime, json, os, time
home = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
p = os.path.join(home, "pool.json")
GRAVEYARD = os.path.join(home, "graveyard.json")
GRAVE_TTL = float(os.environ.get("GRAVEYARD_TTL_H", "24")) * 3600
try:
    pool = [x for x in json.load(open(p)) if x.get("provider") in ("nvidia", "custom")]
except Exception:
    pool = []
# The config website (index.html -> Model pool) is the source of
# truth: whatever you applied there arrives as MODEL_POOL from the
# Firebase vault and replaces the local pool.json. No separate
# model panel is required anymore.
try:
    web = json.loads(os.environ.get("MODEL_POOL") or "[]")
    web = [{"id": x["id"], "provider": x["provider"]} for x in web
           if isinstance(x, dict) and x.get("id")
           and x.get("provider") in ("nvidia", "custom")]
    if web:
        pool = web
        print("pool: taken from the website vault (MODEL_POOL)")
except Exception as e:
    print("::warning::MODEL_POOL from vault unreadable: %s" % e)

# ── graveyard filter (same rules as fbpool.py) ──
# models poolctl benched recently stay out; a grave expires after
# GRAVE_TTL, and re-applying the pool on the website after the burial
# (MODEL_POOL_UPDATED newer than the grave) un-buries immediately.
def _iso_ts(s):
    try:
        return datetime.datetime.fromisoformat(
            str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0
try:
    grave = json.load(open(GRAVEYARD))
    grave = grave if isinstance(grave, dict) else {}
except Exception:
    grave = {}
if grave:
    applied_ts = _iso_ts(os.environ.get("MODEL_POOL_UPDATED") or "")
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
            kept.append(x)
        else:
            benched.append(x["id"])
    if unburied:
        os.makedirs(home, exist_ok=True)
        json.dump(grave, open(GRAVEYARD, "w"), indent=1)
    if benched:
        print("pool: benched (recently pruned, skipping): " + ", ".join(benched))
    pool = kept

# NO hardcoded default model — pool stays empty until YOU pick one
os.makedirs(home, exist_ok=True)
json.dump(pool, open(p, "w"), indent=1)
print("pool:", [x["id"] for x in pool] or "EMPTY (waiting for the website pool)")
