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

- **Database URL**: `HERMESA_DB_URL` in `~/.hermes/.env` - the user sets
  their OWN Firebase Realtime Database URL once in the Hermes config panel
  (no built-in default)
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
