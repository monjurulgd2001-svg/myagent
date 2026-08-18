#!/usr/bin/env python3
"""tg - Telegram group admin CLI for the Hermes agent.

Every action is one direct Bot API call. This tool NEVER calls
getUpdates: the Hermes chat gateway owns long-polling and a second
poller would cause 409 conflicts and kill the chat connection.

Config (from ~/.hermes/.env, written by the workflow / config panel):
  TELEGRAM_BOT_TOKEN   required
  TELEGRAM_GROUP_IDS   optional - comma separated; first id = default group
  TELEGRAM_GROUP_ROLE  optional - "auto" (default) or "member":
                       auto   = admin commands work only when the bot
                                really is a group admin (auto-checked)
                       member = hard-locked member mode; admin commands
                                are disabled even if the bot is an admin
"""

import argparse
import calendar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API_ROOT = "https://api.telegram.org/bot"
ENV_FILE = os.path.expanduser("~/.hermes/.env")
SCHED_FILE = os.path.expanduser("~/.hermes/tg_schedule.json")
BLOCKED = {"getupdates", "setwebhook", "deletewebhook", "logout", "close"}


def _load_env_file():
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                os.environ.setdefault(key.strip(), val.strip())
    except OSError:
        pass


_load_env_file()
TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
GROUPS = [g.strip() for g in re.split(r"[,\n]", os.environ.get("TELEGRAM_GROUP_IDS", "")) if g.strip()]
ROLE = (os.environ.get("TELEGRAM_GROUP_ROLE", "").strip().lower() or "auto")
if ROLE not in ("auto", "admin", "member"):
    ROLE = "auto"

# commands / raw methods that need group ADMIN rights
ADMIN_CMDS = {"ban", "unban", "kick", "mute", "unmute", "promote",
              "demote", "pin", "unpin", "invite", "revoke-invite",
              "approve", "decline", "title", "desc", "lockdown",
              "unlock", "topic-new", "topic-close", "topic-reopen",
              "topic-rename", "topic-del"}
ADMIN_METHOD_PAT = re.compile(
    r"^(ban|unban|restrict|promote|setChat|pinChat|unpinChat|unpinAll"
    r"|createChatInvite|editChatInvite|revokeChatInvite"
    r"|approveChatJoin|declineChatJoin|deleteChatPhoto|setChatPhoto"
    r"|setChatAdministrator|deleteChatStickerSet|setChatStickerSet)", re.I)
MEMBER_ALLOWED = ("send, reply, edit, delete (own msgs), photo, file, "
                  "video, voice, audio, gif, sticker, album, poll, "
                  "quiz, react, forward, copy, location, contact, "
                  "schedule, jobs, info, admins, member, count, groups, me")


def die(msg, code=1):
    print("tg: " + msg, file=sys.stderr)
    sys.exit(code)


