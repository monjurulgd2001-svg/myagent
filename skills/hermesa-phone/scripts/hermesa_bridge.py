#!/usr/bin/env python3
"""
Hermesa Bridge - TWO-WAY chat between the Hermesa Android app and Hermes
=========================================================================
This daemon makes the Hermesa app behave exactly like the Telegram bot:

  Phone -> Agent : text chat, voice messages (auto-transcribed), any file
                   or image, and full tasks ("scrape this", "email him").
  Agent -> Phone : replies are pushed back into the SAME app conversation
                   automatically; the agent can also push images / files /
                   voice calls at any time with the existing `hermesa` CLI.

How it works
------------
1. Polls <HERMESA_DB_URL>/bots/<HERMESA_BOT_ID>/messages.json for new
   entries with sender == "user" (the app writes those when the boss
   types, records a voice note, or attaches a file).
2. Voice notes are saved to ~/.hermes/work/inbox/hermesa/ and transcribed
   with Groq Whisper when GROQ_API_KEY is configured.
3. Files / images are saved to ~/.hermes/work/inbox/hermesa/ so the agent
   can open them locally (platform upload caches get wiped; this dir is
   part of the persisted ~/.hermes tree).
4. The message is injected into the running Hermes agent
   (`hermes agent --message ...`), and the agent's reply text is POSTed
   back to the app as a bot message.
5. A cursor + processed-id set in ~/.hermes/hermesa_bridge_state.json
   guarantees every message is handled exactly once, across restarts.

Config (all read LIVE from ~/.hermes/.env, panel changes apply within ~1m):
  HERMESA_DB_URL       required - the app's Firebase RTDB URL
  HERMESA_BOT_ID       required - which bot conversation belongs to Hermes
  GROQ_API_KEY         optional - enables voice-note transcription
  HERMESA_POLL_SECONDS optional - poll interval (default 4)
  HERMESA_INJECT_CMD   optional - override the agent-inject command;
                       {msg} is replaced with the message text
"""

import base64
import json
import os
import re
import shlex
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

HOME = os.path.expanduser("~")
HERMES = os.path.join(HOME, ".hermes")
INBOX = os.path.join(HERMES, "work", "inbox", "hermesa")
STATE_FILE = os.path.join(HERMES, "hermesa_bridge_state.json")
QUEUE_FILE = os.path.join(INBOX, "queue.md")
MAX_REPLY_CHUNK = 3500
AGENT_TIMEOUT = 1500  # a task can legitimately run for many minutes
# The Hermesa app ships with a built-in Firebase server hardcoded in
# FirebaseManager.kt; bot chats live at <db>/bots/<botId>/messages there.
# When the panel leaves HERMESA_DB_URL empty we fall back to it so the
# Bots-tab chat works out of the box with just HERMESA_BOT_ID set.
DEFAULT_APP_DB_URL = ""  # no baked-in endpoint - the config panel (vault) supplies the URL
MAX_DONE_IDS = 800


def log(msg: str) -> None:
    print("[hermesa-bridge] %s" % msg, flush=True)


# ----------------------------------------------------------------------
# live config (same pattern as hermesa_bot.py: .env first, env second)
# ----------------------------------------------------------------------
def cfg(name: str, default: str = "") -> str:
    try:
        with open(os.path.join(HERMES, ".env")) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(name + "="):
                    v = line.split("=", 1)[1].strip()
                    if v:
                        return v
    except OSError:
        pass
    return (os.environ.get(name, "") or "").strip() or default


