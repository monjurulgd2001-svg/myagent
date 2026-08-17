"""
Zedge Automation Tool - full LOCAL control of the 3 Zedge upload pipelines.
Queue wallpapers/ringtones, edit metadata, requeue/delete, check daily
state, and run the inbuilt Playwright upload bot on THIS machine
(no external GitHub repo or token needed).
Config: ~/.hermes/.env (ZEDGE_*) and ~/.hermes/zedge-accounts.txt.
"""
import argparse
import glob
import io
import os
import re
import shutil
import subprocess
import sys
import time

import requests

DEFAULT_DB = {
    1: "https://zedgeautomation-default-rtdb.firebaseio.com",
    2: "https://zedge-automation-2-default-rtdb.asia-southeast1.firebasedatabase.app",
    3: "https://zedge-automation-3-default-rtdb.asia-southeast1.firebasedatabase.app",
}
HOME = os.path.expanduser("~")
LOG_DIR = os.path.join(HOME, ".hermes", "logs")
RT_DIR = os.path.join(HOME, ".hermes", "zedge-runtime")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_env():
    env = {}
    p = os.path.join(HOME, ".hermes", ".env")
    if os.path.isfile(p):
        for ln in open(p, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, _, v = ln.partition("=")
                env[k.strip()] = v.strip()
    for k, v in os.environ.items():
        if k.startswith("ZEDGE_") and v.strip():
            env[k] = v
    return env


ENV = _load_env()


def cfg(k, d=""):
    return (ENV.get(k) or d).strip()


def db_url(n):
    return cfg("ZEDGE_DB_URL_%d" % n, DEFAULT_DB[n]).rstrip("/")


DEFAULT_WORKER = "https://frosty-pine-2f7dzedge-r2-gateway.holaexplainer.workers.dev"


def worker_for(n):
    """Shared R2 gateway worker. ONE Cloudflare worker + bucket serves
    every account - files stay separate via the zedgeN/ key prefix
    (verified against the original zedge dashboard + bot ymls).
    First non-empty line of ~/.hermes/zedge-r2.txt or
    ZEDGE_R2_WORKER_URL; empty = built-in default."""
    p = os.path.join(HOME, ".hermes", "zedge-r2.txt")
    if os.path.isfile(p):
        for l in open(p, encoding="utf-8", errors="replace"):
            if l.strip():
                return l.strip().rstrip("/")
    return (cfg("ZEDGE_R2_WORKER_URL").split("\n")[0].strip() or DEFAULT_WORKER).rstrip("/")


def account(n):
    p = os.path.join(HOME, ".hermes", "zedge-accounts.txt")
    lines = []
    if os.path.isfile(p):
        lines = [l.strip() for l in open(p, encoding="utf-8", errors="replace") if l.strip()]
    if len(lines) < n or ":" not in lines[n - 1]:
        sys.exit("No Zedge login for instance %d - add line %d to ZEDGE_ACCOUNTS "
                 "('email : password') in the config panel (Zedge section)." % (n, n))
    email, _, pw = lines[n - 1].partition(":")
    return email.strip(), pw.strip()


def fb(n, path, method="GET", data=None):
    url = "%s/%s.json" % (db_url(n), path)
    r = requests.request(method, url, json=data, timeout=60)
    if not r.ok:
        sys.exit("Firebase %s %s (instance %d) failed: HTTP %s %s"
                 % (method, path, n, r.status_code, r.text[:200]))
    try:
        return r.json()
    except ValueError:
        return None


def is_mp3_item(it):
    return bool(it.get("isMp3")) or (it.get("name") or "").lower().endswith(".mp3")


def dhaka_today():
    import datetime, zoneinfo
    d = datetime.datetime.now(zoneinfo.ZoneInfo("Asia/Dhaka"))
    return "%d/%d/%d" % (d.month, d.day, d.year)


def instance_status(n):
    state = fb(n, "uploadState") or {}
    q = fb(n, "wallpaperQueue") or {}
    items = [it for it in q.values() if isinstance(it, dict)] if isinstance(q, dict) else []
    by = {}
    for it in items:
        by.setdefault(it.get("status") or "?", []).append(it)
    queued = by.get("queued", [])
    qa = sum(1 for it in queued if is_mp3_item(it))
    qi = len(queued) - qa
    today = dhaka_today()
    fresh = state.get("lastUploadDate") == today
    day = state.get("uploadDayType") or "WALLPAPER"
    eff = day if fresh else ("WALLPAPER" if day == "AUDIO" else "AUDIO")
    if not state:
        eff = "AUDIO"  # very first run ever defaults to AUDIO day
    used = state.get("totalUploadsToday") or 0
    if not fresh:
        used = 0
    print("== Zedge %d ==  db: %s" % (n, db_url(n)))
    print("  today (%s): %s day | uploads used: %d/3 (%d left)"
          % (today, "AUDIO (ringtone)" if eff == "AUDIO" else "WALLPAPER (image)", used, 3 - used))
    print("  queue: %d queued (%d ringtones, %d wallpapers) | %d processing | %d failed"
          % (len(queued), qa, qi, len(by.get("processing", [])), len(by.get("failed", []))))
    need = qa if eff == "AUDIO" else qi
    if used < 3 and need == 0:
        print("  NOTE: nothing queued for today's %s day - add a %s first"
              % (eff, "mp3 ringtone" if eff == "AUDIO" else "jpg wallpaper"))


def cmd_status(a):
    for n in ([1, 2, 3] if a.all else [a.instance]):
        instance_status(n)


def cmd_queue(a):
    q = fb(a.instance, "wallpaperQueue") or {}
    rows = [(k, v) for k, v in q.items() if isinstance(v, dict)]
    rows.sort(key=lambda kv: kv[1].get("createdAt") or 0)
    flt = a.filter
    shown = 0
    for k, it in rows:
        st = it.get("status") or "?"
        if flt != "all" and st != flt:
            continue
        shown += 1
        kind = "AUDIO" if is_mp3_item(it) else "WALLP"
        meta = "meta:OK" if (it.get("title") and it.get("tags")) else "meta:EMPTY"
        line = "%s | %s | %-10s | %s | %s" % (k, kind, st, meta, it.get("name") or "?")
        if it.get("title"):
            line += " | title: %s" % it["title"]
        if st == "failed" and it.get("error"):
            line += " | error: %s" % str(it["error"])[:120]
        print(line)
    print("(%d item(s) shown, filter=%s, instance %d)" % (shown, flt, a.instance))


def _prepare_wallpaper(data, name):
    try:
        from PIL import Image
    except ImportError:
        if re.search(r"\.jpe?g$", name, re.I):
            print("WARNING: Pillow not installed - uploading jpg without "
                  "1620x2880 normalization (pip install pillow to fix)")
            return data, name
        sys.exit("Pillow is required to convert %s to jpg (pip install pillow)" % name)
    img = Image.open(io.BytesIO(data)).convert("RGB")
    tw, th = 1620, 2880
    scale = max(tw / float(img.width), th / float(img.height))
    sw, sh = int(img.width * scale + 0.5), int(img.height * scale + 0.5)
    img = img.resize((sw, sh), Image.LANCZOS)
    left, top = (sw - tw) // 2, (sh - th) // 2
    img = img.crop((left, top, left + tw, top + th))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=92)
    return buf.getvalue(), re.sub(r"\.(png|webp|jpeg)$", ".jpg", name, flags=re.I)


