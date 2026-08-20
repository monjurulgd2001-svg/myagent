import json, os, urllib.request

KEYS = ["PANEL_TOKEN", "NVIDIA_KEYS", "MISTRAL_KEYS",
        "TELEGRAM_BOT_TOKEN", "TELEGRAM_USER_ID",
        "TELEGRAM_EXTRA_ALLOWED",
        "TELEGRAM_GROUP_IDS",
        "TELEGRAM_GROUP_ROLE",
        "FACEBOOK_PAGE_TOKEN",
        "FACEBOOK_PAGE_ID",
        "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_USER_ID",
        "GROQ_API_KEY", "DATA_REPO", "DATA_REPO_TOKEN",
        "GMAIL_ACCOUNTS", "STABLE_AUDIO_TOKEN",
        "HERMESA_BOT_ID", "HERMESA_DB_URL",
        "HERMESA_GROUP_DB_URL", "HERMESA_GROUP_USER_ID", "HERMESA_GROUP_BOT_NAME",
        "ZEDGE_ACCOUNTS", "ZEDGE_PROXIES", "ZEDGE_WG_1",
        "ZEDGE_WG_2", "ZEDGE_WG_3",
        "ZEDGE_R2_WORKER_URL", "ZEDGE_DB_URL_1",
        "ZEDGE_DB_URL_2", "ZEDGE_DB_URL_3",
        "MODEL_POOL"]
SECRET = {"PANEL_TOKEN", "NVIDIA_KEYS", "MISTRAL_KEYS",
          "TELEGRAM_BOT_TOKEN", "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN",
          "GROQ_API_KEY", "DATA_REPO_TOKEN", "GMAIL_ACCOUNTS",
          "STABLE_AUDIO_TOKEN", "ZEDGE_ACCOUNTS",
          "ZEDGE_PROXIES", "ZEDGE_WG_1", "ZEDGE_WG_2",
          "ZEDGE_WG_3"}
# Only STRUCTURAL defaults belong here - NEVER personal endpoints, repos,
# databases or worker URLs. Every user supplies their OWN via the config
# panel (Firebase vault) or GitHub secrets. A missing value stays empty and
# the feature that needs it errors clearly ("set it in the panel") instead
# of silently falling back to someone else's backend.
DEFAULTS = {"TELEGRAM_GROUP_ROLE": "auto",
            "FACEBOOK_PAGE_TOKEN": "",
            "FACEBOOK_PAGE_ID": ""}

api = os.environ.get("FIREBASE_API_KEY", "").strip()
url = os.environ.get("FIREBASE_DB_URL", "").strip().rstrip("/")
email = os.environ.get("FIREBASE_EMAIL", "").strip()
pw = os.environ.get("FIREBASE_PASSWORD", "")

data, uid = {}, ""
if api and url and email and pw:
    try:
        signin = ("https://identitytoolkit.googleapis.com/v1/"
                  "accounts:signInWithPassword?key=" + api)
        body = json.dumps({"email": email, "password": pw,
                           "returnSecureToken": True}).encode()
        req = urllib.request.Request(signin, data=body,
              headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            tok = json.load(r)
        uid, id_token = tok["localId"], tok["idToken"]
        node = url + "/secrets/" + uid + ".json?auth=" + id_token
        with urllib.request.urlopen(node, timeout=30) as r:
            data = json.load(r) or {}
        print("Vault: loaded secrets/" + uid + " from Firebase")
    except Exception as e:
        print("::warning::Firebase vault unreachable (%s) - "
              "falling back to GitHub secrets" % e)
        data, uid = {}, ""
else:
    print("FIREBASE_* bootstrap secrets not set - "
          "using GitHub secrets only")

values, src = {}, {}
for k in KEYS:
    fbv = str(data.get(k) or "").strip()
    ghv = str(os.environ.get("GH_" + k) or "").strip()
    v = fbv or ghv or DEFAULTS.get(k, "")
    if v:
        values[k] = v
        src[k] = "firebase" if fbv else ("github" if ghv else "default")

# mask every secret line BEFORE it can reach the log
for k in SECRET:
    for line in values.get(k, "").replace(",", "\n").splitlines():
        line = line.strip()
        if len(line) > 3:
            print("::add-mask::" + line)
if pw:
    print("::add-mask::" + pw)

with open(os.environ["GITHUB_ENV"], "a") as fh:
    for k, v in values.items():
        d = "FBEOF_" + k
        fh.write("%s<<%s\n%s\n%s\n" % (k, d, v, d))
    if uid:
        fh.write("FB_UID=%s\n" % uid)

print("Loaded: " + (", ".join("%s(%s)" % (k, src[k])
                              for k in values) or "nothing"))
