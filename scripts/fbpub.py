import json, os, sys, time, urllib.request

api = os.environ.get("FIREBASE_API_KEY", "").strip()
url = os.environ.get("FIREBASE_DB_URL", "").strip().rstrip("/")
email = os.environ.get("FIREBASE_EMAIL", "").strip()
pw = os.environ.get("FIREBASE_PASSWORD", "")
if not (api and url and email and pw):
    sys.exit(0)  # vault not configured - nothing to publish
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
    patch = {"heartbeat": int(time.time() * 1000)}
    for arg in sys.argv[1:]:
        k, _, v = arg.partition("=")
        if k:
            patch[k] = v
    node = url + "/runtime/" + uid + ".json?auth=" + id_token
    req = urllib.request.Request(node,
          data=json.dumps(patch).encode(),
          headers={"Content-Type": "application/json"},
          method="PATCH")
    urllib.request.urlopen(req, timeout=30).read()
except Exception as e:
    print("fbpub: " + str(e))
