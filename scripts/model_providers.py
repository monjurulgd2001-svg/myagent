"""Write the /model picker providers from YOUR panel state.

Two SEPARATE providers, side by side like the built-in NVIDIA/Mistral:
  - pool             : "pool-auto" + every NVIDIA+Mistral model you ticked
  - openrouter-free  : "or-auto"   + every model in the panel's OpenRouter box
Both point at the local pool router (:4000) which sends each id to the
right upstream, so picking ANY entry in /model just works.

Written to BOTH config sections because hermes splits them (issue #7054):
  providers:        <- what the /model picker lists
  custom_providers: <- what runtime resolution reads
Aliases: /model pool -> pool-auto, /model or -> or-auto (instant switch).
Re-run by fbpool.py whenever the panel lists change, so the picker follows
the website without a redeploy.
"""
import json, os, yaml

HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
CFG = os.path.join(HOME, "config.yaml")
BASE = "http://localhost:4000/v1"


def pool_models():
    try:
        items = json.load(open(os.path.join(HOME, "pool.json")))
    except Exception:
        return []
    return [x["id"] for x in items if isinstance(x, dict) and x.get("id")
            and x.get("provider") in ("nvidia", "mistral")]


def or_models():
    out = []
    try:
        raw = open(os.path.join(HOME, "or_models.txt")).read()
    except Exception:
        raw = ""
    for line in raw.replace(",", "\n").splitlines():
        m = line.strip()
        if m and m not in out:
            out.append(m)
    return out


def main():
    try:
        cfg = yaml.safe_load(open(CFG)) or {}
    except Exception:
        cfg = {}

    pool_ids = ["pool-auto"] + pool_models()
    or_ids = ["or-auto"] + or_models()

    provs = cfg.get("providers") or {}
    provs["pool"] = {
        "api": BASE, "base_url": BASE, "api_key": "sk-local",
        "models": {m: {} for m in pool_ids},
    }
    provs["openrouter-free"] = {
        "api": BASE, "base_url": BASE, "api_key": "sk-local",
        "models": {m: {} for m in or_ids},
    }
    cfg["providers"] = provs

    cfg["custom_providers"] = [
        {"name": "pool", "base_url": BASE, "api_key": "sk-local",
         "model": "pool-auto", "models": pool_ids},
        {"name": "openrouter-free", "base_url": BASE, "api_key": "sk-local",
         "model": "or-auto", "models": or_ids},
    ]

    al = cfg.get("model_aliases") or {}
    al["pool"] = {"model": "pool-auto", "provider": "custom", "base_url": BASE}
    al["or"] = {"model": "or-auto", "provider": "custom", "base_url": BASE}
    cfg["model_aliases"] = al

    os.makedirs(HOME, exist_ok=True)
    yaml.safe_dump(cfg, open(CFG, "w"), sort_keys=False)
    print("providers written: pool(%d models) openrouter-free(%d models)"
          % (len(pool_ids), len(or_ids)))


if __name__ == "__main__":
    main()