def api(method, payload=None):
    if not TOKEN:
        die("TELEGRAM_BOT_TOKEN is not set (config panel > Telegram)")
    if method.lower() in BLOCKED:
        die("method %s is blocked: it would break the Hermes chat gateway" % method)
    req = urllib.request.Request(
        API_ROOT + TOKEN + "/" + method,
        data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            out = json.load(resp)
    except urllib.error.HTTPError as err:
        try:
            out = json.load(err)
        except Exception:
            out = {"ok": False, "description": "HTTP %s" % err.code}
    except Exception as err:
        die("network error on %s: %s" % (method, err))
    if not out.get("ok"):
        die("%s failed: %s" % (method, out.get("description")))
    return out.get("result")


def show(obj):
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def _norm_chat(ref):
    ref = str(ref).strip()
    if re.fullmatch(r"[1-9]", ref) and len(GROUPS) >= int(ref):
        ref = GROUPS[int(ref) - 1]
    if re.fullmatch(r"-?\d+", ref):
        return int(ref)
    if ref.startswith("@"):
        return ref
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{3,}", ref):
        return "@" + ref
    die("cannot understand group reference: " + ref)


def chat_of(args):
    ref = getattr(args, "group", None)
    if ref:
        return _norm_chat(ref)
    if GROUPS:
        return _norm_chat(GROUPS[0])
    die("no group configured: pass -g <chat-id|@name> or set "
        "TELEGRAM_GROUP_IDS in the config panel (Telegram section)")


def parse_msg_ref(ref, default_chat):
    """Accepts a plain message id or any t.me message link (incl. topics)."""
    ref = str(ref).strip()
    m = re.search(r"t\.me/c/(\d+)(?:/\d+)?/(\d+)(?:\?.*)?$", ref)
    if m:
        return int("-100" + m.group(1)), int(m.group(2))
    m = re.search(r"t\.me/([A-Za-z][A-Za-z0-9_]{3,})(?:/\d+)?/(\d+)(?:\?.*)?$", ref)
    if m:
        return "@" + m.group(1), int(m.group(2))
    if re.fullmatch(r"\d+", ref):
        return default_chat, int(ref)
    die("cannot parse message id / t.me link: " + ref)


def user_of(val, chat):
    """Resolve a numeric id or @username to a numeric user id."""
    val = str(val).strip()
    if re.fullmatch(r"-?\d+", val):
        return int(val)
    uname = val.lstrip("@").lower()
    try:
        for entry in api("getChatAdministrators", {"chat_id": chat}) or []:
            u = entry.get("user", {})
            if (u.get("username") or "").lower() == uname:
                return u["id"]
    except SystemExit:
        pass
    try:
        res = api("getChat", {"chat_id": "@" + uname})
        if res and res.get("type") == "private":
            return res["id"]
    except SystemExit:
        pass
    die("cannot resolve @%s to a numeric user id (Telegram bots cannot "
        "look up arbitrary usernames). Ask the boss for the numeric id, "
        "or have the user post in the group and use the id shown there." % uname)


def _until(hours):
    return int(time.time()) + int(float(hours) * 3600) if hours else None


def ensure_admin(action, chat):
    """Gate admin actions by role config + the bot's REAL group status."""
    if ROLE == "member":
        die("MEMBER MODE: this deployment is locked to member-level "
            "commands (TELEGRAM_GROUP_ROLE=member in the config panel), "
            "so '%s' is disabled. Available: %s. Only the group owner's "
            "deployment manages the group." % (action, MEMBER_ALLOWED))
    status = None
    try:
        me = api("getMe")
        status = (api("getChatMember",
                      {"chat_id": chat, "user_id": me["id"]}) or {}).get("status")
    except SystemExit:
        return  # cannot verify - Telegram still enforces rights server-side
    if status not in ("administrator", "creator"):
        die("NOT AN ADMIN: this bot is only '%s' in this group, so '%s' is "
            "not allowed. Member-level commands still work: %s. To unlock "
            "admin actions, the GROUP OWNER must promote this bot to admin "
            "in Telegram (ban/pin/invite rights)." % (status, action, MEMBER_ALLOWED))


MUTE_OFF = {k: False for k in (
    "can_send_messages", "can_send_audios", "can_send_documents",
    "can_send_photos", "can_send_videos", "can_send_video_notes",
    "can_send_voice_notes", "can_send_polls", "can_send_other_messages",
    "can_add_web_page_previews")}
MUTE_ON = {k: True for k in MUTE_OFF}
MUTE_ON.update({"can_invite_users": True})


BTN_HELP = "inline URL buttons: 'Label|https://url, L2|url2 ; Row2|url3'"


def _buttons(spec):
    """'Label|url, L2|url2 ; Row2|url3' -> inline keyboard (URL buttons)."""
    rows = []
    for raw_row in spec.split(";"):
        btns = []
        for part in raw_row.split(","):
            part = part.strip()
            if not part:
                continue
            if "|" not in part:
                die("bad button %r - format is 'Label|https://url'" % part)
            label, _, url = part.partition("|")
            if not re.match(r"https?://", url.strip()):
                die("button url must start with http(s):// - got %r" % url.strip())
            btns.append({"text": label.strip(), "url": url.strip()})
        if btns:
            rows.append(btns)
    if not rows:
        die("--buttons is empty")
    return {"inline_keyboard": rows}


def _fmt(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts))


def _tz_off(tz):
    m = re.fullmatch(r"([+-])(\d{1,2}):?(\d{2})?", (tz or "+0").strip())
    if not m:
        die("bad --tz, use a UTC offset like +06:00")
    sign = 1 if m.group(1) == "+" else -1
    return sign * (int(m.group(2)) * 3600 + int(m.group(3) or 0) * 60)


def _parse_dt(s, off):
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M"):
        try:
            return calendar.timegm(time.strptime(s.strip(), fmt)) - off
        except ValueError:
            pass
    die("bad --at, use 'YYYY-MM-DD HH:MM'")


def _next_hm(hm, off, now):
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", hm.strip())
    if not m:
        die("bad time, use HH:MM (24h)")
    h, mi = int(m.group(1)), int(m.group(2))
    day = (now + off) // 86400
    for d in (day, day + 1):
        ts = d * 86400 + h * 3600 + mi * 60 - off
        if ts > now:
            return ts
    return ts


def _next_weekly(spec, off, now):
    m = re.fullmatch(r"([a-z]{3})[a-z]*\s+(\d{1,2}):(\d{2})",
                     spec.strip().lower())
    days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    if not m or m.group(1) not in days:
        die("bad --weekly, use like 'mon 09:00'")
    want = days.index(m.group(1))
    h, mi = int(m.group(2)), int(m.group(3))
    day = (now + off) // 86400
    for d in range(day, day + 8):
        if (d + 3) % 7 == want:
            ts = d * 86400 + h * 3600 + mi * 60 - off
            if ts > now:
                return ts
    die("weekly calc error")


def _parse_every(s):
    m = re.fullmatch(r"(\d+)\s*(m|min|mins|h|hr|hrs|d|day|days)",
                     s.strip().lower())
    if not m:
        die("bad --every, use like 30m, 6h, 1d")
    secs = int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)[0]]
    if secs < 300:
        die("--every minimum is 5m")
    return secs


