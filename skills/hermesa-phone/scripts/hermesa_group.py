#!/usr/bin/env python3
"""hermesa-group: interact with the Pulse Messenger group chat system.

The app now ships with a BUILT-IN group server (Firebase RTDB), so no
per-user database setup is needed. Users sign up in the app, can create
many groups, and each user's bot joins the groups its owner belongs to as
member id "bot:<ownerUid>".

Environment:
  HERMESA_GROUP_DB_URL        optional override of the built-in server URL
  HERMESA_GROUP_USER_ID       the owner's uid (from the app's bot settings)
  HERMESA_GROUP_BOT_NAME      display name for the bot (default: Hermes)
  HERMESA_GROUP_DEFAULT_GROUP default group id (default: global)

Usage:
  hermesa-group text "message" [--group GID] [--reply-to MSG_ID]
  hermesa-group task "task description" [--group GID]
  hermesa-group file <path> [caption] [--group GID]
  hermesa-group image <path> [caption] [--group GID]
  hermesa-group pin <messageId> [off] [--group GID]
  hermesa-group history [n] [--group GID]
  hermesa-group groups                # groups the owner (and the bot) belongs to
  hermesa-group members [--group GID] # member list of one group
  hermesa-group users                 # everyone on the built-in server

Private messages (user-to-user DM threads):
  hermesa-group dm <userIdOrName> "message"        [--reply-to MSG_ID]
  hermesa-group dm-file  <userIdOrName> <path> [caption]
  hermesa-group dm-image <userIdOrName> <path> [caption]
  hermesa-group dm-voice <userIdOrName> <audioPath> [caption]  # playable voice note (e.g. TTS audio)
  hermesa-group dms                   # list the owner's private chat threads
  hermesa-group dm-history <userIdOrName> [n]
"""

import base64
import json
import mimetypes
import os
import sys
import time
import urllib.request

DEFAULT_GROUP_DB_URL = "https://softizence-default-rtdb.firebaseio.com"
MAX_CHUNK = 3500


def env(name, default=""):
    v = (os.environ.get(name) or "").strip()
    if v:
        return v
    # Fallback: read ~/.hermes/.env so the CLI still works when the shell
    # session did not export the config-panel variables.
    try:
        with open(os.path.expanduser("~/.hermes/.env")) as fh:
            for line in fh:
                if line.startswith(name + "="):
                    fv = line.split("=", 1)[1].strip()
                    if fv:
                        return fv
    except OSError:
        pass
    return default


def db_url():
    return env("HERMESA_GROUP_DB_URL", DEFAULT_GROUP_DB_URL).rstrip("/")


def owner_id():
    uid = env("HERMESA_GROUP_USER_ID")
    if not uid:
        print("ERROR: HERMESA_GROUP_USER_ID is not set (copy it from the app's bot settings)", file=sys.stderr)
        sys.exit(2)
    return uid


def bot_name():
    return env("HERMESA_GROUP_BOT_NAME", "Hermes")


def default_group():
    return env("HERMESA_GROUP_DEFAULT_GROUP", "global")


def http(method, url, payload=None):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    # Generous timeout: Base64 screenshots/files can be several MB.
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body) if body else None


def get(path, query=""):
    url = "%s/%s.json%s" % (db_url(), path, ("?" + query) if query else "")
    return http("GET", url)


def post_message(gid, extra):
    owner = owner_id()
    msg = {
        "senderId": "bot:%s" % owner,
        "senderName": bot_name(),
        "senderIsBot": True,
        "ownerId": owner,
        "text": "",
        "type": "text",
        "pinned": False,
        "timestamp": {".sv": "timestamp"},
    }
    msg.update(extra)
    res = http("POST", "%s/group/messages/%s.json" % (db_url(), gid), msg)
    key = (res or {}).get("name")
    if key:
        http("PATCH", "%s/group/messages/%s/%s.json" % (db_url(), gid, key), {"id": key})
    return key


def send_text(gid, text, reply_to=None):
    reply_extra = {}
    if reply_to:
        orig = get("group/messages/%s/%s" % (gid, reply_to)) or {}
        reply_extra = {
            "replyToId": reply_to,
            "replyToText": (orig.get("text") or orig.get("fileName") or "")[:80],
            "replyToSender": orig.get("senderName") or "",
        }
    chunks = [text[i:i + MAX_CHUNK] for i in range(0, len(text), MAX_CHUNK)] or [""]
    keys = []
    for i, chunk in enumerate(chunks):
        extra = {"text": chunk}
        if i == 0:
            extra.update(reply_extra)
        keys.append(post_message(gid, extra))
    return keys


