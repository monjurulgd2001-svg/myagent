"""
Hermesa Bot - Python integration
================================
Send messages, images, files and VOICE CALLS to the Hermesa Android app.

Setup: nothing - uses requests if installed, plain urllib otherwise.

1. Open Hermesa app -> select your bot -> PC Integration / Code Snippets
   and copy your BOT ID.
2. Save the Bot ID once in the Hermes config panel (HERMESA_BOT_ID) -
   the workflow writes it into ~/.hermes/.env automatically.
3. Run:  python3 hermesa_bot.py text "hello"
"""

import base64
import os
import time

try:
    import requests
except ImportError:  # urllib fallback - works even without requests installed
    import json as _json
    import urllib.error as _ue
    import urllib.request as _ur

    class _Resp:
        def __init__(self, r):
            self.status_code = getattr(r, "status", None) or getattr(r, "code", 0)
            self.text = r.read().decode("utf-8", "replace")

        def raise_for_status(self):
            if self.status_code >= 400:
                raise RuntimeError("HTTP %d: %s" % (self.status_code, self.text[:200]))

    class _RequestsShim:
        @staticmethod
        def post(url, json=None, timeout=30):
            req = _ur.Request(url, data=_json.dumps(json).encode(),
                              headers={"Content-Type": "application/json"})
            try:
                return _Resp(_ur.urlopen(req, timeout=timeout))
            except _ue.HTTPError as e:
                return _Resp(e)

    requests = _RequestsShim()

# ======================= CONFIG =======================
def _cfg(name: str, default: str = "") -> str:
    """Read config from ~/.hermes/.env FIRST (kept fresh by vault_sync.py,
    so panel changes apply live), falling back to the process environment."""
    try:
        with open(os.path.expanduser("~/.hermes/.env")) as fh:
            for line in fh:
                if line.startswith(name + "="):
                    fv = line.split("=", 1)[1].strip()
                    if fv:
                        return fv
    except OSError:
        pass
    v = os.environ.get(name, "").strip()
    if v:
        return v
    return default


# No baked-in backend: the user sets HERMESA_DB_URL + HERMESA_BOT_ID once in
# the config panel; the workflow writes them into ~/.hermes/.env. Empty = not
# configured, and _post() errors clearly instead of hitting a stranger's DB.
BOT_ID = _cfg("HERMESA_BOT_ID", "")
DATABASE_URL = _cfg("HERMESA_DB_URL", "").rstrip("/")
WEBHOOK_URL = f"{DATABASE_URL}/bots/{BOT_ID}/messages.json"
# =======================================================


def _now_ms() -> int:
    return int(time.time() * 1000)


def _post(payload: dict) -> None:
    if not DATABASE_URL or not BOT_ID:
        raise SystemExit("Hermesa not configured - set HERMESA_DB_URL and "
                         "HERMESA_BOT_ID in the config panel before sending.")
    # Big Base64 payloads (screenshots) need a generous timeout.
    res = requests.post(WEBHOOK_URL, json=payload, timeout=120)
    print(f"[{payload['type']}] HTTP {res.status_code} -> {res.text[:100]}")
    res.raise_for_status()


MAX_INLINE_BYTES = 2_500_000   # keep Base64 uploads fast and well under RTDB limits
HARD_CAP_BYTES = 9_000_000     # matches the app-side parser limit


def _human_size(n: int) -> str:
    return "%.1f KB" % (n / 1024) if n < 1_000_000 else "%.1f MB" % (n / 1e6)


def _shrink_image(path: str):
    """Return (bytes, ext) for an image, auto-compressing big files so
    screenshots always go through Firebase RTDB reliably."""
    with open(path, "rb") as f:
        raw = f.read()
    ext = os.path.splitext(path)[1].lstrip(".").lower() or "png"
    if len(raw) <= MAX_INLINE_BYTES:
        return raw, ext
    try:
        import io
        from PIL import Image  # pip install pillow
    except ImportError:
        if len(raw) > HARD_CAP_BYTES:
            raise SystemExit(
                "Image is %s - too big to inline and Pillow is not installed. "
                "Run: pip install pillow  (or send an https:// URL instead)."
                % _human_size(len(raw)))
        return raw, ext
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    quality, scale, data = 80, 1.0, raw
    for _ in range(10):
        w = max(int(img.width * scale), 1)
        h = max(int(img.height * scale), 1)
        buf = io.BytesIO()
        img.resize((w, h)).save(buf, "JPEG", quality=quality)
        data = buf.getvalue()
        if len(data) <= MAX_INLINE_BYTES:
            break
        scale *= 0.8
        quality = max(45, quality - 7)
    print("compressed image %s -> %s" % (_human_size(len(raw)), _human_size(len(data))))
    return data, "jpg"