def _load_jobs():
    try:
        with open(SCHED_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return []


def _save_jobs(jobs):
    os.makedirs(os.path.dirname(SCHED_FILE), exist_ok=True)
    tmp = SCHED_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(jobs, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, SCHED_FILE)


def _add_job(job):
    jobs = _load_jobs()
    job["id"] = max([int(j.get("id", 0)) for j in jobs] or [0]) + 1
    job["created"] = _fmt(time.time())
    jobs.append(job)
    _save_jobs(jobs)
    return job["id"]


def _fire(j):
    kind = j.get("kind", "message")
    if kind == "unlock":
        api("setChatPermissions", {"chat_id": j["chat"],
                                   "permissions": MUTE_ON})
        print("job #%s: group %s auto-unlocked" % (j.get("id"), j.get("chat")),
              flush=True)
        return
    if kind == "stoppoll":
        api("stopPoll", {"chat_id": j["chat"], "message_id": j["mid"]})
        print("job #%s: poll %s closed" % (j.get("id"), j.get("mid")),
              flush=True)
        return
    payload = {"chat_id": j["chat"], "text": j.get("text", "")}
    if j.get("silent"):
        payload["disable_notification"] = True
    if j.get("markdown"):
        payload["parse_mode"] = "Markdown"
    if j.get("topic"):
        payload["message_thread_id"] = j["topic"]
    if j.get("buttons"):
        payload["reply_markup"] = _buttons(j["buttons"])
    res = api("sendMessage", payload)
    print("job #%s: posted message_id=%s" % (j.get("id"),
                                             res.get("message_id")), flush=True)


# ── commands ──────────────────────────────────────────────────────────

def cmd_send(args):
    chat = chat_of(args)
    payload = {"chat_id": chat, "text": args.text}
    if args.silent:
        payload["disable_notification"] = True
    if args.markdown:
        payload["parse_mode"] = "Markdown"
    if getattr(args, "reply_to", None):
        rchat, mid = parse_msg_ref(args.reply_to, chat)
        payload["chat_id"] = rchat
        payload["reply_parameters"] = {"message_id": mid,
                                       "allow_sending_without_reply": True}
    if getattr(args, "topic", None):
        payload["message_thread_id"] = int(args.topic)
    if getattr(args, "buttons", None):
        payload["reply_markup"] = _buttons(args.buttons)
    res = api("sendMessage", payload)
    print("sent message_id=%s chat=%s" % (
        res.get("message_id"), res.get("chat", {}).get("id")))


def cmd_reply(args):
    args.reply_to = args.message
    cmd_send(args)


def cmd_edit(args):
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    api("editMessageText", {"chat_id": chat, "message_id": mid,
                            "text": args.text})
    print("edited message %s" % mid)


def cmd_delete(args):
    chat = chat_of(args)
    for ref in args.messages:
        c, mid = parse_msg_ref(ref, chat)
        api("deleteMessage", {"chat_id": c, "message_id": mid})
        print("deleted message %s" % mid)


def cmd_pin(args):
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    api("pinChatMessage", {"chat_id": chat, "message_id": mid,
                           "disable_notification": not args.notify})
    print("pinned message %s" % mid)


def cmd_unpin(args):
    chat = chat_of(args)
    if args.all:
        api("unpinAllChatMessages", {"chat_id": chat})
        print("unpinned ALL messages")
        return
    payload = {"chat_id": chat}
    if args.message:
        chat2, mid = parse_msg_ref(args.message, chat)
        payload = {"chat_id": chat2, "message_id": mid}
    api("unpinChatMessage", payload)
    print("unpinned")


def _send_media(args, method, field):
    chat = chat_of(args)
    src = args.source
    caption = getattr(args, "caption", None)
    extra = {}
    if getattr(args, "topic", None):
        extra["message_thread_id"] = int(args.topic)
    if getattr(args, "buttons", None):
        extra["reply_markup"] = _buttons(args.buttons)
    if re.match(r"https?://", src) or not os.path.isfile(src):
        payload = {"chat_id": chat, field: src}
        if caption:
            payload["caption"] = caption
        payload.update(extra)
        res = api(method, payload)
    else:
        cmd = ["curl", "-s", "-X", "POST", API_ROOT + TOKEN + "/" + method,
               "-F", "chat_id=%s" % chat, "-F", "%s=@%s" % (field, src)]
        if caption:
            cmd += ["-F", "caption=%s" % caption]
        for k, v in extra.items():
            cmd += ["-F", "%s=%s" % (k, json.dumps(v) if isinstance(v, dict) else v)]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        try:
            res = json.loads(out)
        except Exception:
            die("upload failed: " + out[:300])
        if not res.get("ok"):
            die("%s failed: %s" % (method, res.get("description")))
        res = res["result"]
    print("sent %s message_id=%s" % (field, res.get("message_id")))


def cmd_photo(args):
    _send_media(args, "sendPhoto", "photo")


def cmd_file(args):
    _send_media(args, "sendDocument", "document")


def cmd_video(args):
    _send_media(args, "sendVideo", "video")


def cmd_voice(args):
    _send_media(args, "sendVoice", "voice")


def cmd_audio(args):
    _send_media(args, "sendAudio", "audio")


def cmd_gif(args):
    _send_media(args, "sendAnimation", "animation")


def cmd_sticker(args):
    _send_media(args, "sendSticker", "sticker")


def cmd_album(args):
    chat = chat_of(args)
    if not 2 <= len(args.sources) <= 10:
        die("album needs 2-10 items")
    media, files = [], []
    for i, src in enumerate(args.sources):
        ext = os.path.splitext(src.split("?")[0])[1].lower().lstrip(".")
        mtype = ("photo" if ext in ("jpg", "jpeg", "png", "webp") else
                 "video" if ext in ("mp4", "mov", "m4v", "avi") else
                 "audio" if ext in ("mp3", "m4a", "flac", "ogg", "wav")
                 else "document")
        item = {"type": mtype}
        if re.match(r"https?://", src):
            item["media"] = src
        else:
            if not os.path.isfile(src):
                die("file not found: " + src)
            item["media"] = "attach://f%d" % i
            files.append(("f%d" % i, src))
        if i == 0 and args.caption:
            item["caption"] = args.caption
        media.append(item)
    if files:
        cmd = ["curl", "-s", "-X", "POST",
               API_ROOT + TOKEN + "/sendMediaGroup",
               "-F", "chat_id=%s" % chat,
               "-F", "media=%s" % json.dumps(media)]
        if getattr(args, "topic", None):
            cmd += ["-F", "message_thread_id=%s" % args.topic]
        for name, path in files:
            cmd += ["-F", "%s=@%s" % (name, path)]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        try:
            res = json.loads(out)
        except Exception:
            die("upload failed: " + out[:300])
        if not res.get("ok"):
            die("sendMediaGroup failed: %s" % res.get("description"))
    else:
        payload = {"chat_id": chat, "media": media}
        if getattr(args, "topic", None):
            payload["message_thread_id"] = int(args.topic)
        api("sendMediaGroup", payload)
    print("album sent (%d items)" % len(media))


def cmd_react(args):
    if not args.clear and not args.emoji:
        die("give an emoji or --clear")
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    reaction = [] if args.clear else [{"type": "emoji", "emoji": args.emoji}]
    api("setMessageReaction", {"chat_id": chat, "message_id": mid,
                               "reaction": reaction, "is_big": args.big})
    print("cleared reactions" if args.clear else "reacted %s" % args.emoji)


def cmd_poll(args):
    chat = chat_of(args)
    if not 2 <= len(args.options) <= 10:
        die("polls need 2-10 options")
    payload = {"chat_id": chat, "question": args.question,
               "options": [{"text": o} for o in args.options],
               "is_anonymous": not args.public}
    if args.multi:
        payload["allows_multiple_answers"] = True
    res = api("sendPoll", payload)
    print("poll sent message_id=%s" % res.get("message_id"))
    if args.hours:
        jid = _add_job({"kind": "stoppoll", "type": "once",
                        "chat": res["chat"]["id"],
                        "mid": res["message_id"],
                        "next_run": _until(args.hours)})
        print("auto-closes in %sh (job #%s)" % (args.hours, jid))


def cmd_quiz(args):
    chat = chat_of(args)
    if not 2 <= len(args.options) <= 10:
        die("quizzes need 2-10 options")
    if not 1 <= args.correct <= len(args.options):
        die("--correct must be 1..%d" % len(args.options))
    payload = {"chat_id": chat, "question": args.question,
               "options": [{"text": o} for o in args.options],
               "type": "quiz", "correct_option_id": args.correct - 1,
               "is_anonymous": True}
    if args.explain:
        payload["explanation"] = args.explain
    res = api("sendPoll", payload)
    print("quiz sent message_id=%s" % res.get("message_id"))


def cmd_stoppoll(args):
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    res = api("stopPoll", {"chat_id": chat, "message_id": mid})
    print("poll closed - %s votes" % res.get("total_voter_count", 0))
    for opt in res.get("options", []):
        print("  %s: %s" % (opt.get("text"), opt.get("voter_count")))


def cmd_forward(args):
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    dest = _norm_chat(args.to)
    res = api("forwardMessage", {"chat_id": dest, "from_chat_id": chat,
                                 "message_id": mid})
    print("forwarded to %s message_id=%s" % (dest, res.get("message_id")))


def cmd_copy(args):
    chat, mid = parse_msg_ref(args.message, chat_of(args))
    dest = _norm_chat(args.to)
    payload = {"chat_id": dest, "from_chat_id": chat, "message_id": mid}
    if args.caption:
        payload["caption"] = args.caption
    res = api("copyMessage", payload)
    print("copied to %s message_id=%s" % (dest, res.get("message_id")))


def cmd_location(args):
    api("sendLocation", {"chat_id": chat_of(args),
                         "latitude": float(args.lat),
                         "longitude": float(args.lon)})
    print("location sent")


def cmd_contact(args):
    api("sendContact", {"chat_id": chat_of(args),
                        "phone_number": args.phone,
                        "first_name": args.name})
    print("contact sent")


def cmd_lockdown(args):
    chat = chat_of(args)
    api("setChatPermissions", {"chat_id": chat, "permissions": MUTE_OFF})
    msg = "group LOCKED: only admins can post"
    if args.hours:
        jid = _add_job({"kind": "unlock", "type": "once", "chat": chat,
                        "next_run": _until(args.hours)})
        msg += " - auto-unlock in %sh (job #%s)" % (args.hours, jid)
    print(msg)


def cmd_unlock(args):
    api("setChatPermissions", {"chat_id": chat_of(args),
                               "permissions": MUTE_ON})
    print("group unlocked: members can post again")


def cmd_topic_new(args):
    res = api("createForumTopic", {"chat_id": chat_of(args),
                                   "name": args.name})
    tid = res.get("message_thread_id")
    print("topic created id=%s name=%s" % (tid, args.name))
    print("(SAVE this id - the Bot API cannot list topics later; "
          "post into it with: tg send \"...\" --topic %s)" % tid)


def cmd_topic_close(args):
    api("closeForumTopic", {"chat_id": chat_of(args),
                            "message_thread_id": int(args.id)})
    print("topic %s closed" % args.id)


def cmd_topic_reopen(args):
    api("reopenForumTopic", {"chat_id": chat_of(args),
                             "message_thread_id": int(args.id)})
    print("topic %s reopened" % args.id)


def cmd_topic_rename(args):
    api("editForumTopic", {"chat_id": chat_of(args),
                           "message_thread_id": int(args.id),
                           "name": args.name})
    print("topic %s renamed to %s" % (args.id, args.name))


def cmd_topic_del(args):
    api("deleteForumTopic", {"chat_id": chat_of(args),
                             "message_thread_id": int(args.id)})
    print("topic %s deleted (all its messages too)" % args.id)


def cmd_schedule(args):
    chat = chat_of(args)
    off = _tz_off(args.tz)
    now = int(time.time())
    job = {"kind": "message", "chat": chat, "text": args.text,
           "silent": bool(args.silent), "markdown": bool(args.markdown)}
    if args.buttons:
        _buttons(args.buttons)
        job["buttons"] = args.buttons
    if getattr(args, "topic", None):
        job["topic"] = int(args.topic)
    picked = [x for x in (args.at, args.daily, args.weekly, args.every) if x]
    if len(picked) != 1:
        die("pick exactly one of --at / --daily / --weekly / --every")
    if args.at:
        ts = _parse_dt(args.at, off)
        if ts <= now:
            die("--at time is in the past (did you forget --tz?)")
        job.update({"type": "once", "next_run": ts})
    elif args.daily:
        job.update({"type": "daily", "step": 86400,
                    "next_run": _next_hm(args.daily, off, now)})
    elif args.weekly:
        job.update({"type": "weekly", "step": 7 * 86400,
                    "next_run": _next_weekly(args.weekly, off, now)})
    else:
        step = _parse_every(args.every)
        job.update({"type": "every", "step": step, "next_run": now + step})
    jid = _add_job(job)
    print("scheduled job #%s (%s) - next run %s UTC" % (
        jid, job["type"], _fmt(job["next_run"])))
    print("(fires while the Hermes workflow is running; "
          "manage with: tg jobs / tg unschedule %s)" % jid)


def cmd_jobs(args):
    jobs = _load_jobs()
    if not jobs:
        print("no scheduled jobs")
        return
    for j in jobs:
        print("#%-3s %-7s %-9s next=%s UTC chat=%-15s %s" % (
            j.get("id"), j.get("type"), j.get("kind"),
            _fmt(j.get("next_run", 0)), j.get("chat"),
            (j.get("text") or "")[:50]))


def cmd_unschedule(args):
    jobs = _load_jobs()
    keep = [j for j in jobs if str(j.get("id")) != str(args.id)]
    if len(keep) == len(jobs):
        die("no job #%s (see: tg jobs)" % args.id)
    _save_jobs(keep)
    print("removed job #%s" % args.id)


def cmd_daemon(args):
    print("tg schedule daemon up (checks every 30s)", flush=True)
    while True:
        now = int(time.time())
        jobs = _load_jobs()
        changed = False
        for j in list(jobs):
            if j.get("next_run", 0) > now:
                continue
            changed = True
            try:
                _fire(j)
            except SystemExit:
                print("job #%s failed this slot" % j.get("id"),
                      file=sys.stderr, flush=True)
            except Exception as err:
                print("job #%s error: %s" % (j.get("id"), err),
                      file=sys.stderr, flush=True)
            if j.get("type") == "once":
                jobs.remove(j)
            else:
                step = j.get("step") or 86400
                nr = j.get("next_run", now)
                while nr <= now:
                    nr += step
                j["next_run"] = nr
        if changed:
            _save_jobs(jobs)
        time.sleep(30)


def cmd_ban(args):
    chat = chat_of(args)
    payload = {"chat_id": chat, "user_id": user_of(args.user, chat)}
    if args.hours:
        payload["until_date"] = _until(args.hours)
    if args.revoke_messages:
        payload["revoke_messages"] = True
    api("banChatMember", payload)
    print("banned %s%s" % (args.user,
          " for %sh" % args.hours if args.hours else " permanently"))


def cmd_unban(args):
    chat = chat_of(args)
    api("unbanChatMember", {"chat_id": chat,
                            "user_id": user_of(args.user, chat),
                            "only_if_banned": True})
    print("unbanned %s (they can rejoin via link)" % args.user)


def cmd_kick(args):
    chat = chat_of(args)
    uid = user_of(args.user, chat)
    api("banChatMember", {"chat_id": chat, "user_id": uid})
    api("unbanChatMember", {"chat_id": chat, "user_id": uid,
                            "only_if_banned": True})
    print("kicked %s (not banned - can rejoin via invite link)" % args.user)


def cmd_mute(args):
    chat = chat_of(args)
    payload = {"chat_id": chat, "user_id": user_of(args.user, chat),
               "permissions": MUTE_OFF}
    if args.hours:
        payload["until_date"] = _until(args.hours)
    api("restrictChatMember", payload)
    print("muted %s%s" % (args.user,
          " for %sh" % args.hours if args.hours else ""))


def cmd_unmute(args):
    chat = chat_of(args)
    api("restrictChatMember", {"chat_id": chat,
                               "user_id": user_of(args.user, chat),
                               "permissions": MUTE_ON})
    print("unmuted %s" % args.user)


def cmd_promote(args):
    chat = chat_of(args)
    uid = user_of(args.user, chat)
    api("promoteChatMember", {
        "chat_id": chat, "user_id": uid, "can_manage_chat": True,
        "can_delete_messages": True, "can_restrict_members": True,
        "can_invite_users": True, "can_pin_messages": True,
        "can_manage_video_chats": True})
    if args.title:
        api("setChatAdministratorCustomTitle",
            {"chat_id": chat, "user_id": uid, "custom_title": args.title})
    print("promoted %s to admin" % args.user)


def cmd_demote(args):
    chat = chat_of(args)
    uid = user_of(args.user, chat)
    api("promoteChatMember", {
        "chat_id": chat, "user_id": uid, "can_manage_chat": False,
        "can_delete_messages": False, "can_restrict_members": False,
        "can_invite_users": False, "can_pin_messages": False,
        "can_manage_video_chats": False, "can_promote_members": False,
        "can_change_info": False})
    print("demoted %s" % args.user)


def cmd_invite(args):
    chat = chat_of(args)
    payload = {"chat_id": chat}
    if args.name:
        payload["name"] = args.name
    if args.hours:
        payload["expire_date"] = _until(args.hours)
    if args.join_request:
        payload["creates_join_request"] = True
    elif args.limit:
        payload["member_limit"] = args.limit
    res = api("createChatInviteLink", payload)
    print(res.get("invite_link"))
    print("(send this link to the person you want to ADD to the group)")


def cmd_revoke_invite(args):
    chat = chat_of(args)
    api("revokeChatInviteLink", {"chat_id": chat, "invite_link": args.link})
    print("revoked " + args.link)


def cmd_approve(args):
    chat = chat_of(args)
    api("approveChatJoinRequest", {"chat_id": chat,
                                   "user_id": user_of(args.user, chat)})
    print("approved join request of %s" % args.user)


def cmd_decline(args):
    chat = chat_of(args)
    api("declineChatJoinRequest", {"chat_id": chat,
                                   "user_id": user_of(args.user, chat)})
    print("declined join request of %s" % args.user)


def cmd_info(args):
    chat = chat_of(args)
    res = api("getChat", {"chat_id": chat})
    try:
        res["member_count"] = api("getChatMemberCount", {"chat_id": chat})
    except SystemExit:
        pass
    show(res)


def cmd_admins(args):
    chat = chat_of(args)
    for entry in api("getChatAdministrators", {"chat_id": chat}) or []:
        u = entry.get("user", {})
        print("%-14s %-12s @%-24s %s %s" % (
            u.get("id"), entry.get("status"), u.get("username") or "-",
            u.get("first_name") or "", "[bot]" if u.get("is_bot") else ""))


def cmd_member(args):
    chat = chat_of(args)
    show(api("getChatMember", {"chat_id": chat,
                               "user_id": user_of(args.user, chat)}))


def cmd_count(args):
    print(api("getChatMemberCount", {"chat_id": chat_of(args)}))


def cmd_title(args):
    api("setChatTitle", {"chat_id": chat_of(args), "title": args.text})
    print("title set")


def cmd_desc(args):
    api("setChatDescription", {"chat_id": chat_of(args),
                               "description": args.text})
    print("description set")


def cmd_groups(args):
    if not GROUPS:
        print("TELEGRAM_GROUP_IDS is empty - set it in the config panel")
        return
    for i, g in enumerate(GROUPS, 1):
        note = " (default)" if i == 1 else ""
        print("%d: %s%s" % (i, g, note))


def cmd_me(args):
    show(api("getMe"))


def cmd_raw(args):
    try:
        payload = json.loads(args.json) if args.json else {}
    except Exception as err:
        die("bad JSON payload: %s" % err)
    if "chat_id" not in payload and GROUPS:
        payload.setdefault("chat_id", _norm_chat(GROUPS[0]))
    show(api(args.method, payload))


def main():
    p = argparse.ArgumentParser(
        prog="tg",
        description="Telegram GROUP admin tool for the Hermes agent "
                    "(direct Bot API - never touches getUpdates).",
        epilog="Examples:\n"
               "  tg send \"Hello group\"\n"
               "  tg reply https://t.me/c/123456/789 \"replying to that bot\"\n"
               "  tg ban 123456789 --hours 24 | tg unban 123456789\n"
               "  tg mute @spammer --hours 12 | tg kick @spammer\n"
               "  tg pin 456 --notify | tg unpin --all\n"
               "  tg invite --limit 1 --hours 24   # link to ADD a member\n"
               "  tg info | tg admins | tg member 123456789\n"
               "  tg raw sendDice '{\"emoji\": \"🎲\"}'",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def sp(name, fn, help_, **kw):
        s = sub.add_parser(name, help=help_, **kw)
        s.add_argument("-g", "--group",
                       help="group: chat id, @username, or index 1..N "
                            "into TELEGRAM_GROUP_IDS (default: first)")
        s.set_defaults(fn=fn)
        return s

    s = sp("send", cmd_send, "post a message to the group")
    s.add_argument("text")
    s.add_argument("--reply-to", help="message id or t.me link to reply to")
    s.add_argument("--silent", action="store_true")
    s.add_argument("--markdown", action="store_true")
    s.add_argument("--buttons", help=BTN_HELP)
    s.add_argument("--topic", help="forum topic id to post into")

    s = sp("reply", cmd_reply, "reply to a message (works on other bots' "
           "messages too - pass the t.me message link or id)")
    s.add_argument("message", help="message id or t.me link")
    s.add_argument("text")
    s.add_argument("--silent", action="store_true")
    s.add_argument("--markdown", action="store_true")
    s.add_argument("--buttons", help=BTN_HELP)

    s = sp("edit", cmd_edit, "edit one of the bot's own messages")
    s.add_argument("message")
    s.add_argument("text")

    s = sp("delete", cmd_delete, "delete message(s)")
    s.add_argument("messages", nargs="+")

    s = sp("pin", cmd_pin, "pin a group post")
    s.add_argument("message")
    s.add_argument("--notify", action="store_true",
                   help="notify all members about the pin")

    s = sp("unpin", cmd_unpin, "unpin a post (or --all)")
    s.add_argument("message", nargs="?")
    s.add_argument("--all", action="store_true")

    s = sp("photo", cmd_photo, "send a photo (local path or URL)")
    s.add_argument("source")
    s.add_argument("--caption")
    s.add_argument("--buttons", help=BTN_HELP)
    s.add_argument("--topic", help="forum topic id")

    s = sp("file", cmd_file, "send a document (local path or URL)")
    s.add_argument("source")
    s.add_argument("--caption")
    s.add_argument("--buttons", help=BTN_HELP)
    s.add_argument("--topic", help="forum topic id")

    s = sp("ban", cmd_ban, "ban a member (permanent unless --hours)")
    s.add_argument("user", help="numeric user id or @username")
    s.add_argument("--hours", type=float)
    s.add_argument("--revoke-messages", action="store_true",
                   help="also delete all their messages")

    s = sp("unban", cmd_unban, "lift a ban")
    s.add_argument("user")

    s = sp("kick", cmd_kick, "remove a member without banning")
    s.add_argument("user")

    s = sp("mute", cmd_mute, "make a member read-only")
    s.add_argument("user")
    s.add_argument("--hours", type=float)

    s = sp("unmute", cmd_unmute, "restore a muted member")
    s.add_argument("user")

    s = sp("promote", cmd_promote, "make a member admin")
    s.add_argument("user")
    s.add_argument("--title", help="custom admin title")

    s = sp("demote", cmd_demote, "remove admin rights")
    s.add_argument("user")

    s = sp("invite", cmd_invite, "create an invite link (how you ADD users)")
    s.add_argument("--name", help="label for the link")
    s.add_argument("--limit", type=int, help="max joins via this link")
    s.add_argument("--hours", type=float, help="expire after N hours")
    s.add_argument("--join-request", action="store_true",
                   help="joins need approval (tg approve <user>)")

    s = sp("revoke-invite", cmd_revoke_invite, "revoke an invite link")
    s.add_argument("link")

    s = sp("approve", cmd_approve, "approve a pending join request")
    s.add_argument("user")

    s = sp("decline", cmd_decline, "decline a pending join request")
    s.add_argument("user")

    sp("info", cmd_info, "show group info + member count")
    sp("admins", cmd_admins, "list group admins")

    s = sp("member", cmd_member, "show one member's status")
    s.add_argument("user")

    sp("count", cmd_count, "member count")

    s = sp("title", cmd_title, "rename the group")
    s.add_argument("text")

    s = sp("desc", cmd_desc, "set the group description")
    s.add_argument("text")

    sp("groups", cmd_groups, "list configured groups (1 = default)")
    sp("me", cmd_me, "show the bot's own identity")


    for name, fn, hlp in (
            ("video", cmd_video, "send a video (local path or URL)"),
            ("voice", cmd_voice, "send a voice note"),
            ("audio", cmd_audio, "send music/audio"),
            ("gif", cmd_gif, "send a GIF/animation"),
            ("sticker", cmd_sticker, "send a sticker (file/URL/file_id)")):
        s = sp(name, fn, hlp)
        s.add_argument("source")
        s.add_argument("--caption")
        s.add_argument("--buttons", help=BTN_HELP)
        s.add_argument("--topic", help="forum topic id")

    s = sp("album", cmd_album, "send 2-10 photos/videos as ONE album")
    s.add_argument("sources", nargs="+")
    s.add_argument("--caption", help="caption shown on the album")
    s.add_argument("--topic", help="forum topic id")

    s = sp("react", cmd_react, "emoji-react to a message")
    s.add_argument("message", help="message id or t.me link")
    s.add_argument("emoji", nargs="?", help="like 👍 ❤️ 🔥 🎉 😁 💯")
    s.add_argument("--big", action="store_true")
    s.add_argument("--clear", action="store_true",
                   help="remove the bot's reaction")

    s = sp("poll", cmd_poll, "create a poll")
    s.add_argument("question")
    s.add_argument("options", nargs="+", help="2-10 answer options")
    s.add_argument("--public", action="store_true", help="voters visible")
    s.add_argument("--multi", action="store_true", help="multiple answers")
    s.add_argument("--hours", type=float,
                   help="auto-close after N hours (via scheduler)")

    s = sp("quiz", cmd_quiz, "quiz with one right answer")
    s.add_argument("question")
    s.add_argument("options", nargs="+")
    s.add_argument("--correct", type=int, required=True,
                   help="1-based index of the right option")
    s.add_argument("--explain", help="shown after answering")

    s = sp("stoppoll", cmd_stoppoll, "close a poll and show results")
    s.add_argument("message")

    s = sp("forward", cmd_forward, "forward a message to another chat")
    s.add_argument("message")
    s.add_argument("--to", required=True, help="destination chat id/@name/index")

    s = sp("copy", cmd_copy, "copy a message (no 'forwarded from' header)")
    s.add_argument("message")
    s.add_argument("--to", required=True)
    s.add_argument("--caption", help="replace the caption")

    s = sp("location", cmd_location, "send a map location")
    s.add_argument("lat")
    s.add_argument("lon")

    s = sp("contact", cmd_contact, "share a contact card")
    s.add_argument("phone")
    s.add_argument("name")

    s = sp("lockdown", cmd_lockdown, "EMERGENCY: only admins can post")
    s.add_argument("--hours", type=float, help="auto-unlock after N hours")

    sp("unlock", cmd_unlock, "lift a lockdown")

    s = sp("topic-new", cmd_topic_new, "create a forum topic")
    s.add_argument("name")

    s = sp("topic-close", cmd_topic_close, "close a topic")
    s.add_argument("id")

    s = sp("topic-reopen", cmd_topic_reopen, "reopen a topic")
    s.add_argument("id")

    s = sp("topic-rename", cmd_topic_rename, "rename a topic")
    s.add_argument("id")
    s.add_argument("name")

    s = sp("topic-del", cmd_topic_del, "delete a topic + its messages")
    s.add_argument("id")

    s = sp("schedule", cmd_schedule, "schedule a post (one-off or recurring)")
    s.add_argument("text")
    s.add_argument("--at", help="one-time: 'YYYY-MM-DD HH:MM'")
    s.add_argument("--daily", metavar="HH:MM", help="every day at HH:MM")
    s.add_argument("--weekly", metavar="'mon 09:00'")
    s.add_argument("--every", metavar="30m|6h|1d", help="repeating interval")
    s.add_argument("--tz", default="+00:00",
                   help="UTC offset of the given times, e.g. +06:00 for Dhaka")
    s.add_argument("--silent", action="store_true")
    s.add_argument("--markdown", action="store_true")
    s.add_argument("--buttons", help=BTN_HELP)
    s.add_argument("--topic", help="forum topic id")

    sp("jobs", cmd_jobs, "list scheduled jobs")

    s = sp("unschedule", cmd_unschedule, "remove a scheduled job")
    s.add_argument("id")

    sp("_daemon", cmd_daemon, "(internal) scheduler loop - workflow starts it")

    s = sp("raw", cmd_raw, "escape hatch: call any Bot API method "
           "(getUpdates/webhook methods are blocked)")
    s.add_argument("method")
    s.add_argument("json", nargs="?", help="JSON payload")

    args = p.parse_args()
    if args.cmd in ADMIN_CMDS:
        ensure_admin(args.cmd, chat_of(args))
    elif args.cmd == "raw" and ADMIN_METHOD_PAT.match(args.method or ""):
        ensure_admin(args.method, chat_of(args))
    args.fn(args)


if __name__ == "__main__":
    main()