def _upload_r2(n, data, name, prefix, mime):
    key = "%s/%d_%s" % (prefix, int(time.time() * 1000), re.sub(r"[^a-zA-Z0-9.-]", "_", name))
    r = requests.post(worker_for(n), headers={"X-File-Name": key, "X-File-Type": mime},
                      data=data, timeout=300)
    if not r.ok:
        sys.exit("R2 upload failed: HTTP %s %s" % (r.status_code, r.text[:200]))
    return r.json()["url"]


def _fetch_source(src):
    if re.match(r"^https?://", src):
        r = requests.get(src, timeout=300)
        if not r.ok:
            sys.exit("Download failed: HTTP %s" % r.status_code)
        name = src.split("?")[0].rstrip("/").split("/")[-1] or "file"
        return r.content, name
    p = os.path.expanduser(src)
    if not os.path.isfile(p):
        sys.exit("File not found: %s (user uploads land in ~/.hermes/work/inbox/)" % src)
    return open(p, "rb").read(), os.path.basename(p)


def _queue_item(n, data, name, a):
    is_mp3 = name.lower().endswith(".mp3")
    if not is_mp3 and not re.search(r"\.(jpe?g|png|webp)$", name, re.I):
        sys.exit("Only jpg/jpeg/png/webp (wallpaper) or .mp3 (ringtone) can be queued: %s" % name)
    if not is_mp3:
        data, name = _prepare_wallpaper(data, name)
    mime = "audio/mpeg" if is_mp3 else "image/jpeg"
    url = _upload_r2(n, data, name, "zedge%d" % n, mime)
    payload = {
        "name": name, "type": mime, "size": len(data), "isMp3": is_mp3,
        "fileUrl": url,
        "title": getattr(a, "title", "") or "",
        "tags": getattr(a, "tags", "") or "",
        "category": (getattr(a, "category", "") or "").upper(),
        "description": getattr(a, "description", "") or "",
        "status": "queued",
        "createdAt": {".sv": "timestamp"},
    }
    if not is_mp3:
        payload["width"], payload["height"] = 1620, 2880
    res = fb(n, "wallpaperQueue", "POST", payload)
    kind = "ringtone" if is_mp3 else "wallpaper"
    print("Queued %s '%s' -> Zedge %d (id %s)" % (kind, name, n, (res or {}).get("name")))
    if not payload["title"] or not payload["tags"]:
        print("NOTE: title/tags empty - set them with: zedge edit <id> -i %d --title ... --tags ..." % n)