def send_message(text: str, level: str = "info") -> None:
    """Send a plain text message. level: info | success | warning | error"""
    _post({
        "sender": "bot",
        "text": text,
        "type": "text",
        "level": level,
        "timestamp": _now_ms(),
    })


def send_image(image_url_or_path: str, text: str = "Image", file_name: str = "image.png") -> None:
    """Send an image. Accepts an https:// URL or a local file path
    (auto Base64, auto-compressed when it is a big screenshot)."""
    image_url = image_url_or_path
    if os.path.isfile(image_url_or_path):
        data, ext = _shrink_image(image_url_or_path)
        b64 = base64.b64encode(data).decode()
        image_url = f"data:image/{ext};base64,{b64}"
        file_name = os.path.basename(image_url_or_path)
    _post({
        "sender": "bot",
        "text": text,
        "type": "image",
        "imageUrl": image_url,
        "fileName": file_name,
        "timestamp": _now_ms(),
    })


def send_file(file_url: str, file_name: str = "file.bin", file_size: str = "", text: str = "File", level: str = "info") -> None:
    """Send a file attachment. Accepts an https:// URL or a LOCAL file path
    (embedded as Base64 automatically - this used to silently fail)."""
    if os.path.isfile(file_url):
        with open(file_url, "rb") as f:
            raw = f.read()
        if len(raw) > HARD_CAP_BYTES:
            raise SystemExit(
                "File is %s - over the 9 MB inline limit. Host it somewhere "
                "and send an https:// URL instead." % _human_size(len(raw)))
        file_name = os.path.basename(file_url)
        if not file_size:
            file_size = _human_size(len(raw))
        b64 = base64.b64encode(raw).decode()
        file_url = f"data:application/octet-stream;base64,{b64}"
    _post({
        "sender": "bot",
        "text": text,
        "type": "file",
        "fileUrl": file_url,
        "fileName": file_name,
        "fileSize": file_size,
        "level": level,
        "timestamp": _now_ms(),
    })


def trigger_voice_call(audio_url_or_path: str,
                       text: str = "Incoming Voice Call",
                       file_name: str = "voice_alert.mp3",
                       duration: str = "00:45") -> None:
    """Ring the phone with a FULL-SCREEN CALL that plays an mp3/wav.

    Accepts an https:// URL to an audio file, or a local .mp3/.wav path
    (embedded as Base64 automatically).
    """
    audio_url = audio_url_or_path
    if os.path.isfile(audio_url_or_path):
        ext = os.path.splitext(audio_url_or_path)[1].lstrip(".").lower() or "mp3"
        with open(audio_url_or_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        audio_url = f"data:audio/{ext};base64,{b64}"
        file_name = os.path.basename(audio_url_or_path)
    _post({
        "sender": "bot",
        "text": text,
        "type": "voice_call",
        "audioUrl": audio_url,
        "audioFileName": file_name,
        "audioDuration": duration,
        "level": "info",
        "timestamp": _now_ms(),
    })


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(
        description="Send notifications / images / files / voice calls to the Hermesa Android app")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("text", help="send a text message")
    p.add_argument("message")
    p.add_argument("--level", default="info",
                   choices=["info", "success", "warning", "error"])

    p = sub.add_parser("image", help="send an image (https URL or local path)")
    p.add_argument("image")
    p.add_argument("--text", default="Image")
    p.add_argument("--name", default="image.png")
    p.add_argument("--level", default="info",
                   choices=["info", "success", "warning", "error"],
                   help="accepted for CLI consistency (images render the same)")

    p = sub.add_parser("file", help="send a file (https URL or local path)")
    p.add_argument("url")
    p.add_argument("--name", default="file.bin")
    p.add_argument("--size", default="")
    p.add_argument("--text", default="File")
    p.add_argument("--level", default="info",
                   choices=["info", "success", "warning", "error"])

    p = sub.add_parser("call", help="RING the phone: full-screen voice call (mp3/wav URL or local path)")
    p.add_argument("audio")
    p.add_argument("--text", default="Incoming Voice Call")
    p.add_argument("--duration", default="00:45")
    p.add_argument("--level", default="info",
                   choices=["info", "success", "warning", "error"],
                   help="accepted for CLI consistency (calls always ring)")

    a = ap.parse_args()
    if not BOT_ID or BOT_ID == "PASTE_YOUR_BOT_ID_HERE":
        raise SystemExit("HERMESA_BOT_ID is not set - ask the user to set it "
                         "in the Hermes config panel (Hermesa section)")
    if a.cmd == "text":
        send_message(a.message, level=a.level)
    elif a.cmd == "image":
        send_image(a.image, text=a.text, file_name=a.name)
    elif a.cmd == "file":
        send_file(a.url, file_name=a.name, file_size=a.size, text=a.text, level=a.level)
    elif a.cmd == "call":
        trigger_voice_call(a.audio, text=a.text, duration=a.duration)
