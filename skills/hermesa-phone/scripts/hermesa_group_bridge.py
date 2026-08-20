#!/usr/bin/env python3
"""
hermesa_group_bridge.py - two-way bridge between the Hermes agent and the
Pulse Messenger GROUP CHAT system (the app's BUILT-IN group server).

The app now ships with a built-in Firebase RTDB for groups: users sign up
inside the app, can create many groups, and every user's bot connects to
this SAME built-in server (no per-user group DB needed). The user's OWN
bot database (bot <-> Hermes webhook connection) is untouched and keeps
working exactly as before - this bridge only handles group traffic.

The bot joins as member `bot:<owner-user-id>` and:
  * keeps an online/offline presence heartbeat,
  * auto-joins every group its OWNER is a member of (and leaves when the
    owner disables the bot),
  * reads the member list and messages of each of those groups (marks seen),
  * replies to its OWNER when mentioned / replied-to / given a /task,
  * replies to OTHER USERS only when the owner enabled `botReplyOthers`,
  * watches the owner's PRIVATE DM threads (user-to-user chats) with the
    same rules, and can send private texts/files/voice notes on request,
  * talks to OTHER BOTS only when the owner enabled `botCrossBot`,
  * transcribes voice notes (Groq Whisper) and downloads shared files,
  * posts replies/files/tasks back into the SAME group they came from.

Live settings are read from the group DB (`group/users/<owner>`), so
flipping the switches in the app takes effect without restarts.

Config (~/.hermes/.env or environment):
  HERMESA_GROUP_DB_URL   optional override; default is the built-in server
  HERMESA_GROUP_USER_ID  the owner's user id shown in the app's bot settings
  HERMESA_GROUP_BOT_NAME optional fallback bot display name
  HERMESA_POLL_SECONDS   poll interval (default 5)
  GROQ_API_KEY           optional, for voice transcription
"""

import json
import os
import sys
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hermesa_bridge as hb  # reuse cfg/transcribe/inject/save helpers

HOME = os.path.expanduser("~")
HERMES = os.path.join(HOME, ".hermes")
GROUP_INBOX = os.path.join(HERMES, "work", "inbox", "hermesa-group")
STATE_FILE = os.path.join(HERMES, "hermesa_group_state.json")
# Built-in group server (same constant as the app's GroupChatManager).
DEFAULT_GROUP_DB_URL = "https://softizence-default-rtdb.firebaseio.com"
MAX_REPLY_CHUNK = 3500
MAX_DONE_IDS = 800
HEARTBEAT_SECONDS = 30
CONTEXT_MESSAGES = 12

# route shared attachment/queue helpers into the group inbox for this process
hb.INBOX = GROUP_INBOX
hb.QUEUE_FILE = os.path.join(GROUP_INBOX, "queue.md")


def log(msg: str) -> None:
    print("[hermesa-group] %s" % msg, flush=True)


def cfg(name: str, default: str = "") -> str:
    return hb.cfg(name, default)


# ----------------------------------------------------------------------
# state (per-group cursors)
# ----------------------------------------------------------------------
def load_state() -> dict:
    try:
        with open(STATE_FILE) as fh:
            st = json.load(fh)
            st.setdefault("groups", {})
            st.setdefault("done_ids", [])
            st.setdefault("my_ids", [])
            # migrate old single-group state (last_ts) into the global group
            if "last_ts" in st and "global" not in st["groups"]:
                st["groups"]["global"] = {"last_ts": int(st["last_ts"])}
            return st
    except Exception:
        return {"groups": {}, "done_ids": [], "my_ids": []}


def group_state(st: dict, gid: str) -> dict:
    g = st["groups"].setdefault(gid, {})
    # never replay old history the first time we see a group
    g.setdefault("last_ts", int(time.time() * 1000))
    return g


def save_state(st: dict) -> None:
    st["done_ids"] = st["done_ids"][-MAX_DONE_IDS:]
    st["my_ids"] = st["my_ids"][-200:]
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        log("state save failed: %s" % e)


# ----------------------------------------------------------------------
# firebase REST helpers (need PATCH/DELETE in addition to hb.http_json)
# ----------------------------------------------------------------------
def http(url, payload=None, method=None, timeout=30):
    if payload is None and method is None:
        req = urllib.request.Request(url)
    else:
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(
            url, data=data,
            headers={"Content-Type": "application/json"},
            method=method or "POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace") or "null")


def bot_member_id(owner: str) -> str:
    return "bot:%s" % owner