def cmd_add(a):
    data, name = _fetch_source(a.file)
    _queue_item(a.instance, data, name, a)


def cmd_distribute(a):
    n_idx = 0
    for f in a.files:
        data, name = _fetch_source(f)
        if name.lower().endswith(".mp3"):
            print("Skipping %s (distribute is for images; use zedge add for mp3)" % name)
            continue
        target = (n_idx % 3) + 1
        _queue_item(target, data, name, a)
        n_idx += 1
    print("Distributed %d image(s) round-robin across Zedge 1->2->3" % n_idx)


def cmd_edit(a):
    upd = {}
    if a.title is not None:
        upd["title"] = a.title
    if a.tags is not None:
        upd["tags"] = a.tags
    if a.category is not None:
        upd["category"] = a.category.upper()
    if a.description is not None:
        upd["description"] = a.description
    if not upd:
        sys.exit("Nothing to edit - pass --title/--tags/--category/--description")
    fb(a.instance, "wallpaperQueue/%s" % a.id, "PATCH", upd)
    print("Updated %s on Zedge %d: %s" % (a.id, a.instance, ", ".join(upd)))


def cmd_requeue(a):
    fb(a.instance, "wallpaperQueue/%s" % a.id, "PATCH",
       {"status": "queued", "error": None, "failedAt": None, "processingAt": None})
    print("Requeued %s on Zedge %d" % (a.id, a.instance))


def cmd_delete(a):
    it = fb(a.instance, "wallpaperQueue/%s" % a.id) or {}
    fb(a.instance, "wallpaperQueue/%s" % a.id, "DELETE")
    print("Deleted queue entry %s from Zedge %d" % (a.id, a.instance))
    file_url = it.get("fileUrl")
    if file_url:
        key = re.sub(r"^https?://[^/]+/", "", str(file_url)).split("?")[0]
        try:
            from urllib.parse import unquote
            key = unquote(key)
        except Exception:
            pass
        r = requests.delete(worker_for(a.instance), headers={"X-File-Name": key}, timeout=60)
        print("R2 file delete '%s': HTTP %s" % (key, r.status_code))


# ---------- local runner (inbuilt Playwright bot, no external repo) ----------

def _sh(cmd):
    return subprocess.call(cmd, shell=True, cwd=RT_DIR)


