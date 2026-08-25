import os, yaml
cfg_path = os.path.expanduser("~/.hermes/config.yaml")
try:
    cfg = yaml.safe_load(open(cfg_path)) or {}
except Exception:
    cfg = {}
al = cfg.setdefault("model_aliases", {})
al["pool"] = {"model": "pool-auto", "provider": "custom",
              "base_url": "http://localhost:4000/v1"}
yaml.safe_dump(cfg, open(cfg_path, "w"), sort_keys=False)
print("model aliases ready: " + ", ".join(sorted(al)))
