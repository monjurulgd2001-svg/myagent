#!/usr/bin/env python3
"""Live vault sync - panel changes apply WITHOUT restarting the run.

Polls the Firebase vault (secrets/<uid>) every 45 s. When a synced value
changes, it rewrites the runtime config files that the tools re-read on
EVERY invocation, so the new value is live within about a minute:

  ~/.hermes/.env                  (upserts synced keys, keeps other lines)
  ~/.hermes/zedge-accounts.txt    ZEDGE_ACCOUNTS
  ~/.hermes/zedge-proxies.txt     ZEDGE_PROXIES
  ~/.hermes/zedge-r2.txt          ZEDGE_R2_WORKER_URL
  ~/.hermes/zedge-vpn/zedgeN.conf ZEDGE_WG_N

LIVE without restart: all Zedge settings, Hermesa phone settings, Telegram
group / Facebook page settings.
NOT live (captured by running processes at startup - needs a fresh run):
TELEGRAM_BOT_TOKEN, SLACK_*, MODEL_POOL, PANEL_TOKEN, GROQ_API_KEY.

Never crashes the job: every error is logged and retried on the next poll.
"""
import json
import os
import time
import urllib.request

HOME = os.path.expanduser("~")
HERMES = os.path.join(HOME, ".hermes")
VPN_DIR = os.path.join(HERMES, "zedge-vpn")
POLL_SECONDS = 45

API_KEY = (os.environ.get("FIREBASE_API_KEY") or "").strip()
DB_URL = (os.environ.get("FIREBASE_DB_URL") or "").strip().rstrip("/")
EMAIL = (os.environ.get("FIREBASE_EMAIL") or "").strip()
PASSWORD = (os.environ.get("FIREBASE_PASSWORD") or "").strip()

# vault keys mirrored into ~/.hermes/.env (tools re-read that file per call)
ENV_KEYS = [
    "ZEDGE_R2_WORKER_URL", "ZEDGE_DB_URL_1", "ZEDGE_DB_URL_2", "ZEDGE_DB_URL_3",
    "HERMESA_DB_URL", "HERMESA_BOT_ID",
    "TELEGRAM_GROUP_IDS", "TELEGRAM_GROUP_ROLE",
    "FACEBOOK_PAGE_TOKEN", "FACEBOOK_PAGE_ID",
]

# vault keys mirrored into standalone runtime files
FILE_KEYS = {
    "ZEDGE_ACCOUNTS": os.path.join(HERMES, "zedge-accounts.txt"),
    "ZEDGE_PROXIES": os.path.join(HERMES, "zedge-proxies.txt"),
    "ZEDGE_R2_WORKER_URL": os.path.join(HERMES, "zedge-r2.txt"),
    "ZEDGE_WG_1": os.path.join(VPN_DIR, "zedge1.conf"),
    "ZEDGE_WG_2": os.path.join(VPN_DIR, "zedge2.conf"),
    "ZEDGE_WG_3": os.path.join(VPN_DIR, "zedge3.conf"),
}


def log(m):
    print("[vault-sync] %s" % m, flush=True)


def http(url, payload=None):
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def signin():
    r = http("https://identitytoolkit.googleapis.com/v1/accounts:"
             "signInWithPassword?key=" + API_KEY,
             {"email": EMAIL, "password": PASSWORD, "returnSecureToken": True})
    return r["idToken"], r["localId"]


def write_if_changed(path, value):
    content = str(value or "").rstrip("\n") + "\n"
    try:
        old = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        old = None
    if old == content:
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return True


def upsert_env(vals):
    """Update only the synced keys in ~/.hermes/.env; keep every other line."""
    p = os.path.join(HERMES, ".env")
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        lines = []
    seen, out, changed = set(), [], False
    for ln in lines:
        k = None
        if "=" in ln and not ln.lstrip().startswith("#"):
            k = ln.split("=", 1)[0].strip()
        if k in vals:
            seen.add(k)
            new = "%s=%s" % (k, vals[k])
            if ln != new:
                changed = True
            out.append(new)
        else:
            out.append(ln)
    for k, v in vals.items():
        if k not in seen:
            out.append("%s=%s" % (k, v))
            changed = True
    if changed:
        os.makedirs(HERMES, exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
    return changed


def apply(secrets):
    changed = []
    for k, path in FILE_KEYS.items():
        # only touch a file when its key EXISTS in the vault - a fetch
        # hiccup must never blank out working configs
        if k in secrets and write_if_changed(path, secrets[k]):
            changed.append(os.path.basename(path))
    env_vals = {k: str(secrets.get(k) or "").replace("\n", " ").strip()
                for k in ENV_KEYS if k in secrets}
    if env_vals and upsert_env(env_vals):
        changed.append(".env")
    return changed


def main():
    if not (API_KEY and DB_URL and EMAIL and PASSWORD):
        log("Firebase vault not configured - live sync disabled")
        return
    token = None
    uid = None
    while True:
        try:
            if not token:
                token, uid = signin()
                log("signed in - watching secrets/%s every %ss" % (uid, POLL_SECONDS))
            secrets = http("%s/secrets/%s.json?auth=%s" % (DB_URL, uid, token))
            if isinstance(secrets, dict) and secrets:
                changed = apply(secrets)
                if changed:
                    log("LIVE UPDATE applied: " + ", ".join(sorted(set(changed))))
        except Exception as e:
            log("poll failed (%s) - re-auth next round" % e)
            token = None
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