def _ensure_runtime():
    if shutil.which("node") is None:
        sys.exit("node is not installed on this machine - install Node.js first")
    os.makedirs(RT_DIR, exist_ok=True)
    mark = os.path.join(RT_DIR, ".pw-ready")
    if os.path.isfile(mark):
        return
    print("First run: installing Playwright chromium locally (~2 min, once only)...")
    if not os.path.isfile(os.path.join(RT_DIR, "package.json")):
        _sh("npm init -y >/dev/null 2>&1")
    if _sh("npm install playwright >/dev/null 2>&1") != 0:
        sys.exit("npm install playwright failed - check network/npm")
    if _sh("npx playwright install --with-deps chromium >/dev/null 2>&1") != 0:
        if _sh("npx playwright install chromium >/dev/null 2>&1") != 0:
            sys.exit("playwright chromium download failed")
    open(mark, "w").write("ok")
    print("Playwright ready.")


VPN_DIR = os.path.join(HOME, ".hermes", "zedge-vpn")


def _sudo(args):
    return subprocess.call(["sudo", "-n"] + args)


def _sudo_q(args):
    return subprocess.call(["sudo", "-n"] + args,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def vpn_path(n):
    p = os.path.join(VPN_DIR, "zedge%d.ovpn" % n)
    try:
        if os.path.isfile(p) and open(p, encoding="utf-8", errors="replace").read().strip():
            return p
    except OSError:
        pass
    return ""


def _vpn_auth_file(n):
    p = os.path.join(VPN_DIR, "auth.txt")
    if not os.path.isfile(p):
        return ""
    lines = [l.strip() for l in open(p, encoding="utf-8", errors="replace").read().splitlines()]
    ln = lines[n - 1] if len(lines) >= n else ""
    if not ln or ":" not in ln:
        return ""
    user, _, pw = ln.partition(":")
    ap = os.path.join(VPN_DIR, "zedge%d.auth" % n)
    open(ap, "w").write(user.strip() + "\n" + pw.strip() + "\n")
    os.chmod(ap, 0o600)
    return ap


def vpn_down(n):
    """Tear down the instance's VPN namespace (safe to call anytime)."""
    ns = "zedgevpn%d" % n
    pidf = "/tmp/%s.pid" % ns
    _sudo_q(["bash", "-c",
             "test -f {0} && kill $(cat {0}) 2>/dev/null; rm -f {0}".format(pidf)])
    _sudo_q(["ip", "netns", "del", ns])
    _sudo_q(["ip", "link", "del", "zv%dh" % n])
    _sudo_q(["iptables", "-t", "nat", "-D", "POSTROUTING",
             "-s", "10.219.%d.0/24" % n, "-j", "MASQUERADE"])


def vpn_up(n):
    """Start this instance's OpenVPN inside its OWN network namespace so ONLY
    the bot's browser traffic uses the tunnel. Returns the namespace name.
    Aborts (never falls back to direct) if the tunnel cannot be verified."""
    if shutil.which("openvpn") is None and _sudo(["apt-get", "install", "-y", "openvpn"]) != 0:
        sys.exit("openvpn is not installed and could not be installed (need sudo)")
    ns = "zedgevpn%d" % n
    host_if, peer_if = "zv%dh" % n, "zv%dp" % n
    host_ip, peer_ip = "10.219.%d.1" % n, "10.219.%d.2" % n
    vpn_down(n)  # clean slate
    steps = [
        ["ip", "netns", "add", ns],
        ["ip", "link", "add", host_if, "type", "veth", "peer", "name", peer_if],
        ["ip", "link", "set", peer_if, "netns", ns],
        ["ip", "addr", "add", host_ip + "/24", "dev", host_if],
        ["ip", "link", "set", host_if, "up"],
        ["ip", "netns", "exec", ns, "ip", "addr", "add", peer_ip + "/24", "dev", peer_if],
        ["ip", "netns", "exec", ns, "ip", "link", "set", peer_if, "up"],
        ["ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up"],
        ["ip", "netns", "exec", ns, "ip", "route", "add", "default", "via", host_ip],
        ["sysctl", "-qw", "net.ipv4.ip_forward=1"],
        ["iptables", "-t", "nat", "-A", "POSTROUTING",
         "-s", "10.219.%d.0/24" % n, "-j", "MASQUERADE"],
        ["mkdir", "-p", "/etc/netns/" + ns],
        ["bash", "-c", "printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'"
         " > /etc/netns/%s/resolv.conf" % ns],
    ]
    for c in steps:
        if _sudo(c) != 0:
            vpn_down(n)
            sys.exit("VPN namespace setup failed at: %s (root/sudo required)" % " ".join(c))
    ov = ["ip", "netns", "exec", ns, "openvpn", "--config", vpn_path(n),
          "--daemon", "--writepid", "/tmp/%s.pid" % ns, "--log", "/tmp/%s.log" % ns,
          "--connect-retry-max", "3", "--pull-filter", "ignore", "block-outside-dns"]
    auth = _vpn_auth_file(n)
    if auth:
        ov += ["--auth-user-pass", auth, "--auth-nocache"]
    if _sudo(ov) != 0:
        vpn_down(n)
        sys.exit("openvpn failed to start - check the .ovpn (log: /tmp/%s.log)" % ns)
    print("Zedge %d: connecting VPN in isolated namespace %s ..." % (n, ns))
    for _ in range(45):
        time.sleep(2)
        has_tun = subprocess.call(
            ["sudo", "-n", "ip", "netns", "exec", ns, "bash", "-c",
             "ip addr show 2>/dev/null | grep -q -E 'tun[0-9]|tap[0-9]'"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
        if not has_tun:
            continue
        chk = subprocess.run(
            ["sudo", "-n", "ip", "netns", "exec", ns, "curl", "-s",
             "--max-time", "12", "https://api.ipify.org"],
            capture_output=True, text=True)
        if chk.returncode == 0 and chk.stdout.strip():
            print("Zedge %d: VPN UP - exit IP %s (browser-only, host IP untouched)"
                  % (n, chk.stdout.strip()))
            return ns
    vpn_down(n)
    sys.exit("VPN tunnel did not come up within 90s - ABORTING, no direct "
             "fallback (check .ovpn/auth; log: /tmp/%s.log)" % ns)


def proxy_for(n, a):
    """Proxy for instance n: per-run flags win, else line n of
    ~/.hermes/zedge-proxies.txt. Line formats: host:port |
    scheme://user:pass@host:port | host:port|user|pass. Empty/"-" = direct."""
    if a.proxy_server:
        return a.proxy_server, a.proxy_user or "", a.proxy_pass or ""
    p = os.path.join(HOME, ".hermes", "zedge-proxies.txt")
    lines = []
    if os.path.isfile(p):
        lines = [l.strip() for l in open(p, encoding="utf-8", errors="replace").read().splitlines()]
    ln = lines[n - 1] if len(lines) >= n else ""
    if not ln or ln.lower() in ("-", "none", "direct"):
        return "", "", ""
    if "|" in ln:
        parts = [x.strip() for x in ln.split("|")]
        while len(parts) < 3:
            parts.append("")
        return parts[0], parts[1], parts[2]
    if "@" in ln and "://" in ln:
        from urllib.parse import urlparse, unquote
        u = urlparse(ln)
        server = "%s://%s" % (u.scheme, u.hostname) + ((":%d" % u.port) if u.port else "")
        return server, unquote(u.username or ""), unquote(u.password or "")
    return ln, "", ""


def _run_one(n, a):
    email, pw = account(n)
    pxy_s, pxy_u, pxy_p = proxy_for(n, a)
    use_vpn = bool(vpn_path(n)) and not a.no_vpn and not a.proxy_server
    _ensure_runtime()
    bot_src = os.path.join(SCRIPT_DIR, "zedge_bot.js")
    if not os.path.isfile(bot_src):
        sys.exit("zedge_bot.js is missing next to this tool - re-run the Hermes setup")
    bot = os.path.join(RT_DIR, "zedge_bot.js")
    shutil.copyfile(bot_src, bot)  # run from RT_DIR so require('playwright') resolves
    if use_vpn and pxy_s:
        print("Zedge %d: both .ovpn and proxy configured - VPN wins, proxy ignored" % n)
        pxy_s = pxy_u = pxy_p = ""
    env = dict(os.environ)
    env.update({
        "ZEDGE_EMAIL": email, "ZEDGE_PASSWORD": pw,
        "HEADLESS": a.headless, "TOTAL_PROFILES": a.profiles,
        "UA_GROUP": a.ua, "FOLDER_NAME": "Zedge %d" % n,
        "FIREBASE_DB_URL": db_url(n),
        "R2_WORKER_URL": worker_for(n),
        "PROXY_SERVER": pxy_s, "PROXY_USER": pxy_u, "PROXY_PASS": pxy_p,
    })
    cmd = ["node", bot]
    ns = ""
    if use_vpn:
        ns = vpn_up(n)  # ONLY this namespace (= only the bot) uses the tunnel
        me = os.environ.get("USER") or os.environ.get("LOGNAME") or "runner"
        keep = ["ZEDGE_EMAIL", "ZEDGE_PASSWORD", "HEADLESS", "TOTAL_PROFILES",
                "UA_GROUP", "FOLDER_NAME", "FIREBASE_DB_URL", "R2_WORKER_URL",
                "PROXY_SERVER", "PROXY_USER", "PROXY_PASS"]
        cmd = (["sudo", "-n", "ip", "netns", "exec", ns,
                "sudo", "-n", "-u", me, "env",
                "HOME=%s" % HOME, "PATH=%s" % os.environ.get("PATH", "/usr/bin:/bin")]
               + ["%s=%s" % (k, env[k]) for k in keep] + ["node", bot])
    os.makedirs(LOG_DIR, exist_ok=True)
    log = os.path.join(LOG_DIR, "zedge-run-%d-%d.log" % (n, int(time.time())))
    lf = open(log, "w", encoding="utf-8", errors="replace")
    via = "VPN (browser-only netns)" if use_vpn else (pxy_s if pxy_s else "direct")
    print("Zedge %d: starting LOCAL upload bot (headless=%s, network=%s) | log: %s"
          % (n, a.headless, via, log))
    proc = subprocess.Popen(cmd, cwd=RT_DIR, env=env,
                            stdout=lf, stderr=subprocess.STDOUT,
                            start_new_session=bool(a.bg))
    if a.bg:
        print("Running in background (pid %d). A run takes ~5-15 min - "
              "check progress with: zedge runs -i %d" % (proc.pid, n))
        if use_vpn:
            print("NOTE: the VPN namespace stays up for this run; after it "
                  "finishes, close with: zedge vpn down -i %d" % n)
        return
    rc = proc.wait()
    lf.close()
    if use_vpn:
        vpn_down(n)
    tail = open(log, encoding="utf-8", errors="replace").read().splitlines()[-25:]
    print("\n".join(tail))
    print("Zedge %d finished with exit code %d (full log: %s)" % (n, rc, log))


def cmd_run(a):
    ns_list = [1, 2, 3] if a.all else [a.instance]
    if len(ns_list) > 1:
        seen = {}
        for n in ns_list:
            if not a.no_vpn and not a.proxy_server and vpn_path(n):
                key = "vpn:%d" % n  # own tunnel - never shared
            else:
                key = proxy_for(n, a)[0]
            seen.setdefault(key, []).append(n)
        for s, grp in seen.items():
            if len(grp) > 1 and s:
                print("WARNING: instances %s share the SAME proxy (%s) - Zedge "
                      "can link & suspend these accounts! Give each account its "
                      "own ZEDGE_PROXIES line or its own .ovpn." % (grp, s))
            elif len(grp) > 1:
                print("WARNING: instances %s all run WITHOUT a proxy/VPN (same "
                      "machine IP) - account-linking risk. Set one proxy per "
                      "line in ZEDGE_PROXIES or one .ovpn per instance." % (grp,))
    for n in ns_list:
        _run_one(n, a)


def cmd_vpn(a):
    n = a.instance
    if a.action == "down":
        vpn_down(n)
        print("VPN namespace for Zedge %d removed" % n)
        return
    if a.action == "up":
        if not vpn_path(n):
            sys.exit("No .ovpn saved for instance %d - paste it into ZEDGE_OVPN_%d "
                     "in the config panel (Zedge section)." % (n, n))
        vpn_up(n)
        return
    nsname = "zedgevpn%d" % n
    r = subprocess.run(["sudo", "-n", "ip", "netns", "exec", nsname, "curl", "-s",
                        "--max-time", "10", "https://api.ipify.org"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        print("Zedge %d VPN: UP (namespace %s, exit IP %s)" % (n, nsname, r.stdout.strip()))
    else:
        print("Zedge %d VPN: DOWN (.ovpn %s)" % (n, "saved" if vpn_path(n) else "NOT saved"))


def cmd_runs(a):
    pat = os.path.join(LOG_DIR, "zedge-run-%d-*.log" % a.instance)
    logs = sorted(glob.glob(pat), reverse=True)[:a.limit]
    if not logs:
        print("No local runs yet for Zedge %d - start one with: zedge run -i %d --bg"
              % (a.instance, a.instance))
        return
    for i, lg in enumerate(logs):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(lg)))
        print("== %s (updated %s) ==" % (os.path.basename(lg), ts))
        lines = open(lg, encoding="utf-8", errors="replace").read().splitlines()
        for ln in lines[-(a.tail if i == 0 else 5):]:
            print("  " + ln)


def main():
    ap = argparse.ArgumentParser(prog="zedge",
        description="Control the Zedge wallpaper/ringtone pipelines (instances 1-3, runs locally)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def inst(p):
        p.add_argument("-i", "--instance", type=int, choices=[1, 2, 3], default=1)

    p = sub.add_parser("status", help="day type, uploads left, queue counts")
    inst(p)
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("queue", help="list queue items")
    inst(p)
    p.add_argument("--filter", default="all",
                   choices=["all", "queued", "processing", "failed", "done"])
    p.set_defaults(fn=cmd_queue)

    p = sub.add_parser("add", help="queue a wallpaper (jpg/png/webp) or ringtone (mp3)")
    p.add_argument("file")
    inst(p)
    for f in ("title", "tags", "category", "description"):
        p.add_argument("--" + f, default="")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("distribute", help="round-robin images across instances 1->2->3")
    p.add_argument("files", nargs="+")
    for f in ("title", "tags", "category", "description"):
        p.add_argument("--" + f, default="")
    p.set_defaults(fn=cmd_distribute)

    p = sub.add_parser("edit", help="edit metadata of a queue item")
    p.add_argument("id")
    inst(p)
    for f in ("title", "tags", "category", "description"):
        p.add_argument("--" + f, default=None)
    p.set_defaults(fn=cmd_edit)

    p = sub.add_parser("requeue", help="set a failed/stuck item back to queued")
    p.add_argument("id")
    inst(p)
    p.set_defaults(fn=cmd_requeue)

    p = sub.add_parser("delete", help="delete a queue item (and its R2 file)")
    p.add_argument("id")
    inst(p)
    p.set_defaults(fn=cmd_delete)

    p = sub.add_parser("run", help="run the inbuilt Playwright upload bot on THIS machine")
    inst(p)
    p.add_argument("--all", action="store_true")
    p.add_argument("--bg", action="store_true", help="run in background (recommended)")
    p.add_argument("--no-vpn", action="store_true",
                   help="ignore the saved .ovpn for this run")
    p.add_argument("--headless", default="true", choices=["true", "false"])
    p.add_argument("--profiles", default="3")
    p.add_argument("--ua", default="random")
    p.add_argument("--proxy-server", default="")
    p.add_argument("--proxy-user", default="")
    p.add_argument("--proxy-pass", default="")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("vpn", help="browser-only OpenVPN control (netns + .ovpn)")
    p.add_argument("action", choices=["up", "down", "status"])
    inst(p)
    p.set_defaults(fn=cmd_vpn)

    p = sub.add_parser("runs", help="recent local run logs / progress")
    inst(p)
    p.add_argument("--limit", type=int, default=3)
    p.add_argument("--tail", type=int, default=25)
    p.set_defaults(fn=cmd_runs)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
