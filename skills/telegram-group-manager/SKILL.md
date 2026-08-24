---
name: telegram-group-manager
description: >-
  Manage the boss's Telegram group(s) as an ADMIN: post and reply in the
  group (including replying to other bots' posts), ban / unban / kick / mute
  members, ADD members via invite links and join-request approval, pin and
  unpin group posts, delete messages, promote / demote admins, rename the
  group and inspect members. Use this skill for ANY Telegram GROUP action
  the boss asks for.
---

# Telegram Group Manager

All group actions go through the preinstalled `tg` terminal command
(shim for this skill's `scripts/tg_group.py`). It talks straight to the
Telegram Bot API with the same bot token as the chat gateway.

`tg --help` and `tg <command> --help` self-document everything.

## Golden rules

1. NEVER call getUpdates or webhook methods yourself (raw curl included).
   The Hermes chat gateway owns long-polling; a second consumer causes
   409 conflicts and disconnects the boss. `tg raw` blocks these methods
   on purpose.
2. The bot must be an ADMIN in the target group with the matching rights
   (ban users, pin messages, invite users, delete messages). If a call
   fails with "not enough rights", tell the boss which admin right to
   grant the bot.
3. Default group = FIRST id in TELEGRAM_GROUP_IDS (config panel,
   Telegram section). Every command accepts `-g <chat-id|@username|index>`
   to target another group. `tg groups` lists what is configured.
4. ADDING USERS: Telegram bots CANNOT force-add a member. "Add user X" =
   `tg invite --limit 1 --hours 24` and send that link to X (or to the
   boss). With `--join-request` links, joins wait for `tg approve <id>`.
5. BOT-TO-BOT: bots never RECEIVE other bots' group messages, but they
   CAN reply to them. Ask the boss for the message link (long-press /
   right-click the message -> Copy Message Link), then:
   `tg reply <t.me link> "text"`. Plain numeric message ids work too.
6. Users are addressed by NUMERIC id. @username only resolves reliably
   for group admins; for normal members ask the boss for the id or take
   it from a forwarded message / join request.

## Roles - multi-user deployments (IMPORTANT)

This same config website + workflow is used by OTHER people with their
own bots. Group adminship is per-deployment, controlled by
TELEGRAM_GROUP_ROLE (config panel, Telegram section):

- auto (default): admin commands are allowed ONLY if this deployment's
  bot really holds admin status in the target group. `tg` verifies the
  bot's actual status before every admin action and refuses with a
  clear explanation when the bot is just a member.
- member: hard-locked member mode. Admin commands (ban, mute, kick,
  pin, invite, promote, title, ...) are disabled in the tool itself,
  even if someone promotes the bot. Member-level commands still work:
  send, reply (incl. bot-to-bot), edit/delete own messages, photo,
  file, info, admins, member, count, groups, me.

When an admin command is refused, do NOT retry or work around it with
`tg raw` (admin methods are blocked there too). Tell the boss plainly:
this deployment is member-level; only the group owner's bot (promoted
to admin in Telegram) can do that.

## Command cheat-sheet

```
tg send "text" [--silent] [--markdown] [--reply-to <id|link>]
tg reply <msg-id | t.me link> "text"      # bot-to-bot replies too
tg edit <msg-id> "new text"               # own messages only
tg delete <msg-id | link> [...]
tg pin <msg-id> [--notify]   |  tg unpin [<msg-id>] [--all]
tg photo <path|url> [--caption "..."]  |  tg file <path|url>
tg ban <user> [--hours 24] [--revoke-messages]
tg unban <user>  |  tg kick <user>
tg mute <user> [--hours 12]  |  tg unmute <user>
tg promote <user> [--title "Moderator"]  |  tg demote <user>
tg invite [--limit N] [--hours N] [--join-request] [--name "..."]
tg approve <user>  |  tg decline <user>  |  tg revoke-invite <link>
tg info  |  tg admins  |  tg member <user>  |  tg count
tg title "New name"  |  tg desc "About text"
tg groups  |  tg me
tg raw <method> '<json>'                  # any other Bot API method
```

## Typical boss requests -> commands

- "post X in the group"            -> tg send "X"
- "reply to that bot's message"    -> tg reply <link boss gives> "text"
- "ban that spammer"               -> tg ban <id> --revoke-messages
- "remove him but he can rejoin"   -> tg kick <id>
- "silence her for a day"          -> tg mute <id> --hours 24
- "add my friend to the group"     -> tg invite --limit 1 ; send link
- "pin that announcement"          -> tg pin <msg-id> --notify
- "make X a moderator"             -> tg promote <id> --title "Moderator"
- "who's in charge here?"          -> tg admins

After every action, confirm to the boss in chat what was done, and
include any generated invite link in full.

## Pro features

### Polls, quizzes & reactions
```
tg poll "Question" "Opt A" "Opt B" [--public] [--multi] [--hours N]
tg quiz "Q" "A" "B" "C" --correct 2 [--explain "why"]
tg stoppoll <msg-id|link>          # close + show results
tg react <msg-id|link> 👍 [--big]  |  tg react <msg> --clear
```

### Media pro + inline buttons
```
tg video/gif/voice/audio/sticker <path|url> [--caption ...]
tg album a.jpg b.jpg c.mp4 --caption "trip"    # 2-10 items, one album
tg location 23.81 90.41  |  tg contact +8801... "Name"
```
Inline buttons on send/reply/photo/file/video/gif/schedule:
`--buttons 'Open|https://x.com, Docs|https://y.com ; Row2|https://z.com'`
URL buttons only - callback buttons need the update stream, which the
Hermes chat gateway owns.

### Scheduled posts (daemon runs while the workflow is up)
```
tg schedule "Good morning!" --daily 09:00 --tz +06:00
tg schedule "Launch!" --at "2026-08-20 18:00" --tz +06:00
tg schedule "Backup reminder" --every 6h
tg jobs  |  tg unschedule <id>
```
ALWAYS convert the boss's local time: pass --tz with their UTC offset
(Bangladesh/Dhaka = +06:00). Jobs live in ~/.hermes/tg_schedule.json and fire
while the workflow runs (they pause if the workflow is down).

### Auto-moderation
```
tg lockdown [--hours 2]   # only admins can post; auto-unlock later
tg unlock
```
Per-user tools stay: tg mute/ban <user> --hours N.

### Forum topics & channels
```
tg topic-new "Support"  |  tg topic-close/reopen/del <id>
tg topic-rename <id> "New name"
tg send "hi" --topic <id>          # post into a topic
tg forward <msg> --to <chat>  |  tg copy <msg> --to <chat>
```
IMPORTANT: the Bot API cannot LIST topics - save ids when creating.
Channels work with -g <channel-id> when the bot is a channel admin.