def human_size(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return "%.0f %s" % (n, unit) if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024.0


MAX_INLINE = 2_500_000  # keep Base64 uploads fast and reliable over RTDB


def _shrink_image_bytes(path):
    """Auto-compress big images (screenshots) so they always upload."""
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) <= MAX_INLINE:
        return raw, mimetypes.guess_type(path)[0] or "image/png"
    try:
        import io
        from PIL import Image  # pip install pillow
    except ImportError:
        return raw, mimetypes.guess_type(path)[0] or "image/png"
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    quality, scale, data = 80, 1.0, raw
    for _ in range(10):
        w = max(int(img.width * scale), 1)
        h = max(int(img.height * scale), 1)
        buf = io.BytesIO()
        img.resize((w, h)).save(buf, "JPEG", quality=quality)
        data = buf.getvalue()
        if len(data) <= MAX_INLINE:
            break
        scale *= 0.8
        quality = max(45, quality - 7)
    print("compressed image %s -> %s" % (human_size(len(raw)), human_size(len(data))))
    return data, "image/jpeg"


def send_file(gid, path, caption, as_image):
    if not os.path.isfile(path):
        print("ERROR: file not found: %s" % path, file=sys.stderr)
        sys.exit(2)
    if as_image:
        data, mime = _shrink_image_bytes(path)
    else:
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        with open(path, "rb") as f:
            data = f.read()
    size = len(data)
    if size > 9_000_000:
        print("ERROR: file too large for chat (max ~9 MB): %s" % path, file=sys.stderr)
        sys.exit(2)
    b64 = base64.b64encode(data).decode("ascii")
    data_uri = "data:%s;base64,%s" % (mime, b64)
    extra = {
        "type": "image" if as_image else "file",
        "text": caption or "",
        "fileUrl": data_uri,
        "fileName": os.path.basename(path),
        "fileSize": human_size(size),
    }
    key = post_message(gid, extra)
    if caption:
        send_text(gid, caption)
    return key


def cmd_pin(gid, message_id, off):
    http("PATCH", "%s/group/messages/%s/%s.json" % (db_url(), gid, message_id),
         {"pinned": (not off)})
    print("ok: %s %s" % ("unpinned" if off else "pinned", message_id))


def cmd_history(gid, n):
    msgs = get("group/messages/%s" % gid,
               'orderBy="$key"&limitToLast=%d' % n) or {}
    items = sorted(msgs.values(), key=lambda m: m.get("timestamp") or 0)
    for m in items:
        ts = time.strftime("%Y-%m-%d %H:%M", time.localtime((m.get("timestamp") or 0) / 1000))
        kind = m.get("type") or "text"
        body = m.get("text") or ("[%s] %s" % (kind, m.get("fileName") or ""))
        bot = " [bot]" if m.get("senderIsBot") else ""
        pin = " [pinned]" if m.get("pinned") else ""
        print("%s | %s%s%s | %s | id=%s" % (ts, m.get("senderName") or "?", bot, pin, body, m.get("id") or ""))


def owner_groups():
    owner = owner_id()
    bot_id = "bot:%s" % owner
    groups = get("group/groups") or {}
    mine = {}
    for gid, g in groups.items():
        members = (g or {}).get("members") or {}
        if owner in members or bot_id in members:
            mine[gid] = g or {}
    return mine


def cmd_groups():
    owner = owner_id()
    mine = owner_groups()
    if not mine:
        print("(no groups - the owner has not joined any group yet)")
        return
    for gid, g in sorted(mine.items(), key=lambda kv: (kv[0] != "global", (kv[1].get("name") or "").lower())):
        members = g.get("members") or {}
        humans = [m for m in members if not m.startswith("bot:")]
        admin = " [admin=you]" if g.get("ownerId") == owner else ""
        bot_in = " [bot joined]" if ("bot:%s" % owner) in members else ""
        print("%s | %s | %d members%s%s" % (gid, g.get("name") or "Group", len(humans), admin, bot_in))