def persist_env(pairs: dict) -> None:
    """Upsert config into ~/.hermes/.env so the `hermesa` CLI (which the
    agent runs in a separate process) always sees the same HERMESA_DB_URL /
    HERMESA_BOT_ID the bridge is using. Fixes bogus 'not configured' errors
    when the panel env only exists inside the workflow process."""
    try:
        path = os.path.join(HERMES, ".env")
        try:
            with open(path) as fh:
                lines = fh.read().splitlines()
        except OSError:
            lines = []
        for k, v in pairs.items():
            if not v:
                continue
            hit = False
            for i, line in enumerate(lines):
                if line.strip().startswith(k + "="):
                    lines[i] = "%s=%s" % (k, v)
                    hit = True
                    break
            if not hit:
                lines.append("%s=%s" % (k, v))
        os.makedirs(HERMES, exist_ok=True)
        with open(path, "w") as fh:
            fh.write("\n".join(lines).rstrip("\n") + "\n")
        log("config synced to ~/.hermes/.env for the hermesa CLI")
    except Exception as e:
        log("env persist failed: %s" % e)


# ----------------------------------------------------------------------
# state
# ----------------------------------------------------------------------
def load_state() -> dict:
    try:
        with open(STATE_FILE) as fh:
            st = json.load(fh)
            st.setdefault("last_ts", 0)
            st.setdefault("done_ids", [])
            return st
    except Exception:
        # first ever start: only react to messages sent from NOW on, so the
        # whole chat history is never replayed into the agent
        return {"last_ts": int(time.time() * 1000), "done_ids": []}


def save_state(st: dict) -> None:
    st["done_ids"] = st["done_ids"][-MAX_DONE_IDS:]
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        log("state save failed: %s" % e)


# ----------------------------------------------------------------------
# firebase helpers
# ----------------------------------------------------------------------
def http_json(url: str, payload=None, timeout=30):
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace") or "null")


def http_send(url: str, payload=None, method="PUT", timeout=15):
    """PUT/DELETE helper used for the live typing indicator node."""
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        r.read()


def msg_ts(m) -> int:
    """Message timestamp as int; tolerates str/float/None junk values."""
    try:
        return int(float(m.get("timestamp") or 0))
    except (TypeError, ValueError):
        return 0


def fetch_recent_messages(db_url: str, bot_id: str):
    # push keys sort chronologically, and orderBy="$key" needs no .indexOn
    url = ('%s/bots/%s/messages.json?orderBy="$key"&limitToLast=40'
           % (db_url, bot_id))
    data = http_json(url) or {}
    if not isinstance(data, dict):
        return []
    out = []
    for key, m in data.items():
        if isinstance(m, dict):
            m.setdefault("id", key)
            out.append(m)
    out.sort(key=lambda m: (msg_ts(m), str(m.get("id") or "")))
    return out


def post_bot_message(db_url: str, bot_id: str, text: str,
                     level: str = "info") -> None:
    url = "%s/bots/%s/messages.json" % (db_url, bot_id)
    for chunk_start in range(0, max(len(text), 1), MAX_REPLY_CHUNK):
        chunk = text[chunk_start:chunk_start + MAX_REPLY_CHUNK]
        payload = {
            "sender": "bot",
            "text": chunk,
            "type": "text",
            "level": level,
            "timestamp": int(time.time() * 1000),
        }
        try:
            http_json(url, payload)
        except Exception as e:
            log("reply POST failed: %s" % e)
            return


# ----------------------------------------------------------------------
# attachment handling
# ----------------------------------------------------------------------
_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def safe_name(name: str, fallback: str) -> str:
    name = _SAFE.sub("_", (name or "").strip()) or fallback
    return name[-120:]


def save_payload(url_or_data: str, file_name: str) -> str:
    """Save a data: URI or download an http(s) URL into the inbox.
    Returns the local path, or '' on failure."""
    os.makedirs(INBOX, exist_ok=True)
    path = os.path.join(INBOX, "%d_%s" % (int(time.time()), file_name))
    try:
        if url_or_data.startswith("data:"):
            b64 = url_or_data.split(",", 1)[1] if "," in url_or_data else ""
            with open(path, "wb") as fh:
                fh.write(base64.b64decode(b64))
        elif url_or_data.startswith(("http://", "https://")):
            req = urllib.request.Request(url_or_data,
                                         headers={"User-Agent": "hermesa-bridge"})
            with urllib.request.urlopen(req, timeout=120) as r, \
                    open(path, "wb") as fh:
                while True:
                    buf = r.read(65536)
                    if not buf:
                        break
                    fh.write(buf)
        else:
            return ""
        return path
    except Exception as e:
        log("attachment save failed (%s): %s" % (file_name, e))
        try:
            os.remove(path)
        except OSError:
            pass
        return ""


