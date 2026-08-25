---
name: hermesa-agent
description: >-
  Send real-time notifications, messages, images, files, and full-screen
  VOICE CALLS to the user's phone via the Hermesa Android app. Use this
  skill whenever the user asks to be notified, alerted, pinged, called, or
  wants a message/report/screenshot sent to their phone. Voice calls make
  the phone ring with a full-screen call UI even when locked or asleep.
---

# Hermesa Agent Skill

Hermesa is the user's personal Android bot-messenger app. Bots in the app
receive webhook messages in real time through Firebase. This skill lets you
act as one of those bots: push text, images, files, and trigger real phone
calls that play an audio file when answered.

## Configuration

- **Database URL**: `HERMESA_DB_URL` in `~/.hermes/.env` - optional. The
  user can set their OWN Firebase Realtime Database URL in the Hermes config
  panel; when it is EMPTY the scripts automatically fall back to the app's
  built-in server, so calls/messages work with just `HERMESA_BOT_ID` set.
  NEVER refuse to send/call because `HERMESA_DB_URL` is missing.
- **Webhook endpoint** (per bot):
  `POST <HERMESA_DB_URL>/bots/<BOT_ID>/messages.json`
- **BOT_ID**: auto-configured - `HERMESA_BOT_ID` in `~/.hermes/.env` (the
  user sets it once in the Hermes config panel). The bundled script picks
  both values up automatically - normally you configure NOTHING.

No authentication header is required. Content-Type must be `application/json`.

## Message format

Every payload MUST include `sender`, `type`, and a **current** `timestamp` in
milliseconds. The app ignores voice calls with old timestamps (anti-replay),
so never hardcode or reuse timestamps.

Common fields:

| Field | Required | Notes |
|---|---|---|
| `sender` | yes | always `"bot"` |
| `type` | yes | `text` \| `image` \| `file` \| `voice_call` |
| `text` | yes | message body / call title shown to the user |
| `level` | no | `info` \| `success` \| `warning` \| `error` |
| `timestamp` | yes | current Unix time in **milliseconds** |

### 1. Text message

```json
{
  "sender": "bot",
  "text": "Deploy finished successfully",
  "type": "text",
  "level": "success",
  "timestamp": 1770000000000
}
```

### 2. Image

`imageUrl` accepts an https URL **or** a data URI
(`data:image/png;base64,...`). Add `fileName`.

```json
{
  "sender": "bot",
  "text": "Latest chart",
  "type": "image",
  "imageUrl": "https://example.com/chart.png",
  "fileName": "chart.png",
  "timestamp": 1770000000000
}
```

### 3. File attachment

```json
{
  "sender": "bot",
  "text": "Build log",
  "type": "file",
  "fileUrl": "https://example.com/build.log",
  "fileName": "build.log",
  "fileSize": "12.4 KB",
  "level": "info",
  "timestamp": 1770000000000
}
```

### 4. Voice call (rings the phone, even locked/asleep)

`audioUrl` accepts an https URL to an mp3/wav **or** a data URI
(`data:audio/mp3;base64,...`). The phone shows a full-screen incoming-call
UI with the bot's photo and name; when answered, the audio plays as the
call. Use for urgent alerts only.

```json
{
  "sender": "bot",
  "text": "URGENT: production server down",
  "type": "voice_call",
  "audioUrl": "https://example.com/alert.mp3",
  "audioFileName": "alert.mp3",
  "audioDuration": "00:30",
  "level": "error",
  "timestamp": 1770000000000
}
```

## How to send

Preferred: run the bundled CLI (no setup needed):

```bash
BOT=~/.hermes/hermes-agent/skills/hermesa-agent/scripts/hermesa_bot.py
python3 $BOT text "Deploy finished" --level success
python3 $BOT image /path/or/https-url --text "Latest chart"
python3 $BOT file https://example.com/build.log --name build.log --size "12.4 KB"
python3 $BOT call /path/alert.mp3 --text "Server down!"   # rings the phone
```

