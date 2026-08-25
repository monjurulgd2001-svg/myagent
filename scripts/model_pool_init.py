import json, os
home = os.environ.get("HERMES_HOME", "/home/runner/.hermes")
p = os.path.join(home, "pool.json")
try:
    pool = [x for x in json.load(open(p)) if x.get("provider") in ("nvidia", "mistral", "openrouter")]
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
           and x.get("provider") in ("nvidia", "mistral", "openrouter")]
    if web:
        pool = web
        print("pool: taken from the website vault (MODEL_POOL)")
except Exception as e:
    print("::warning::MODEL_POOL from vault unreadable: %s" % e)
# NO hardcoded default model — pool stays empty until YOU pick one
os.makedirs(home, exist_ok=True)
json.dump(pool, open(p, "w"), indent=1)
print("pool:", [x["id"] for x in pool] or "EMPTY (waiting for the website pool)")