def heartbeat(db: str, owner: str, name: str, online: bool) -> None:
    http("%s/group/users/%s.json" % (db, bot_member_id(owner)),
         {"id": bot_member_id(owner), "name": name, "isBot": True,
          "ownerId": owner, "online": bool(online),
          "lastSeen": int(time.time() * 1000)},
         method="PATCH")


def owner_settings(db: str, owner: str) -> dict:
    try:
        data = http("%s/group/users/%s.json" % (db, owner)) or {}
        return data if isinstance(data, dict) else {}
    except Exception as e:
        log("owner settings fetch failed: %s" % e)
        return {}


def fetch_users(db: str) -> dict:
    try:
        data = http("%s/group/users.json" % db) or {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def fetch_groups(db: str, owner: str) -> dict:
    """Returns {gid: group} for every group the owner (or the bot) is in."""
    try:
        data = http("%s/group/groups.json" % db) or {}
    except Exception as e:
        log("groups fetch failed: %s" % e)
        return {}
    if not isinstance(data, dict):
        return {}
    bid = bot_member_id(owner)
    out = {}
    for gid, g in data.items():
        if not isinstance(g, dict):
            continue
        members = g.get("members") or {}
        if owner in members or bid in members:
            out[gid] = g
    return out


def fetch_dm_threads(db: str, owner: str) -> dict:
    """Returns {dmId: peerId} for every private chat thread of the owner."""
    try:
        data = http("%s/group/dmIndex/%s.json" % (db, owner)) or {}
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for peer in data:
        if not isinstance(peer, str) or not peer:
            continue
        x, y = (owner, peer) if owner <= peer else (peer, owner)
        out["dm_%s_%s" % (x, y)] = peer
    return out


def dm_peer_of(gid: str, owner: str):
    """The other participant of a DM thread id, or None for group ids."""
    if not gid.startswith("dm_"):
        return None
    parts = [x for x in gid[3:].split("_") if x]
    if len(parts) != 2:
        return None
    if parts[0] == owner:
        return parts[1]
    if parts[1] == owner:
        return parts[0]
    return None


def msg_ts(m) -> int:
    """Message timestamp as int; tolerates str/float/None junk values."""
    try:
        return int(float(m.get("timestamp") or 0))
    except (TypeError, ValueError):
        return 0


def is_bot_dm(gid: str, bid: str) -> bool:
    """True when the DM thread is a direct private chat WITH the bot itself."""
    if not gid.startswith("dm_"):
        return False
    return bid in [x for x in gid[3:].split("_") if x]


def touch_dm_index(db: str, gid: str, owner: str) -> None:
    """Bumps both sides of the DM index after the bot posts in a DM."""
    peer = dm_peer_of(gid, owner)
    a = owner
    if not peer:
        a = bot_member_id(owner)
        peer = dm_peer_of(gid, a)
    if not peer:
        return
    now = int(time.time() * 1000)
    try:
        http("%s/group/dmIndex.json" % db,
             {"%s/%s" % (a, peer): now, "%s/%s" % (peer, a): now},
             method="PATCH")
    except Exception as e:
        log("dm index update failed: %s" % e)


def sync_bot_membership(db: str, owner: str, groups: dict, enabled: bool) -> None:
    """Joins the bot to every owner group (or removes it when disabled)."""
    bid = bot_member_id(owner)
    now = int(time.time() * 1000)
    for gid, g in groups.items():
        members = (g or {}).get("members") or {}
        try:
            if enabled and bid not in members:
                http("%s/group/groups/%s/members.json" % (db, gid),
                     {bid: now}, method="PATCH")
                log("joined group %s as %s" % (gid, bid))
            elif not enabled and bid in members:
                http("%s/group/groups/%s/members/%s.json" % (db, gid, bid),
                     method="DELETE")
                log("left group %s" % gid)
        except Exception as e:
            log("membership sync failed for %s: %s" % (gid, e))


def fetch_messages(db: str, gid: str):
    url = '%s/group/messages/%s.json?orderBy="$key"&limitToLast=60' % (db, gid)
    data = http(url) or {}
    if not isinstance(data, dict):
        return []
    out = []
    for key in sorted(data.keys()):
        m = data[key]
        if isinstance(m, dict):
            m.setdefault("id", key)
            out.append(m)
    return out


def mark_seen(db: str, gid: str, owner: str, ids) -> None:
    if not ids:
        return
    now = int(time.time() * 1000)
    bid = bot_member_id(owner)
    updates = {}
    for mid in ids:
        updates["%s/seenBy/%s" % (mid, bid)] = now
    try:
        http("%s/group/messages/%s.json" % (db, gid), updates, method="PATCH")
    except Exception as e:
        log("mark seen failed: %s" % e)


def post_group_message(db: str, gid: str, owner: str, name: str, text: str,
                       reply_to=None, reply_to_text=None, reply_to_sender=None,
                       mentions=None, mtype="text", extra=None):
    """Posts (possibly chunked) messages as the bot. Returns posted ids."""
    ids = []
    text = (text or "").strip()
    chunks = [text[i:i + MAX_REPLY_CHUNK]
              for i in range(0, len(text), MAX_REPLY_CHUNK)] or [""]
    for i, chunk in enumerate(chunks):
        payload = {
            "senderId": bot_member_id(owner),
            "senderName": name,
            "senderIsBot": True,
            "ownerId": owner,
            "text": chunk,
            "type": mtype,
            "pinned": False,
            "timestamp": int(time.time() * 1000),
        }
        if i == 0:
            if reply_to:
                payload["replyToId"] = reply_to
            if reply_to_text:
                payload["replyToText"] = reply_to_text[:80]
            if reply_to_sender:
                payload["replyToSender"] = reply_to_sender
            if mentions:
                payload["mentions"] = list(mentions)
            if extra:
                payload.update(extra)
        try:
            res = http("%s/group/messages/%s.json" % (db, gid), payload) or {}
            mid = res.get("name")
            if mid:
                ids.append(mid)
                # store id so app-side ordering shows it under the push key
                http("%s/group/messages/%s/%s.json" % (db, gid, mid),
                     {"id": mid}, method="PATCH")
        except Exception as e:
            log("post failed: %s" % e)
        time.sleep(0.2)
    return ids


# ----------------------------------------------------------------------
# reply decision rules
# ----------------------------------------------------------------------
def normalize_mentions(m: dict):
    raw = m.get("mentions")
    if isinstance(raw, list):
        return [x for x in raw if isinstance(x, str)]
    if isinstance(raw, dict):
        return [x for x in raw.values() if isinstance(x, str)]
    if isinstance(raw, str):
        return [x.strip() for x in raw.split(",") if x.strip()]
    return []


def is_mentioned(m: dict, bid: str, bname: str, my_ids) -> bool:
    if bid in normalize_mentions(m):
        return True
    text = (m.get("text") or "").lower()
    if bname and ("@" + bname.lower()) in text:
        return True
    if m.get("replyToId") and m.get("replyToId") in my_ids:
        return True
    if bname and (m.get("replyToSender") or "").lower() == bname.lower():
        return True
    return False


def is_task(m: dict) -> bool:
    text = (m.get("text") or "").strip().lower()
    return text.startswith("/task") or (m.get("type") or "") == "task"


def should_reply(m: dict, owner: str, bid: str, bname: str,
                 settings: dict, my_ids, recent,
                 bot_dm: bool = False) -> bool:
    sender = m.get("senderId") or ""
    if sender == bid:
        return False
    mentioned = is_mentioned(m, bid, bname, my_ids)
    task = is_task(m)
    if m.get("senderIsBot"):
        # another user's bot -> only when the owner enabled bot-to-bot chat
        if not settings.get("botCrossBot"):
            return False
        if not (mentioned or task):
            return False
        # loop guard: never keep a bot<->bot ping-pong going forever
        tail = recent[-6:]
        if len(tail) >= 6 and all(x.get("senderIsBot") for x in tail):
            log("bot-to-bot loop guard triggered - staying quiet")
            return False
        return True
    if bot_dm:
        # a private 1-to-1 chat WITH the bot itself: no mention or /task
        # needed - a plain "hi" must always get an answer. The owner is
        # always answered; other users only when the owner allowed it.
        if sender == owner:
            return True
        return bool(settings.get("botReplyOthers"))
    if sender == owner:
        # the owner: mention, reply-to-bot or /task triggers a response
        return mentioned or task
    # other human users -> only when the owner allowed it
    if not settings.get("botReplyOthers"):
        return False
    return mentioned or task


# ----------------------------------------------------------------------
# prompt building & processing
# ----------------------------------------------------------------------
def preview(m: dict) -> str:
    t = (m.get("type") or "text").lower()
    if t == "image":
        return "[photo] %s" % (m.get("fileName") or "")
    if t == "file":
        return "[file] %s" % (m.get("fileName") or "")
    if t == "voice":
        return "[voice message]"
    return (m.get("text") or "").strip()[:300]


def build_prompt(m: dict, gid: str, gname: str, group: dict, users: dict,
                 recent, owner: str, bname: str) -> str:
    sender_name = m.get("senderName") or "Unknown"
    sender_id = m.get("senderId") or "?"
    mtype = (m.get("type") or "text").lower()

    bid = bot_member_id(owner)
    dm_peer = dm_peer_of(gid, owner)
    if dm_peer is None and is_bot_dm(gid, bid):
        dm_peer = dm_peer_of(gid, bid)
    if dm_peer == bid:
        lines = ["[Hermesa PRIVATE DM] You are \"%s\", the personal bot of "
                 "owner %s, inside a PRIVATE one-to-one chat with your OWNER. "
                 "Nobody else can read this thread. Answer EVERY message "
                 "directly and naturally, like a personal assistant - even a "
                 "simple greeting deserves a friendly reply."
                 % (bname, owner)]
    elif dm_peer:
        lines = ["[Hermesa PRIVATE DM] You are \"%s\", the bot of owner %s, "
                 "inside a PRIVATE one-to-one chat between your owner and "
                 "\"%s\" (user id %s). Nobody else can read this thread."
                 % (bname, owner, gname, dm_peer)]
    else:
        lines = ["[Hermesa GROUP chat] You are \"%s\", a bot member of the "
                 "group \"%s\" (group id: %s). Your owner's user id is %s."
                 % (bname, gname, gid, owner)]

    member_ids = set((group or {}).get("members") or {})
    members = []
    for uid, u in sorted(users.items()):
        if not isinstance(u, dict) or uid not in member_ids:
            continue
        extras = []
        if u.get("age"):
            extras.append("age %s" % u.get("age"))
        if u.get("gender"):
            extras.append(str(u.get("gender")))
        extras.append("online" if u.get("online") else "offline")
        members.append("%s%s (%s, %s)" % (
            u.get("name") or uid,
            " [bot]" if u.get("isBot") else "",
            uid, ", ".join(extras)))
    if members:
        lines.append("Members of this group: " + "; ".join(members))
    admin = (group or {}).get("ownerId")
    if admin:
        lines.append("Group admin user id: %s" % admin)

    ctx = [x for x in recent if x.get("id") != m.get("id")][-CONTEXT_MESSAGES:]
    if ctx:
        lines.append("Recent conversation:")
        for x in ctx:
            lines.append("  %s%s: %s" % (
                x.get("senderName") or "?",
                " [bot]" if x.get("senderIsBot") else "",
                preview(x)))

    body = (m.get("text") or "").strip()
    if mtype == "voice" and m.get("audioUrl"):
        path = hb.save_payload(m["audioUrl"],
                               hb.safe_name(m.get("fileName"), "voice.m4a"))
        transcript = hb.transcribe(path) if path else ""
        if transcript:
            body = "(voice message transcript) %s" % transcript
        elif path:
            body = "(voice message saved at %s - transcription unavailable)" % path
        else:
            body = "(voice message could not be downloaded)"
    elif mtype in ("image", "file") and m.get("fileUrl"):
        path = hb.save_payload(m["fileUrl"],
                               hb.safe_name(m.get("fileName"), "attachment.bin"))
        note = "shared a %s: %s%s" % (
            "photo" if mtype == "image" else "file",
            m.get("fileName") or "attachment",
            (" (saved locally at %s)" % path) if path else "")
        body = ("%s\n%s" % (note, body)).strip()

    if dm_peer:
        cli_hint = ("Reply into THIS private chat with `hermesa-group dm %s \"text\"`. "
                    "You can also send files (`dm-file %s <path> [caption]`), photos "
                    "(`dm-image`), or a playable voice note such as generated TTS "
                    "audio (`dm-voice %s <audioPath>`). `dms` lists all private "
                    "threads." % (dm_peer, dm_peer, dm_peer))
    else:
        cli_hint = ("Use the `hermesa-group` CLI (text/file/image/task/pin/"
                    "history/groups/members/users) with `--group %s` to act in "
                    "THIS group. For PRIVATE messages to one person use "
                    "`hermesa-group dm <userIdOrName> \"text\"` (also dm-file/"
                    "dm-image/dm-voice for files and TTS voice notes)." % gid)
    if is_task(m):
        lines.append("New GROUP TASK from %s (%s): %s" % (sender_name, sender_id, body))
        lines.append("Do the task if it is quick, or start it and say what "
                     "you'll deliver. %s" % cli_hint)
    else:
        lines.append("New message from %s (%s)%s: %s" % (
            sender_name, sender_id,
            " [another user's bot]" if m.get("senderIsBot") else "", body))
        lines.append("Write a helpful, SHORT group-chat reply (plain text). "
                     "%s" % cli_hint)
    return "\n".join(lines)


def process_message(db: str, gid: str, gname: str, group: dict, owner: str,
                    bname: str, m: dict, users: dict, recent, st: dict) -> None:
    prompt = build_prompt(m, gid, gname, group, users, recent, owner, bname)
    log("handling %s message %s from %s in group %s"
        % (m.get("type", "text"), m.get("id"), m.get("senderName"), gid))
    # Live typing indicator: keep group/typing/<gid>/<bot> fresh while the
    # agent thinks, so the app shows "<bot> is typing..." in realtime.
    typing_url = "%s/group/typing/%s/%s.json" % (db, gid, bot_member_id(owner))
    stop_typing = threading.Event()

    def _typing_beat():
        while not stop_typing.is_set():
            try:
                http(typing_url, int(time.time() * 1000), method="PUT")
            except Exception:
                pass
            stop_typing.wait(5)

    beat = threading.Thread(target=_typing_beat, daemon=True)
    beat.start()
    try:
        ok, reply = hb.inject_into_agent(prompt)
    finally:
        stop_typing.set()
        try:
            http(typing_url, None, method="DELETE")
        except Exception:
            pass
    if not reply:
        hb.queue_fallback(prompt)
        reply = ("\u26a0\ufe0f I couldn't reach my agent just now - I saved "
                 "this message and will pick it up on my next run.")
    ids = post_group_message(
        db, gid, owner, bname, reply,
        reply_to=m.get("id"),
        reply_to_text=preview(m),
        reply_to_sender=m.get("senderName"),
        mentions=[m.get("senderId")] if m.get("senderId") else None)
    st["my_ids"].extend(ids)
    if ids:
        touch_dm_index(db, gid, owner)


# ----------------------------------------------------------------------
# main loop
# ----------------------------------------------------------------------
def main() -> None:
    log("group bridge starting (multi-group, built-in server)")
    os.makedirs(GROUP_INBOX, exist_ok=True)
    st = load_state()
    last_beat = 0.0
    last_online = None

    while True:
        try:
            poll = max(3, int(cfg("HERMESA_POLL_SECONDS", "5") or "5"))
        except ValueError:
            poll = 5
        try:
            db = (cfg("HERMESA_GROUP_DB_URL") or DEFAULT_GROUP_DB_URL).rstrip("/")
            owner = cfg("HERMESA_GROUP_USER_ID").strip()
            if not db or not owner:
                time.sleep(15)
                continue
            bid = bot_member_id(owner)

            settings = owner_settings(db, owner)
            bname = (settings.get("botName") or
                     cfg("HERMESA_GROUP_BOT_NAME") or "Hermes").strip()
            enabled = bool(settings.get("botEnabled"))

            groups = fetch_groups(db, owner)

            now = time.time()
            if now - last_beat > HEARTBEAT_SECONDS or last_online != enabled:
                heartbeat(db, owner, bname, online=enabled)
                sync_bot_membership(db, owner, groups, enabled)
                last_beat = now
                last_online = enabled

            if not enabled:
                time.sleep(poll)
                continue

            users = None
            convos = dict(groups)
            dm_threads = fetch_dm_threads(db, owner)
            # also watch DM threads that users opened DIRECTLY with the bot
            # (those live in the bot's own dmIndex, not the owner's)
            for dmid, peer in fetch_dm_threads(db, bid).items():
                dm_threads.setdefault(dmid, peer)
            if dm_threads:
                users = fetch_users(db)
                for dmid, peer in dm_threads.items():
                    pu = (users.get(peer) or {})
                    convos[dmid] = {"id": dmid,
                                    "name": pu.get("name") or peer,
                                    "ownerId": owner,
                                    "members": {owner: 1, peer: 1}}
            for gid, group in convos.items():
                gname = (group or {}).get("name") or gid
                gst = group_state(st, gid)
                msgs = fetch_messages(db, gid)
                new = [m for m in msgs
                       if msg_ts(m) > gst["last_ts"]
                       and m.get("id") not in st["done_ids"]
                       and (m.get("senderId") or "") != bid]
                if not new:
                    continue
                if users is None:
                    users = fetch_users(db)
                mark_seen(db, gid, owner, [m["id"] for m in new])
                for m in new:
                    st["done_ids"].append(m["id"])
                    ts = msg_ts(m)
                    if ts > gst["last_ts"]:
                        gst["last_ts"] = ts
                    save_state(st)
                    if should_reply(m, owner, bid, bname, settings,
                                    st["my_ids"], msgs,
                                    bot_dm=is_bot_dm(gid, bid)):
                        process_message(db, gid, gname, group, owner, bname,
                                        m, users, msgs, st)
                        save_state(st)
        except Exception as e:
            log("loop error: %s" % e)
        time.sleep(poll)


if __name__ == "__main__":
    main()
