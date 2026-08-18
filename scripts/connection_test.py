#!/usr/bin/env python3
"""Standalone VPN + proxy connection tester (dispatched from the config panel).

Browsers cannot open VPN/proxy sockets, so the REAL test runs here on a
GitHub runner. Results are published live to Firebase runtime/<uid>/conntest
and the config panel renders them as they stream in.

- Proxies: every non-empty ZEDGE_PROXIES line is dialed with curl and the
  exit IP + latency is reported.
- VPN: every configured zedgeN.conf (WireGuard) is brought up in a network namespace
  via zedge_tool.py (EXACTLY like the agent uses it at runtime, including
  the Docker FORWARD fix), then the exit IP through the tunnel is checked.

No baked-in endpoints. Always exits 0 - failures are reported in the JSON,
never as a crashed job.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
VPN_DIR = os.path.join(HOME, ".hermes", "zedge-vpn")
ZEDGE_TOOL = os.path.abspath(os.path.join(
    HERE, "..", "skills", "zedge-automation", "scripts", "zedge_tool.py"))


def env(k):
    return (os.environ.get(k) or "").strip()


def publish(payload):
    """PATCH runtime/<uid>.conntest via the existing fbpub.py publisher."""
    try:
        subprocess.run([sys.executable, os.path.join(HERE, "fbpub.py"),
                        "conntest=" + json.dumps(payload)],
                       timeout=60, check=False)
    except Exception as e:
        print("publish failed: %s" % e)


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ss" % timeout
    except Exception as e:
        return 1, str(e)


def curl_ip(extra=None, netns=""):
    cmd = ["curl", "-4", "-s", "--max-time", "25"] + (extra or []) \
        + ["https://api.ipify.org"]
    if netns:
        cmd = ["sudo", "ip", "netns", "exec", netns] + cmd
    t0 = time.time()
    code, out = run(cmd, timeout=40)
    ms = int((time.time() - t0) * 1000)
    ip = out.strip().splitlines()[-1].strip() if out.strip() else ""
    ok = code == 0 and re.fullmatch(r"[0-9.]{7,15}", ip) is not None
    return ok, (ip if ok else ""), ms, ("" if ok else out.strip()[-300:])


def parse_proxy(ln):
    """Formats the panel accepts: empty/'-' = direct (skip), 'host:port',
    'host:port | user | pass', 'scheme://user:pass@host:port'."""
    ln = (ln or "").strip()
    if not ln or ln == "-":
        return None
    if "|" in ln:
        parts = [p.strip() for p in ln.split("|")]
        return (parts[0],
                parts[1] if len(parts) > 1 else "",
                parts[2] if len(parts) > 2 else "")
    return ln, "", ""


report = {"status": "running", "startedAt": int(time.time() * 1000),
          "proxies": [], "vpns": []}
publish(report)

ok, ip, ms, _err = curl_ip()
report["runnerIp"] = ip
print("Runner direct IP: %s (%d ms)" % (ip or "unknown", ms))

# ---- proxies (line N = instance N) ----
for i, ln in enumerate(env("ZEDGE_PROXIES").splitlines(), 1):
    px = parse_proxy(ln)
    if px is None:
        continue
    server, user, pw = px
    extra = ["-x", server]
    if user:
        extra += ["--proxy-user", "%s:%s" % (user, pw)]
    ok, ip, ms, err = curl_ip(extra)
    item = {"n": i, "server": server, "ok": ok, "ms": ms}
    if ok:
        item["exitIp"] = ip
        item["sameAsRunner"] = bool(report["runnerIp"]) and ip == report["runnerIp"]
    else:
        item["error"] = err or "no response"
    report["proxies"].append(item)
    print("proxy %d (%s): %s" % (i, server,
          ("OK " + ip) if ok else ("FAIL " + item.get("error", ""))))
    publish(report)

# ---- WireGuard configs: REAL end-to-end netns test via zedge_tool.py ----
for n in (1, 2, 3):
    cfg = os.path.join(VPN_DIR, "zedge%d.conf" % n)
    if not (os.path.isfile(cfg) and os.path.getsize(cfg) > 50):
        continue
    print("VPN %d: bringing the tunnel up in a netns..." % n)
    t0 = time.time()
    code, out = run(["python3", ZEDGE_TOOL, "vpn", "up", "-i", str(n)],
                    timeout=240)
    item = {"n": n, "ok": False, "ms": int((time.time() - t0) * 1000)}
    if code == 0:
        ok, ip, ms, err = curl_ip(netns="zedgevpn%d" % n)
        item["ok"] = ok
        item["ms"] = int((time.time() - t0) * 1000)
        if ok:
            item["exitIp"] = ip
            item["sameAsRunner"] = (bool(report["runnerIp"])
                                    and ip == report["runnerIp"])
        else:
            item["error"] = ("tunnel up but no internet through it: "
                             + (err or "no response"))
    else:
        item["error"] = out.strip()[-600:] or "vpn up failed"
    run(["python3", ZEDGE_TOOL, "vpn", "down", "-i", str(n)], timeout=90)
    report["vpns"].append(item)
    print("VPN %d: %s" % (n, ("OK " + item.get("exitIp", ""))
                          if item["ok"] else "FAIL"))
    publish(report)

report["status"] = "done"
report["finishedAt"] = int(time.time() * 1000)
publish(report)
print("DONE - report published to the panel (runtime/<uid>/conntest)")