def cmd_members(gid):
    g = get("group/groups/%s" % gid) or {}
    members = g.get("members") or {}
    users = get("group/users") or {}
    print("group: %s (%s) admin=%s" % (g.get("name") or "?", gid, g.get("ownerId") or "?"))
    for mid in sorted(members):
        u = users.get(mid) or {}
        online = "online" if u.get("online") else "offline"
        kind = "bot" if (u.get("isBot") or mid.startswith("bot:")) else "user"
        details = []
        if u.get("age"):
            details.append("age %s" % u.get("age"))
        if u.get("gender"):
            details.append(u.get("gender"))
        detail = (" (" + ", ".join(details) + ")") if details else ""
        print("%s | %s | %s | %s%s" % (mid, u.get("name") or "?", kind, online, detail))


def cmd_users():
    users = get("group/users") or {}
    for uid, u in sorted(users.items(), key=lambda kv: (not (kv[1] or {}).get("online"), ((kv[1] or {}).get("name") or "").lower())):
        u = u or {}
        online = "online" if u.get("online") else "offline"
        kind = "bot" if u.get("isBot") else "user"
        details = []
        if u.get("age"):
            details.append("age %s" % u.get("age"))
        if u.get("gender"):
            details.append(u.get("gender"))
        detail = (" (" + ", ".join(details) + ")") if details else ""
        print("%s | %s | %s | %s%s" % (uid, u.get("name") or "?", kind, online, detail))


# ----------------------------------------------------------------------
# Direct messages (private user-to-user chats)
#
# A DM thread is a pseudo-group with id `dm_<uidA>_<uidB>` (sorted pair).
# Messages live at group/messages/<dmId> just like groups, and the
# per-user thread index group/dmIndex/<uid>/<peerId> powers chat lists.
# The bot writes as `bot:<owner>` on the owner's behalf.
# ----------------------------------------------------------------------
def dm_id_for(a, b):
    x, y = (a, b) if a <= b else (b, a)
    return "dm_%s_%s" % (x, y)


def resolve_peer(who):
    """Accepts a user id or a (case-insensitive) display name; returns (uid, user)."""
    users = get("group/users") or {}
    if who in users:
        return who, (users[who] or {})
    needle = who.strip().lower()
    matches = [(uid, u or {}) for uid, u in users.items()
               if not (u or {}).get("isBot")
               and ((u or {}).get("name") or "").strip().lower() == needle]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        print("ERROR: no user found with id or name '%s' (see `hermesa-group users`)" % who,
              file=sys.stderr)
    else:
        print("ERROR: multiple users named '%s' - use the user id instead:" % who,
              file=sys.stderr)
        for uid, u in matches:
            print("  %s | %s" % (uid, u.get("name")), file=sys.stderr)
    sys.exit(2)


def touch_dm_index(a, b):
    """Bumps the DM thread index on BOTH sides so the chat shows up in the app."""
    http("PATCH", "%s/group/dmIndex.json" % db_url(), {
        "%s/%s" % (a, b): {".sv": "timestamp"},
        "%s/%s" % (b, a): {".sv": "timestamp"},
    })


def send_voice(gid, path, caption):
    """Sends an audio file as a playable in-chat voice note (TTS 'voice call')."""
    if not os.path.isfile(path):
        print("ERROR: file not found: %s" % path, file=sys.stderr)
        sys.exit(2)
    size = os.path.getsize(path)
    if size > 9_000_000:
        print("ERROR: audio too large for chat (max ~9 MB): %s" % path, file=sys.stderr)
        sys.exit(2)
    mime = mimetypes.guess_type(path)[0] or "audio/mpeg"
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    extra = {
        "type": "voice",
        "text": caption or "",
        "audioUrl": "data:%s;base64,%s" % (mime, b64),
        "audioDuration": "",
        "fileName": os.path.basename(path),
        "fileSize": human_size(size),
    }
    return post_message(gid, extra)


def cmd_dms():
    owner = owner_id()
    idx = get("group/dmIndex/%s" % owner) or {}
    if not idx:
        print("(no private chats yet)")
        return
    users = get("group/users") or {}
    for pid, ts in sorted(idx.items(), key=lambda kv: -(kv[1] or 0)):
        u = users.get(pid) or {}
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime((ts or 0) / 1000))
        online = "online" if u.get("online") else "offline"
        print("%s | %s | %s | last activity %s | dmId=%s"
              % (pid, u.get("name") or "?", online, when, dm_id_for(owner, pid)))