def transcribe(path: str) -> str:
    """Groq Whisper transcription. Returns '' when unavailable/failed."""
    key = cfg("GROQ_API_KEY")
    if not key or not path:
        return ""
    try:
        boundary = uuid.uuid4().hex
        with open(path, "rb") as fh:
            audio = fh.read()
        fname = os.path.basename(path)
        parts = []
        for k, v in (("model", "whisper-large-v3"),
                     ("response_format", "json")):
            parts.append(("--%s\r\nContent-Disposition: form-data; "
                          "name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)
                          ).encode())
        parts.append(("--%s\r\nContent-Disposition: form-data; "
                      "name=\"file\"; filename=\"%s\"\r\n"
                      "Content-Type: application/octet-stream\r\n\r\n"
                      % (boundary, fname)).encode())
        parts.append(audio)
        parts.append(("\r\n--%s--\r\n" % boundary).encode())
        body = b"".join(parts)
        req = urllib.request.Request(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            data=body,
            headers={
                "Authorization": "Bearer %s" % key,
                "Content-Type": "multipart/form-data; boundary=%s" % boundary,
            })
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return (data.get("text") or "").strip()
    except Exception as e:
        log("transcription failed: %s" % e)
        return ""


# ----------------------------------------------------------------------
# agent injection
# ----------------------------------------------------------------------
def extract_reply(raw: str) -> str:
    """Best-effort extraction of the agent's reply from CLI output."""
    raw = (raw or "").strip()
    if not raw:
        return ""
    # try full-output JSON, then last JSON-looking line
    candidates = [raw] + [ln for ln in raw.splitlines()[::-1]
                          if ln.strip().startswith("{")][:3]
    for cand in candidates:
        try:
            obj = json.loads(cand)
        except Exception:
            continue
        if isinstance(obj, dict):
            for k in ("reply", "response", "text", "content", "message",
                      "result", "output"):
                v = obj.get(k)
                if isinstance(v, str) and v.strip():
                    return v.strip()
            # payloads: [{text: ...}] shape
            pl = obj.get("payloads") or obj.get("messages")
            if isinstance(pl, list):
                texts = [p.get("text") for p in pl
                         if isinstance(p, dict) and isinstance(p.get("text"), str)]
                if texts:
                    return "\n\n".join(t.strip() for t in texts if t.strip())
    # plain text output: drop obvious log noise lines
    lines = [ln for ln in raw.splitlines()
             if not re.match(r"^\s*(\[|\d{4}-\d\d-\d\d[T ]|(DEBUG|INFO|WARN|ERROR)\b)", ln)]
    text = "\n".join(lines).strip() or raw
    return text[-8000:]


_cli_diagnosed = {"done": False}


# Root of the Hermes agent workspace (where AGENTS.md, skills/, system/,
# memory files etc. live). This bridge script lives in
# skills/hermesa-phone/scripts/, so the workspace root is three levels up.
# Without this the agent was launched from whatever random directory the
# daemon happened to start in, so it could not see its skills or brain
# files at all. Override with HERMESA_WORKSPACE if the layout differs.
WORKSPACE_ROOT = cfg("HERMESA_WORKSPACE") or os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", ".."))


