# Facebook Page Manager

Full control of the boss's Facebook Page from the terminal via the Graph
API (v21.0). A `fb` shim is installed - run `fb --help` any time; it
self-documents even after context compaction.

Config (in `~/.hermes/.env`, set from the config panel):
- `FACEBOOK_PAGE_TOKEN` (required) - a **Page access token**
- `FACEBOOK_PAGE_ID` (optional) - one page id, or comma-separated ids
  (first = default); auto-resolved from the token if empty

Verify the token any time: `fb me` (shows which Page it controls).

## Multiple pages
Put a long-lived USER token in `FACEBOOK_PAGE_TOKEN` - it unlocks every
page the boss manages (the skill auto-fetches each page's own token
from /me/accounts, so every command works per page).
```
fb pages                      # numbered list of manageable pages
fb post "hi" -p 2             # by list index
fb post "hi" -p 1234567890    # by page id
fb reel x.mp4 -p "Shop"       # by name match
```
A single-Page token still works exactly as before (that one page only).

## Posting & media
```
fb post "Big announcement!"                  # publish now
fb post "Read this" --link https://x.com     # link post
fb post "GM!" --schedule "2026-08-20 09:00" --tz +06:00   # native FB scheduling
fb photo ./pic.jpg --caption "nice"          # local file or URL
fb video https://cdn/x.mp4 --title "Demo" --desc "..."
fb posts --limit 10                          # published posts + like/comment counts
fb posts --scheduled                         # queued posts
fb edit <post-id> "new text"
fb del <post-id-or-comment-id>
```
Scheduling is native Facebook (works even when the workflow is down).
Window: 10 minutes to 75 days ahead. Boss timezone: pass `--tz +06:00`.

## Reels, albums & stories
```
fb reel ./clip.mp4 --caption "..." [--schedule "2026-08-20 09:00" --tz +06:00]
fb reel https://cdn/x.mp4 --caption "..."
fb album a.jpg b.jpg c.jpg --caption "trip"   # 2-10 photos in ONE post
fb story ./photo.jpg   |   fb story ./clip.mp4
```
Reel specs: vertical 9:16, 3-90 seconds, min 540x960, mp4. Reels CAN be
scheduled. Stories expire after 24h and CANNOT be scheduled.

## Comments & moderation
```
fb comments <post-id> --limit 25
fb comment <post-or-comment-id> "reply text"   # reply as the Page
fb hide <comment-id>   |  fb unhide <comment-id>
fb like <post-or-comment-id>  |  fb unlike <id>
fb private-reply <comment-id> "we DM'd you!"   # one private reply per comment
fb del <comment-id>
```

## Facebook Live
```
fb live "Title" [--desc "..."]            # create live -> rtmps:// URL + stream key
fb live "Title" --schedule "2026-08-20 21:00" --tz +06:00   # scheduled live
fb golive ./video.mp4 --title "..." [--loop] [--encode]      # create + stream the file
fb live-end <live-video-id>
fb lives                                   # list active/past lives
```
- `fb live` alone gives the RTMP URL - the boss can paste it into
  OBS/phone streaming apps to go live with a real camera.
- `fb golive` streams a video file from the runner with ffmpeg and
  auto-ends the live when the file (or the workflow) stops. `--loop`
  repeats the file forever - good for 24/7 style streams.
- Live needs the `publish_video` permission on the token.
- If ffmpeg is missing: `sudo apt-get install -y ffmpeg`.

## Messenger (as the Page)
```
fb inbox --limit 10          # conversations + unread counts
fb convo <conversation-id>   # read messages
fb send <psid> "text"        # reply (only within 24h of the user's last message)
```

## Analytics & page profile
```
fb insights [--period day|week|days_28] [--metric m1,m2]
fb post-insights <post-id>
fb info                      # name, fans, followers, rating
fb update --about "..." --desc "..." --phone "..." --website "..."
fb ratings                   # reviews
```

## Anything else
```
fb raw GET <PAGE-ID>/feed limit=5
fb raw POST <object-id> key=value ...
fb raw DELETE <object-id>
```

## Honest limits
- Error `code 190` = token expired/invalid: boss must generate a fresh
  Page token and update the config panel. Long-lived user token ->
  `/me/accounts` gives a Page token that does not expire.
- Messenger: a Page can only message people who messaged the Page first,
  and only within a 24h window. `private-reply` works once per comment.
- Insights on brand-new/tiny pages return empty data - not an error.
- Graph API manages **Pages only** - personal profiles and creating
  events are not supported.
- Managing pages the boss does not own requires Meta App Review.
- Rate limits (`code 4/17/32/613`): wait a few minutes, then retry.