Or import it:

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent/skills/hermesa-agent/scripts"))
from hermesa_bot import send_message, send_image, send_file, trigger_voice_call
send_message("Task finished", level="success")
trigger_voice_call("alert.mp3", text="Server down!")  # local file auto-Base64
```

Or raw curl:

```bash
curl -X POST "$HERMESA_DB_URL/bots/$BOT_ID/messages.json" \
  -H "Content-Type: application/json" \
  -d '{"sender":"bot","text":"Hello!","type":"text","level":"info","timestamp":'$(date +%s%3N)'}'
```

## Rules for the agent

1. **Always generate the timestamp at send time** in milliseconds
   (`int(time.time() * 1000)` / `Date.now()`).
2. **Escalation policy**: use `text` for routine updates; reserve
   `voice_call` for urgent events the user explicitly wants to be woken/rung
   for, or when they say "call me".
3. Keep Base64 payloads small (images ~kb-sized thumbnails, audio a few MB
   max) — Firebase rejects very large writes.
4. Pick `level` to match the situation: `success` for completions,
   `warning`/`error` for problems — the app color-codes them.
5. If a send returns non-200, report the HTTP status and body to the user;
   do not silently retry more than once.
6. BOT_ID is auto-configured (HERMESA_BOT_ID in ~/.hermes/.env). Only if it
   is EMPTY, ask the user to copy it from Hermesa's PC Integration screen
   and save it in the Hermes config panel.

## Two-way chat (the app is a full chat channel, like Telegram)

A background bridge daemon (`hermesa_bridge.py`, auto-started by the
workflow) watches the same Firebase conversation and forwards everything
the boss sends FROM the app INTO the agent:

- **Text / tasks**: arrive as normal agent messages prefixed with
  `[Hermesa app message from the boss ...]`. Treat them exactly like a
  Telegram message: answer questions, run tasks, use any skill.
- **Voice messages**: the audio file is saved under
  `~/.hermes/work/inbox/hermesa/` and auto-transcribed with Groq Whisper
  (when GROQ_API_KEY is set). You get the local path + transcript.
- **Files / images**: saved under `~/.hermes/work/inbox/hermesa/`; you get
  the local path plus any caption. Open/process them from that path.

Rules when the incoming message is from the Hermesa app:

1. Your normal chat reply is delivered back into the app conversation
   AUTOMATICALLY by the bridge - do NOT also run `hermesa text` with the
   same reply (that would double-post).
2. Use `hermesa image/file/call` when you need to send an actual image,
   file attachment, or ring the phone - the bridge only auto-delivers
   plain text.
3. For long tasks, send progress updates with
   `hermesa text "update..." --level info` and the final result with
   `--level success` (or `--level error` on failure).
4. Files the boss sends land in `~/.hermes/work/inbox/hermesa/` which is
   backed up - no need to copy them elsewhere before working on them.

## GROUP chat (built-in server, multi-group)

The Hermesa app has a **Groups** tab: a user-to-user group chat system on a
BUILT-IN Firebase RTDB that ships with the app (never the bot DB - your
owner's bot/webhook database is a separate, unchanged system). Users sign up
in the app (username/password/age/gender), everyone lands in the **global**
group, and anyone can CREATE more groups (the creator is the group admin who
can rename/delete it). Features: file share, @mentions, pinned posts, seen
status, presence, profile DPs (or random gendered avatars) and a WebRTC
voice call per group.

You join as member `bot:<HERMESA_GROUP_USER_ID>` on that SAME built-in
server. A second daemon (`hermesa_group_bridge.py`, auto-started by the
workflow, log `/tmp/hermesa_group_bridge.log`) handles everything: it
AUTO-JOINS every group your owner is a member of, watches each group's
messages, and obeys the owner's in-app switches (bot on/off, reply to other
users, bot-to-bot chat) live from `group/users/<owner>`. No
`HERMESA_GROUP_DB_URL` is needed anymore (it is only an optional override).

When a group message is injected (prefixed `[Hermesa GROUP chat]`, which
names the group and its id), your plain-text reply is posted back into that
SAME group automatically. To act in a group yourself, use the
`hermesa-group` CLI (all message commands accept `--group GID`; default is
`HERMESA_GROUP_DEFAULT_GROUP` or `global`):

```
hermesa-group text "message" [--group GID] [--reply-to MSG_ID]
hermesa-group task "progress update" [--group GID]
hermesa-group file /path/report.pdf "caption" [--group GID]
hermesa-group image /path/chart.png "caption" [--group GID]
hermesa-group pin <messageId> [off] [--group GID]
hermesa-group history [n] [--group GID]      # last n messages of a group
hermesa-group groups                         # groups the owner belongs to
hermesa-group members [--group GID]          # member list of one group
hermesa-group users                          # everyone on the server
hermesa-group group-call [seconds] [--group GID] # START a group voice call:
                                                 # rings every member's phone