def extract_opt(args, name):
    """Removes `--name value` from args and returns (value, rest)."""
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            print("ERROR: %s needs a value" % name, file=sys.stderr)
            sys.exit(2)
        value = args[i + 1]
        return value, args[:i] + args[i + 2:]
    return None, args


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)
    cmd = args[0]
    rest = args[1:]

    gid, rest = extract_opt(rest, "--group")
    gid = gid or default_group()
    reply_to, rest = extract_opt(rest, "--reply-to")

    if cmd == "text":
        if not rest:
            print("ERROR: text requires a message", file=sys.stderr)
            sys.exit(2)
        keys = send_text(gid, rest[0], reply_to)
        print("ok: sent %d message(s) to %s: %s" % (len(keys), gid, ",".join(k or "?" for k in keys)))
    elif cmd == "task":
        if not rest:
            print("ERROR: task requires a description", file=sys.stderr)
            sys.exit(2)
        key = post_message(gid, {"type": "task", "text": rest[0]})
        print("ok: task posted to %s: %s" % (gid, key))
    elif cmd in ("file", "image"):
        if not rest:
            print("ERROR: %s requires a path" % cmd, file=sys.stderr)
            sys.exit(2)
        caption = rest[1] if len(rest) > 1 else ""
        key = send_file(gid, rest[0], caption, as_image=(cmd == "image"))
        print("ok: %s sent to %s: %s" % (cmd, gid, key))
    elif cmd == "pin":
        if not rest:
            print("ERROR: pin requires a messageId", file=sys.stderr)
            sys.exit(2)
        cmd_pin(gid, rest[0], off=(len(rest) > 1 and rest[1] == "off"))
    elif cmd == "history":
        n = int(rest[0]) if rest else 30
        cmd_history(gid, n)
    elif cmd == "groups":
        cmd_groups()
    elif cmd == "members":
        cmd_members(gid)
    elif cmd == "users":
        cmd_users()
    elif cmd == "dm":
        if len(rest) < 2:
            print("ERROR: dm requires <userIdOrName> and a message", file=sys.stderr)
            sys.exit(2)
        peer, _u = resolve_peer(rest[0])
        owner = owner_id()
        dm = dm_id_for(owner, peer)
        keys = send_text(dm, rest[1], reply_to)
        touch_dm_index(owner, peer)
        print("ok: private message sent to %s (%d chunk(s), thread %s)" % (peer, len(keys), dm))
    elif cmd in ("dm-file", "dm-image"):
        if len(rest) < 2:
            print("ERROR: %s requires <userIdOrName> and <path>" % cmd, file=sys.stderr)
            sys.exit(2)
        peer, _u = resolve_peer(rest[0])
        owner = owner_id()
        dm = dm_id_for(owner, peer)
        caption = rest[2] if len(rest) > 2 else ""
        key = send_file(dm, rest[1], caption, as_image=(cmd == "dm-image"))
        touch_dm_index(owner, peer)
        print("ok: %s sent privately to %s: %s"
              % ("image" if cmd == "dm-image" else "file", peer, key))
    elif cmd == "dm-voice":
        if len(rest) < 2:
            print("ERROR: dm-voice requires <userIdOrName> and <audioPath>", file=sys.stderr)
            sys.exit(2)
        peer, _u = resolve_peer(rest[0])
        owner = owner_id()
        dm = dm_id_for(owner, peer)
        caption = rest[2] if len(rest) > 2 else ""
        key = send_voice(dm, rest[1], caption)
        touch_dm_index(owner, peer)
        print("ok: voice message sent privately to %s: %s" % (peer, key))
    elif cmd == "dm-history":
        if not rest:
            print("ERROR: dm-history requires <userIdOrName>", file=sys.stderr)
            sys.exit(2)
        peer, _u = resolve_peer(rest[0])
        n = int(rest[1]) if len(rest) > 1 else 30
        cmd_history(dm_id_for(owner_id(), peer), n)
    elif cmd == "dms":
        cmd_dms()
    else:
        print("ERROR: unknown command: %s" % cmd, file=sys.stderr)
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