def _diagnose_cli() -> None:
    """One-time dump of the hermes CLI surface into the log, so a failing
    inject explains itself in the GitHub run log (no terminal needed)."""
    if _cli_diagnosed["done"]:
        return
    _cli_diagnosed["done"] = True
    try:
        res = subprocess.run(["hermes", "--help"], capture_output=True,
                             text=True, timeout=60, cwd=WORKSPACE_ROOT)
        out = ((res.stdout or "") + "\n" + (res.stderr or "")).strip()
        log("DIAGNOSIS hermes --help (rc=%s):\n%s"
            % (res.returncode, out[:1500]))
    except FileNotFoundError:
        log("DIAGNOSIS: 'hermes' CLI is NOT on PATH for this daemon - "
            "set HERMESA_INJECT_CMD in the panel to the correct command")
    except Exception as e:
        log("DIAGNOSIS: could not run 'hermes --help': %s" % e)


def inject_into_agent(message: str) -> tuple:
    """Run one agent turn with the message. Returns (ok, reply_text)."""
    override = cfg("HERMESA_INJECT_CMD")
    if override:
        cmds = [shlex.split(override.replace("{msg}", message))]
    else:
        # Newer Hermes CLI does one-shot prompts with `hermes -z PROMPT`
        # (there is no `agent` subcommand any more); older builds used
        # `hermes agent --message`. Try newest first, keep old fallbacks.
        cmds = [
            ["hermes", "-z", message],
            ["hermes", "agent", "--message", message, "--json"],
            ["hermes", "agent", "--message", message],
        ]
    # two rounds: right after a (watchdog) restart the gateway can still be
    # booting, so one failed round gets a second chance 20s later
    for attempt in (1, 2):
        for cmd in cmds:
            try:
                # cwd=WORKSPACE_ROOT is what gives the agent access to its
                # skills, memory/brain files and scripts - exactly like a
                # normal interactive session in the workspace.
                res = subprocess.run(cmd, capture_output=True, text=True,
                                     timeout=AGENT_TIMEOUT, cwd=WORKSPACE_ROOT)
            except FileNotFoundError:
                log("inject cmd %s failed: executable not found on PATH"
                    % cmd[:1])
                continue
            except subprocess.TimeoutExpired:
                # the subprocess was KILLED - nothing keeps running, so be
                # honest and queue the task for the drain pass instead of
                # promising a result that will never arrive.
                queue_fallback(message)
                return (False, "⏳ This took longer than my wait limit, so I "
                               "queued it - I will finish it and post the "
                               "result on my next pass.")
            if res.returncode == 0:
                reply = extract_reply(res.stdout)
                if reply:
                    return (True, reply)
                log("inject cmd %s rc=0 but no usable reply text; stdout "
                    "head: %r" % (cmd[:3], (res.stdout or "")[:200]))
            else:
                log("inject cmd %s failed rc=%s: %s"
                    % (cmd[:3], res.returncode, (res.stderr or "")[:300]))
        if attempt == 1:
            log("inject failed - retrying once in 20s "
                "(gateway may still be booting)")
            time.sleep(20)
    _diagnose_cli()
    return (False, "")