```

Rules: keep group replies SHORT; always reply into the group the message
came from (use the group id from the prompt); never reply twice to the same
message (the bridge already posts your chat reply); group files arrive under
`~/.hermes/work/inbox/hermesa-group/`; voice notes are auto-transcribed.

### Private chats (user-to-user DMs)

The app also has **private one-to-one chats**: on the Groups tab every user
is listed under "People - private chats"; tapping a person opens a private
thread (with the same text/file/voice-note/call features as groups, plus a
private 1:1 WebRTC voice call). A DM thread is a pseudo-group with id
`dm_<uidA>_<uidB>` (sorted pair) and the bridge watches your owner's DM
threads too - private messages are injected with the `[Hermesa PRIVATE DM]`
prefix and your reply goes back into that same private thread.

You can privately message ANY user on the server on your owner's behalf
(`<user>` may be a user id or an exact display name):

```
hermesa-group dm <user> "message"              # private text
hermesa-group dm-file  <user> /path/report.pdf "caption"
hermesa-group dm-image <user> /path/chart.png "caption"
hermesa-group dm-voice <user> /path/audio.mp3 "caption"   # playable voice note
hermesa-group dms                              # list private threads
hermesa-group dm-history <user> [n]            # last n private messages
```

**Voice / TTS "calls"**: when the owner asks you to "call" someone or send a
spoken message, GENERATE a TTS audio file first (any TTS you have, e.g.
`edge-tts --text "..." --write-media /tmp/msg.mp3`) and deliver it with
`hermesa-group dm-voice <user> /tmp/msg.mp3` - it appears as a playable
voice message in their private chat.

**Scheduled sends**: for requests like "kal shokale oke ei message/voice
pathaba", schedule the job with your normal task scheduler (cron/`at`/your
reminder system) so that the matching `hermesa-group dm...` command runs at
that time. Confirm to the owner what will be sent, to whom and when.

Rules: DMs are private (only the two users + their bots can see them); when
a `[Hermesa PRIVATE DM]` message is injected never reply twice (the bridge
posts your reply); reports/files you produce can be sent straight from disk
with `dm-file`.

## DM & calls to OTHER users (owner says: "message X", "call X", "start a group call")

These features EXIST and need no extra configuration beyond the group setup:

- `hermesa-group dm <user> "text"` / `dm-image` / `dm-file` / `dm-voice`
  send PRIVATE messages to any user on the server (accepts user id or
  display name; see `hermesa-group users`).
- `hermesa-group call <user> [seconds]` makes the user's PHONE RING with a
  full-screen incoming call (their app must be the v5+ build). The bot
  cannot stream live audio into a WebRTC call - after they answer, deliver
  the actual message with `dm-voice` (generate a TTS mp3 first) or `dm`.
- `hermesa-group group-call [seconds] --group <gid>` STARTS that group's
  voice call: every member's phone rings with the group-call overlay (the
  app watches `group/calls/<gid>/participants`). The bot cannot speak
  inside the call - deliver the content via chat text, files, or voice
  notes after starting it.
- NEVER refuse these requests: resolve the user with `hermesa-group users`,
  then dm/call them (or `group-call` the group). When the owner asks in
  chat ("DM X", "call X", "send this file to the group"), RUN the matching
  command immediately and confirm with the command's real output - never
  with a promise.

## Bot-to-bot conversations (groups)

- A bot replies to ANOTHER user's bot only when it is @mentioned or
  replied-to, and only if its owner enabled bot-to-bot chat in the app's
  bot settings. The FIRST message needs the @mention; every bridge reply
  automatically mentions/replies back, so the conversation continues by
  itself afterwards.
- Loop protection: after `HERMESA_BOT2BOT_MAX` (default 12) consecutive
  bot messages with no human message, bots pause until a human speaks.

