# Registers model aliases in ~/.hermes/config.yaml so /model <name> works
# from Telegram/Slack. Hermes' /model picker does NOT fetch the model list
# from a custom endpoint's /v1/models (known limitation: hermes-agent issue
# #20582 - picker shows only 1 model for custom providers), so every model
# the user may want to switch to needs an explicit alias.
#
# Aliases registered here (all pointing at the pool router on :4000):
#   pool     -> pool-auto            (auto-rotation across the whole pool)
#   chatgpt  -> chatgpt              (the web->API bridge, always registered
#                                     even before the bridge first connects)
#   <short>  -> <full id>            (one alias per pool.json entry, e.g.
#                                     "llama-3.3-70b-instruct" for
#                                     "meta/llama-3.3-70b-instruct")
import json, os, yaml

ROUTER = {"provider": "custom", "base_url": "http://localhost:4000/v1"}
HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
cfg_path = os.path.expanduser("~/.hermes/config.yaml")
try:
    cfg = yaml.safe_load(open(cfg_path)) or {}
except Exception:
    cfg = {}
al = cfg.setdefault("model_aliases", {})

# the auto-rotating pool (default model)
al["pool"] = dict(ROUTER, model="pool-auto")

# the ChatGPT web->API bridge: register even if it is not in the pool yet,
# because the bridge workflow can join mid-run (the router just skips it
# gracefully until CUSTOM_API_BASE appears in ~/.hermes/.env)
al.setdefault("chatgpt", dict(ROUTER, model="chatgpt"))

# one alias per pool model so /model <name> can jump to any single model
try:
    pool = json.load(open(os.path.join(HOME, "pool.json")))
except Exception:
    pool = []
for it in pool if isinstance(pool, list) else []:
    mid = (it or {}).get("id") or ""
    if not mid:
        continue
    short = mid.split("/")[-1]  # "meta/llama-3.3-70b" -> "llama-3.3-70b"
    al.setdefault(short, dict(ROUTER, model=mid))

yaml.safe_dump(cfg, open(cfg_path, "w"), sort_keys=False)
print("model aliases ready: " + ", ".join(sorted(al)))