def queue_fallback(message: str) -> None:
    """Last resort: persist the message where the agent will find it."""
    log("agent unreachable - queued the message for the next agent turn")
    os.makedirs(INBOX, exist_ok=True)
    with open(QUEUE_FILE, "a") as fh:
        fh.write("\n## %s\n%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))


# ----------------------------------------------------------------------
# task completion enforcement
# ----------------------------------------------------------------------
# The agent runs ONE-SHOT per message: when its reply comes back, the
# process is gone. So a reply like "On it - I'll get back to you" means
# the task silently DIES. These helpers detect acknowledgment-only
# replies and immediately re-inject a "finish it NOW" follow-up turn.
_ACK_RE = re.compile(
    r"(on it|i'?ll (get|start|work|do|look|check|handle)|"
    r"working on (it|this|that)|i('?m| am) (on|starting|working)|"
    r"give me (a (moment|minute|min|sec|second)|some time)|"
    r"hold on|hang tight|stay tuned|right away|coming (right )?up|"
    r"will (do|start|update|get back|handle|deliver)|"
    r"let me (get|start|work|check|look)|starting (now|on|the)|"
    r"kore dicchi|kore dibo|korchi|kortesi|kaj shuru|dekhchi|dekhtesi|"
    r"ektu (wait|opekkha)|shortly|in a (bit|moment|minute))",
    re.IGNORECASE)
# things that look like an actual work product, not a promise
_DELIVERABLE_RE = re.compile(
    r"(```|\n[-*•] |\n\d+\. |https?://|\n\|.*\||(^|\n)#{1,3} |\.md\b|"
    r"saved (at|to|in)|~/\.hermes/)", re.IGNORECASE)
FORCE_ROUNDS = 2


def looks_like_ack_only(reply: str) -> bool:
    """True when the reply is just a promise with no work product in it."""
    r = (reply or "").strip()
    if not r or len(r) > 700:
        return False
    if _DELIVERABLE_RE.search(r):
        return False
    return bool(_ACK_RE.search(r))


def force_completion(prompt: str, reply: str, task_hint: str = "") -> str:
    """Re-inject up to FORCE_ROUNDS times until the reply stops being an
    acknowledgment and contains the actual deliverable."""
    for i in range(FORCE_ROUNDS):
        if not looks_like_ack_only(reply):
            return reply
        log("reply is acknowledgment-only - forcing completion "
            "(round %d/%d)" % (i + 1, FORCE_ROUNDS))
        followup = (
            "[Hermesa bridge follow-up] Your previous reply was: %r\n"
            "That was ONLY an acknowledgment. REALITY CHECK: you are a "
            "one-shot process - nothing runs after you reply, there is no "
            "background worker, so anything you 'promise' will NEVER "
            "happen.\n"
            "DO THE WORK RIGHT NOW using your skills, scripts and "
            "terminal, then reply with the COMPLETE professional "
            "deliverable (the actual content/result/file path - not a "
            "status update, not a plan, not a promise).\n\n"
            "The original request was:\n%s"
            % (reply[:400], (task_hint or prompt)[-6000:]))
        ok, second = inject_into_agent(followup)
        if not ok or not second:
            break
        reply = second
    return reply


_DRAIN = {"last": 0.0}


def drain_queue(post_fn, extra: str = "") -> None:
    """Process messages queued while the agent was unreachable, so queued
    tasks actually get DONE instead of rotting in queue.md forever."""
    try:
        with open(QUEUE_FILE) as fh:
            queued = fh.read().strip()
    except OSError:
        return
    if not queued:
        return
    if time.time() - _DRAIN["last"] < 120:  # don't hammer a dead gateway
        return
    _DRAIN["last"] = time.time()
    log("draining queued messages (%d bytes)" % len(queued))
    prompt = ("[Hermesa queued messages] The following messages arrived "
              "while you were unreachable. Handle them NOW - do every "
              "task fully and include the results. %s\n\n%s"
              % (extra, queued[-12000:]))
    ok, reply = inject_into_agent(prompt)
    if not ok or not reply:
        return
    reply = force_completion(prompt, reply)
    try:
        os.remove(QUEUE_FILE)
    except OSError:
        pass
    if post_fn:
        post_fn(reply)


# ----------------------------------------------------------------------
# message processing
# ----------------------------------------------------------------------
# How many previous chat messages are replayed to the agent as memory.
# The agent runs one-shot per message, so WITHOUT this block it forgets
# the whole conversation every single time - this block IS its memory.
CONTEXT_MESSAGES = 20


def _msg_preview(m: dict) -> str:
    text = (m.get("text") or "").strip()
    mtype = (m.get("type") or "text").lower()
    if mtype in ("voice", "audio") or m.get("audioUrl"):
        text = ("[voice message] " + text).strip()
    elif mtype == "image" or m.get("imageUrl"):
        text = ("[image] " + text).strip()
    elif mtype in ("file", "video") or m.get("fileUrl") or m.get("videoUrl"):
        text = ("[file: %s] %s" % (m.get("fileName") or "attachment",
                                   text)).strip()
    text = " ".join(text.split())
    if len(text) > 300:
        text = text[:300] + "..."
    return text or "[empty]"


def build_history_block(recent, current_id) -> str:
    ctx = [x for x in recent if x.get("id") != current_id][-CONTEXT_MESSAGES:]
    if not ctx:
        return ""
    lines = ["[Conversation memory] Recent messages in this Hermesa chat, "
             "oldest first. This is your memory of what was already "
             "discussed - stay consistent with it:"]
    for x in ctx:
        who = "You (bot)" if (x.get("sender") == "bot") else "Boss"
        lines.append("  %s: %s" % (who, _msg_preview(x)))
    return "\n".join(lines)


def build_agent_message(msg: dict) -> str:
    mtype = (msg.get("type") or "text").lower()
    text = (msg.get("text") or "").strip()
    header = ("[Hermesa app message from the boss - reply normally; your "
              "reply text is delivered back into the Hermesa app chat "
              "automatically. You are running inside your normal Hermes "
              "workspace with FULL access to your skills, memory/brain "
              "files, scripts and tools - read and use them exactly like "
              "any other task. For sending images/files/calls to the phone "
              "use the `hermesa` command (text/image/file/call). SMART "
              "ACTIONS: when the boss asks to DM a user, call/ring a user, "
              "start a group call, or send a file to a group or a person, "
              "EXECUTE the `hermesa-group` CLI in your terminal NOW - never "
              "say you can't: `hermesa-group dm <userIdOrName> \"text\"`, "
              "`dm-file`/`dm-image`/`dm-voice <user> <path>`, "
              "`call <user>` (rings their phone), `group-call --group "
              "<gid>` (rings every member), `file`/`image <path> --group "
              "<gid>`. Resolve names with `hermesa-group users` and pick "
              "group ids from `hermesa-group groups`. CRITICAL: you are a ONE-SHOT "
              "process - NOTHING runs after you reply and there is no "
              "background worker, so never answer a task with only an "
              "acknowledgment or a promise ('on it', 'I will do it'). DO "
              "the work NOW with your skills/tools and make your reply "
              "the finished result itself.]")

    if mtype in ("voice", "audio") or (msg.get("audioUrl") and mtype != "voice_call"):
        fname = safe_name(msg.get("audioFileName") or "voice_note.m4a",
                          "voice_note.m4a")
        path = save_payload(msg.get("audioUrl") or "", fname)
        transcript = transcribe(path) if path else ""
        body = "The boss sent a VOICE MESSAGE from the Hermesa app."
        if path:
            body += "\nSaved locally at: %s" % path
        if transcript:
            body += "\nTranscript: %s" % transcript
        elif path:
            body += ("\n(No transcript available - transcribe the audio "
                     "file yourself if needed.)")
        if text:
            body += "\nCaption: %s" % text
        return "%s\n%s" % (header, body)

    if mtype == "image" or msg.get("imageUrl"):
        fname = safe_name(msg.get("fileName") or "photo.jpg", "photo.jpg")
        path = save_payload(msg.get("imageUrl") or "", fname)
        body = "The boss sent an IMAGE from the Hermesa app."
        if path:
            body += "\nSaved locally at: %s" % path
        if text:
            body += "\nCaption/instruction: %s" % text
        return "%s\n%s" % (header, body)

    if mtype in ("file", "video") or msg.get("fileUrl") or msg.get("videoUrl"):
        fname = safe_name(msg.get("fileName") or "attachment.bin",
                          "attachment.bin")
        path = save_payload(msg.get("fileUrl") or msg.get("videoUrl") or "",
                            fname)
        body = "The boss sent a FILE from the Hermesa app (%s%s)." % (
            fname, ", %s" % msg["fileSize"] if msg.get("fileSize") else "")
        if path:
            body += "\nSaved locally at: %s" % path
        if text:
            body += "\nCaption/instruction: %s" % text
        return "%s\n%s" % (header, body)

    return "%s\n%s" % (header, text)


def process_message(db_url: str, bot_id: str, msg: dict) -> None:
    agent_msg = build_agent_message(msg)
    # Prepend the recent conversation so the one-shot agent remembers what
    # was said before (same idea as the group bridge's context block).
    try:
        history = build_history_block(
            fetch_recent_messages(db_url, bot_id), msg.get("id"))
    except Exception as e:
        log("history fetch failed: %s" % e)
        history = ""
    if history:
        agent_msg = "%s\n\n%s" % (history, agent_msg)
    log("processing user msg %s (%s)" % (msg.get("id"), msg.get("type")))
    # Live typing indicator: keep bots/<botId>/typing fresh while the agent
    # thinks, so the app shows the Messenger-style typing bubble (same UX as
    # the group bridge).
    typing_url = "%s/bots/%s/typing.json" % (db_url.rstrip("/"), bot_id)
    stop_typing = threading.Event()

    def _typing_beat():
        while not stop_typing.is_set():
            try:
                http_send(typing_url, int(time.time() * 1000), method="PUT")
            except Exception:
                pass
            stop_typing.wait(5)

    beat = threading.Thread(target=_typing_beat, daemon=True)
    beat.start()
    try:
        ok, reply = inject_into_agent(agent_msg)
        if ok and reply:
            # never let an "on it..." acknowledgment be the final word
            reply = force_completion(agent_msg, reply)
    finally:
        stop_typing.set()
        try:
            http_send(typing_url, None, method="DELETE")
        except Exception:
            pass
    if ok and reply:
        post_bot_message(db_url, bot_id, reply)
    elif reply:  # timeout notice etc.
        post_bot_message(db_url, bot_id, reply, level="warning")
    else:
        queue_fallback(agent_msg)
        post_bot_message(
            db_url, bot_id,
            "⚠️ I could not reach the agent right now. Your message is "
            "queued and will be picked up as soon as the agent is back.",
            level="warning")


def main() -> None:
    log("Hermesa two-way bridge starting")
    os.makedirs(INBOX, exist_ok=True)
    state = load_state()
    warned_cfg = False
    persisted_cfg = None
    while True:
        poll = max(2, int(cfg("HERMESA_POLL_SECONDS", "4") or 4))
        db_url = (cfg("HERMESA_DB_URL") or cfg("HERMESA_GROUP_DB_URL") or
                  DEFAULT_APP_DB_URL).rstrip("/")
        bot_id = cfg("HERMESA_BOT_ID")
        if not db_url or not bot_id:
            if not warned_cfg:
                log("HERMESA_BOT_ID not configured - idle "
                    "(set it in the config panel; picked up live)")
                warned_cfg = True
            time.sleep(30)
            continue
        warned_cfg = False
        # Keep ~/.hermes/.env in sync so the `hermesa` CLI the agent calls
        # never says "not configured" while the bridge is clearly configured.
        if (db_url, bot_id) != persisted_cfg:
            persist_env({"HERMESA_DB_URL": db_url, "HERMESA_BOT_ID": bot_id})
            persisted_cfg = (db_url, bot_id)
        # finish anything that was queued while the agent was unreachable
        drain_queue(lambda text: post_bot_message(db_url, bot_id, text))
        try:
            msgs = fetch_recent_messages(db_url, bot_id)
        except Exception as e:
            log("poll failed: %s" % e)
            time.sleep(poll * 3)
            continue
        for m in msgs:
            if (m.get("sender") or "bot") != "user":
                continue
            ts = msg_ts(m)
            mid = str(m.get("id") or "")
            if ts <= 0 or not mid:
                continue
            if ts < state["last_ts"] - 120000:  # older than cursor-2min
                continue
            if mid in state["done_ids"]:
                continue
            # mark BEFORE processing so a crash can never double-run a task
            state["done_ids"].append(mid)
            state["last_ts"] = max(state["last_ts"], ts)
            save_state(state)
            try:
                process_message(db_url, bot_id, m)
            except Exception as e:
                log("processing error for %s: %s" % (mid, e))
            save_state(state)
        time.sleep(poll)


if __name__ == "__main__":
    main()
