#!/usr/bin/env python3
"""Inbuilt screen capture for the shared virtual desktop (DISPLAY :99).

    cap shot [--out FILE]          take a full-screen .png screenshot
    cap clip SECONDS [--fps 12]    record N seconds -> .mp4 (blocks)
    cap start [--fps 12]           start a background recording
    cap stop                       stop + finalize, prints the .mp4 path
    cap status                     running? file, elapsed, size + recent files

Files are saved in ~/.hermes/work/captures/ - send them to the user in chat.
"""
import argparse
import os
import shutil
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DISPLAY = os.environ.get("DISPLAY") or ":99"
OUT_DIR = os.path.join(HOME, ".hermes", "work", "captures")
PID_FILE = "/tmp/screenrec.pid"
META_FILE = "/tmp/screenrec.meta"
LOG_FILE = "/tmp/screenrec.log"


def _env():
    e = dict(os.environ)
    e["DISPLAY"] = DISPLAY
    return e


def _size():
    try:
        o = subprocess.run(["xdotool", "getdisplaygeometry"],
                           capture_output=True, text=True, env=_env(),
                           timeout=10).stdout.split()
        return "%sx%s" % (o[0], o[1])
    except Exception:
        return "1920x1080"


def _need_ffmpeg():
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg is not installed - run: sudo apt-get install -y ffmpeg")


def _ffcmd(out, fps, dur=None):
    c = ["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab",
         "-video_size", _size(), "-framerate", str(fps), "-i", DISPLAY]
    if dur:
        c += ["-t", str(dur)]
    c += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
          "-movflags", "+faststart", out]
    return c


def _pid():
    try:
        return int(open(PID_FILE).read().strip())
    except Exception:
        return 0


def _alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _meta():
    try:
        lines = open(META_FILE).read().splitlines()
        return lines[0], int(lines[1])
    except Exception:
        return "", int(time.time())


def cmd_shot(a):
    os.makedirs(OUT_DIR, exist_ok=True)
    out = a.out or os.path.join(OUT_DIR, "shot-%d.png" % int(time.time()))
    if shutil.which("scrot"):
        rc = subprocess.call(["scrot", "-z", "-o", out], env=_env())
    else:
        _need_ffmpeg()
        rc = subprocess.call(_ffcmd(out, 1, None)[:-1] + ["-frames:v", "1", out],
                             env=_env())
    if rc == 0 and os.path.isfile(out):
        print("Screenshot saved: %s (%d KB, display %s)"
              % (out, os.path.getsize(out) // 1024, DISPLAY))
    else:
        sys.exit("screenshot failed (exit %d) - is display %s up?" % (rc, DISPLAY))


def cmd_clip(a):
    _need_ffmpeg()
    os.makedirs(OUT_DIR, exist_ok=True)
    sec = max(1, min(int(a.seconds), 600))
    out = a.out or os.path.join(OUT_DIR, "clip-%d.mp4" % int(time.time()))
    print("Recording display %s for %d seconds (%d fps)..." % (DISPLAY, sec, a.fps))
    rc = subprocess.call(_ffcmd(out, a.fps, sec), env=_env())
    if rc == 0 and os.path.isfile(out):
        print("Recording saved: %s (%d KB, %d seconds)"
              % (out, os.path.getsize(out) // 1024, sec))
    else:
        sys.exit("recording failed (exit %d)" % rc)


def cmd_start(a):
    _need_ffmpeg()
    if _alive(_pid()):
        sys.exit("a recording is already running - stop it first: cap stop")
    os.makedirs(OUT_DIR, exist_ok=True)
    out = a.out or os.path.join(OUT_DIR, "rec-%d.mp4" % int(time.time()))
    lf = open(LOG_FILE, "w")
    p = subprocess.Popen(_ffcmd(out, a.fps), env=_env(),
                         stdout=lf, stderr=subprocess.STDOUT,
                         start_new_session=True)
    time.sleep(1.5)
    if not _alive(p.pid):
        sys.exit("ffmpeg exited immediately - check %s" % LOG_FILE)
    open(PID_FILE, "w").write(str(p.pid))
    open(META_FILE, "w").write("%s\n%d\n" % (out, int(time.time())))
    print("Recording started (pid %d, %d fps) -> %s" % (p.pid, a.fps, out))
    print("Stop with: cap stop")


def cmd_stop(a):
    pid = _pid()
    if not _alive(pid):
        sys.exit("no recording is running")
    out, t0 = _meta()
    os.kill(pid, signal.SIGINT)  # lets ffmpeg finalize the mp4 cleanly
    for _ in range(30):
        if not _alive(pid):
            break
        time.sleep(0.5)
    if _alive(pid):
        os.kill(pid, signal.SIGTERM)
        time.sleep(1)
    for f in (PID_FILE, META_FILE):
        try:
            os.remove(f)
        except OSError:
            pass
    if out and os.path.isfile(out):
        print("Recording saved: %s (%d KB, %d seconds)"
              % (out, os.path.getsize(out) // 1024, int(time.time()) - t0))
    else:
        sys.exit("recording file missing - check %s" % LOG_FILE)


def cmd_status(a):
    pid = _pid()
    if _alive(pid):
        out, t0 = _meta()
        size = os.path.getsize(out) // 1024 if out and os.path.isfile(out) else 0
        print("RECORDING (pid %d) -> %s | %d seconds so far | %d KB"
              % (pid, out, int(time.time()) - t0, size))
    else:
        print("no recording running")
    if os.path.isdir(OUT_DIR):
        caps = sorted(os.listdir(OUT_DIR))
        if caps:
            print("saved captures in %s:" % OUT_DIR)
            for f in caps[-8:]:
                print("  " + f)


def main():
    ap = argparse.ArgumentParser(prog="cap",
        description="Screenshot / screen-record the shared virtual desktop (:99)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("shot", help="full-screen .png screenshot")
    p.add_argument("--out", default="")
    p.set_defaults(fn=cmd_shot)

    p = sub.add_parser("clip", help="record N seconds -> .mp4 (blocks)")
    p.add_argument("seconds", type=int)
    p.add_argument("--fps", type=int, default=12)
    p.add_argument("--out", default="")
    p.set_defaults(fn=cmd_clip)

    p = sub.add_parser("start", help="start a background recording")
    p.add_argument("--fps", type=int, default=12)
    p.add_argument("--out", default="")
    p.set_defaults(fn=cmd_start)

    p = sub.add_parser("stop", help="stop + finalize the background recording")
    p.set_defaults(fn=cmd_stop)

    p = sub.add_parser("status", help="recording status + recent captures")
    p.set_defaults(fn=cmd_status)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
