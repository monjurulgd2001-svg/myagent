#!/usr/bin/env python3
# Keep the Camofox engine AND one placeholder tab alive so the
# noVNC view always shows a browser window (no black screen) and
# x11vnc never dies from the 5-min idle shutdown (no disconnects).
import json, os, time, urllib.request

BASE = "http://127.0.0.1:9377"
STATE = (os.environ.get("CAMOFOX_STATE_FILE") or
         "/home/runner/.hermes/data/camofox-profiles/boss-view-storage.json")
IDLE_PAGE = ("data:text/html,<body style='background:%23111;color:%23ddd;"
             "font-family:sans-serif;display:flex;align-items:center;"
             "justify-content:center;height:100vh;text-align:center'>"
             "<div><h1>&%23128058; Camofox is awake</h1>"
             "<p>This placeholder tab keeps the browser alive.<br>"
             "The agent browses in tabs of this SAME window, with your logins.<br>"
             "To log in yourself: use the agent's window, or open a new tab"
             " with the %2B button - do NOT use this tab.</p></div></body>")

def req(method, path, body=None, timeout=20):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=timeout) as f:
        raw = f.read().decode() or "{}"
    try:
        return json.loads(raw)
    except Exception:
        return {}

def restore_cookies():
    # Fresh engine/session starts with ZERO cookies - re-import the
    # saved logins so the user never has to log in again.
    try:
        with open(STATE) as f:
            cookies = (json.load(f) or {}).get("cookies") or []
    except Exception:
        return
    for i in range(0, len(cookies), 400):
        try:
            req("POST", "/sessions/boss-view/cookies",
                {"cookies": cookies[i:i + 400]}, timeout=30)
        except Exception:
            pass

def save_cookies():
    # Export boss-view cookies+localStorage into the data-repo dir;
    # the backup loop pushes it, so logins survive machine runs.
    try:
        st = req("GET", "/sessions/boss-view/storage_state", timeout=30)
    except Exception:
        return
    if not isinstance(st, dict) or not st.get("cookies"):
        return
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, STATE)
    except Exception:
        pass

tab = None
while True:
    try:
        st = req("GET", "/vnc/status", timeout=8)
        if not st.get("running"):
            try:
                req("POST", "/start", {}, timeout=40)
            except Exception:
                pass
            time.sleep(15)
        if tab:
            try:
                req("POST", "/tabs/" + str(tab) + "/refresh", {}, timeout=30)
            except Exception:
                tab = None
        if not tab:
            for target in (IDLE_PAGE, "about:blank"):
                try:
                    resp = req("POST", "/tabs", {"userId": "boss-view",
                               "sessionKey": "view", "url": target}, timeout=60)
                    tab = (resp.get("id") or resp.get("tabId") or
                           (resp.get("tab") or {}).get("id"))
                    if tab:
                        break
                except Exception:
                    continue
            if tab:
                restore_cookies()
        save_cookies()
    except Exception:
        pass
    time.sleep(120)
