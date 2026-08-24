#!/usr/bin/env python3
"""fb - Facebook Page manager for Hermes (Graph API).
Everything a Page can do from the terminal: posts (publish/schedule/edit/
delete), photos & videos, comments + moderation, Messenger inbox/replies,
insights, page profile, ratings, and raw Graph calls.
Config (from ~/.hermes/.env or environment):
  FACEBOOK_PAGE_TOKEN  (required) - a Page access token
  FACEBOOK_PAGE_ID     (optional) - one page id, or comma-separated ids
                       for multi-page mode (first = default)
Multi-page: put a long-lived USER token in FACEBOOK_PAGE_TOKEN, then
`fb pages` lists every page and any command takes -p <id|name|index>.
"""
import argparse
import calendar
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GRAPH = "https://graph.facebook.com/v21.0"
ENV_FILE = os.path.expanduser("~/.hermes/.env")


def _load_env_file():
    if os.path.exists(ENV_FILE):
        for line in open(ENV_FILE):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


_load_env_file()
TOKEN = os.environ.get("FACEBOOK_PAGE_TOKEN", "").strip()
PAGES = [p.strip() for p in os.environ.get("FACEBOOK_PAGE_ID", "").split(",") if p.strip()]
PAGE = PAGES[0] if PAGES else ""


def die(msg):
    print("fb: " + msg, file=sys.stderr)
    sys.exit(1)


def show(obj):
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def api(path, params=None, method="GET", soft=False):
    if not TOKEN:
        die("FACEBOOK_PAGE_TOKEN is not set - add it in the config panel (Facebook section)")
    params = {k: v for k, v in (params or {}).items() if v is not None}
    params["access_token"] = TOKEN
    data = urllib.parse.urlencode(params, doseq=True)
    url = GRAPH + "/" + path.lstrip("/")
    if method == "GET":
        req = urllib.request.Request(url + "?" + data)
    else:
        req = urllib.request.Request(url, data=data.encode(), method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if soft:
            return None
        try:
            err = json.load(e).get("error", {})
        except Exception:
            die("HTTP %s on %s" % (e.code, path))
        code = err.get("code")
        hint = ""
        if code == 190:
            hint = " (token expired/invalid - generate a fresh Page token and update the config panel)"
        elif code in (4, 17, 32, 613):
            hint = " (rate limited - wait a few minutes and retry)"
        elif code in (10, 200, 210) or err.get("type") == "OAuthException":
            hint = " (this Page token is missing a permission for that action)"
        die("%s [code %s]%s" % (err.get("message", "unknown error"), code, hint))
    except urllib.error.URLError as e:
        if soft:
            return None
        die("network error: %s" % e.reason)


def page_id():
    global PAGE
    if not PAGE:
        PAGE = str(api("me", {"fields": "id"})["id"])
    return PAGE


_ACCOUNTS = None


def _accounts():
    global _ACCOUNTS
    if _ACCOUNTS is None:
        r = api("me/accounts", {"fields": "id,name,access_token", "limit": 100}, soft=True)
        _ACCOUNTS = (r or {}).get("data", []) if isinstance(r, dict) else []
    return _ACCOUNTS


def _select_page(sel):
    global TOKEN, PAGE
    if not sel:
        return
    sel = str(sel).strip()
    acc = _accounts()
    if sel.isdigit() and len(sel) <= 2:
        n = int(sel)
        if PAGES and 1 <= n <= len(PAGES):
            sel = PAGES[n - 1]
        elif acc and 1 <= n <= len(acc):
            sel = str(acc[n - 1]["id"])
    for p in acc:
        if str(p.get("id")) == sel or sel.lower() in (p.get("name") or "").lower():
            PAGE = str(p["id"])
            if p.get("access_token"):
                TOKEN = p["access_token"]
            return
    if sel in PAGES or re.match(r"^\d{5,}$", sel):
        PAGE = sel  # explicit id - works if the token has rights on it
        return
    die("page '%s' not found - run `fb pages` to see what this token can manage. "
        "Tip: a long-lived USER token in FACEBOOK_PAGE_TOKEN unlocks ALL your pages; "
        "a single-Page token only manages its own page" % sel)


def cmd_pages(a):
    acc = _accounts()
    if acc:
        for i, p in enumerate(acc, 1):
            mark = " (default)" if str(p.get("id")) == PAGE else ""
            print("%d. %s  id=%s  page-token=%s%s" % (i, p.get("name"), p.get("id"),
                  "yes" if p.get("access_token") else "no", mark))
        print("use -p <index|id|name> on any command to target a page")
    else:
        me = api("me", {"fields": "id,name"})
        print("single-Page token: %s (id=%s)" % (me.get("name"), me.get("id")))
        print("tip: put a long-lived USER token in FACEBOOK_PAGE_TOKEN to manage multiple pages")


def _epoch(when, tz):
    m = re.match(r"^([+-])(\d{1,2}):?(\d{2})$", (tz or "+00:00").strip())
    if not m:
        die("bad --tz, use an offset like +06:00")
    off = (int(m.group(2)) * 3600 + int(m.group(3)) * 60) * (1 if m.group(1) == "+" else -1)
    try:
        t = time.strptime(when.strip(), "%Y-%m-%d %H:%M")
    except ValueError:
        die('bad --schedule time, use "YYYY-MM-DD HH:MM" (with --tz for your offset)')
    ep = calendar.timegm(t) - off
    now = time.time()
    if ep < now + 600:
        die("Facebook requires the scheduled time to be at least 10 minutes in the future")
    if ep > now + 75 * 86400:
        die("Facebook allows scheduling at most 75 days ahead")
    return int(ep)


def _sched(params, a):
    if getattr(a, "schedule", None):
        params["published"] = "false"
        params["scheduled_publish_time"] = _epoch(a.schedule, a.tz)
    return params


def _upload(path, fields, filefield, filepath):
    if not TOKEN:
        die("FACEBOOK_PAGE_TOKEN is not set - add it in the config panel (Facebook section)")
    if not os.path.exists(filepath):
        die("file not found: " + filepath)
    cmd = ["curl", "-sS", "-X", "POST", GRAPH + "/" + path, "-F", "access_token=" + TOKEN]
    for k, v in fields.items():
        if v is not None:
            cmd += ["-F", "%s=%s" % (k, v)]
    cmd += ["-F", "%s=@%s" % (filefield, filepath)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        obj = json.loads(out)
    except Exception:
        die("upload failed: " + out[:300])
    if "error" in obj:
        die(obj["error"].get("message", "upload error"))
    return obj


def _is_url(s):
    return bool(re.match(r"^https?://", s, re.I))


# ── posts ──

def cmd_post(a):
    p = {"message": a.text}
    if a.link:
        p["link"] = a.link
    show(api("%s/feed" % page_id(), _sched(p, a), "POST"))


def cmd_photo(a):
    p = _sched({"caption": a.caption}, a)
    if _is_url(a.source):
        p["url"] = a.source
        show(api("%s/photos" % page_id(), p, "POST"))
    else:
        show(_upload("%s/photos" % page_id(), p, "source", a.source))


def cmd_video(a):
    p = {"description": a.desc, "title": a.title}
    if getattr(a, "schedule", None):
        p["published"] = "false"
        p["scheduled_publish_time"] = _epoch(a.schedule, a.tz)
    if _is_url(a.source):
        p["file_url"] = a.source
        show(api("%s/videos" % page_id(), p, "POST"))
    else:
        show(_upload("%s/videos" % page_id(), p, "source", a.source))


def cmd_edit(a):
    show(api(a.post, {"message": a.text}, "POST"))


def cmd_del(a):
    show(api(a.object, {}, "DELETE"))


def cmd_posts(a):
    if a.scheduled:
        edge, fields = "scheduled_posts", "id,message,scheduled_publish_time"
    else:
        edge, fields = "published_posts", "id,message,created_time,permalink_url,shares,likes.summary(true).limit(0),comments.summary(true).limit(0)"
    show(api("%s/%s" % (page_id(), edge), {"fields": fields, "limit": a.limit}))


RUPLOAD = "https://rupload.facebook.com/video_upload/v21.0"


def _rupload(video_id, source):
    hdrs = ["-H", "Authorization: OAuth " + TOKEN]
    url = RUPLOAD + "/" + video_id
    if _is_url(source):
        cmd = ["curl", "-sS", "-X", "POST", url] + hdrs + ["-H", "file_url: " + source]
    else:
        if not os.path.exists(source):
            die("file not found: " + source)
        cmd = ["curl", "-sS", "-X", "POST", url] + hdrs + [
            "-H", "offset: 0", "-H", "file_size: %d" % os.path.getsize(source),
            "--data-binary", "@" + source]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        obj = json.loads(out)
    except Exception:
        die("video upload failed: " + out[:300])
    if obj.get("success") is False or "error" in obj:
        die("video upload failed: " + str(obj.get("error") or obj)[:300])
    return obj


def cmd_reel(a):
    start = api("%s/video_reels" % page_id(), {"upload_phase": "start"}, "POST")
    vid = str(start.get("video_id") or "") or die("no video_id from start phase")
    _rupload(vid, a.source)
    p = {"upload_phase": "finish", "video_id": vid,
         "description": a.caption, "video_state": "PUBLISHED"}
    if getattr(a, "schedule", None):
        p["video_state"] = "SCHEDULED"
        p["scheduled_publish_time"] = _epoch(a.schedule, a.tz)
    show(api("%s/video_reels" % page_id(), p, "POST"))


def _photo_id(source):
    if _is_url(source):
        r = api("%s/photos" % page_id(), {"url": source, "published": "false"}, "POST")
    else:
        r = _upload("%s/photos" % page_id(), {"published": "false"}, "source", source)
    return str(r["id"])


def cmd_album(a):
    if not 2 <= len(a.sources) <= 10:
        die("album needs 2-10 photos (got %d)" % len(a.sources))
    p = _sched({"message": a.caption}, a)
    for i, s in enumerate(a.sources):
        p["attached_media[%d]" % i] = json.dumps({"media_fbid": _photo_id(s)})
    show(api("%s/feed" % page_id(), p, "POST"))


def cmd_story(a):
    s = a.source
    base = s.split("?")[0].lower()
    if a.video or base.endswith((".mp4", ".mov", ".m4v")):
        start = api("%s/video_stories" % page_id(), {"upload_phase": "start"}, "POST")
        vid = str(start.get("video_id") or "") or die("no video_id from start phase")
        _rupload(vid, s)
        show(api("%s/video_stories" % page_id(), {"upload_phase": "finish", "video_id": vid}, "POST"))
    else:
        show(api("%s/photo_stories" % page_id(), {"photo_id": _photo_id(s)}, "POST"))


# ── comments & moderation ──

def cmd_comments(a):
    show(api("%s/comments" % a.post, {
        "fields": "id,from,message,created_time,like_count,comment_count,is_hidden",
        "limit": a.limit, "order": "reverse_chronological"}))


def cmd_comment(a):
    show(api("%s/comments" % a.object, {"message": a.text}, "POST"))


def cmd_hide(a):
    show(api(a.comment, {"is_hidden": "true"}, "POST"))


def cmd_unhide(a):
    show(api(a.comment, {"is_hidden": "false"}, "POST"))


def cmd_like(a):
    show(api("%s/likes" % a.object, {}, "POST"))


def cmd_unlike(a):
    show(api("%s/likes" % a.object, {}, "DELETE"))


def cmd_private_reply(a):
    show(api("%s/private_replies" % a.comment, {"message": a.text}, "POST"))


# ── live ──

def _live_create(title, desc, status, planned=None):
    p = {"title": title, "description": desc, "status": status,
         "fields": "id,stream_url,secure_stream_url,permalink_url"}
    if planned:
        p["planned_start_time"] = planned
    return api("%s/live_videos" % page_id(), p, "POST")


def cmd_live(a):
    if getattr(a, "schedule", None):
        show(_live_create(a.title, a.desc, "SCHEDULED_UNPUBLISHED", _epoch(a.schedule, a.tz)))
    else:
        show(_live_create(a.title, a.desc, "LIVE_NOW"))


def cmd_golive(a):
    if not _is_url(a.source) and not os.path.exists(a.source):
        die("file not found: " + a.source)
    if not shutil.which("ffmpeg"):
        die("ffmpeg is not installed - run: sudo apt-get install -y ffmpeg")
    r = _live_create(a.title, a.desc, "LIVE_NOW")
    show(r)
    url = r.get("secure_stream_url") or r.get("stream_url") or die("no stream URL returned")
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-re"]
    if a.loop:
        cmd += ["-stream_loop", "-1"]
    cmd += ["-i", a.source]
    if a.encode:
        cmd += ["-c:v", "libx264", "-preset", "veryfast", "-b:v", "3000k",
                "-maxrate", "3000k", "-bufsize", "6000k", "-g", "60",
                "-c:a", "aac", "-b:a", "128k", "-ar", "44100"]
    else:
        cmd += ["-c", "copy"]
    cmd += ["-f", "flv", url]
    print("fb: streaming %s -> live video %s" % (a.source, r.get("id")))
    try:
        subprocess.run(cmd)
    finally:
        api(str(r["id"]), {"end_live_video": "true"}, "POST")
        print("fb: live ended")


def cmd_live_end(a):
    show(api(a.live_id, {"end_live_video": "true"}, "POST"))


def cmd_lives(a):
    show(api("%s/live_videos" % page_id(), {
        "fields": "id,title,status,permalink_url,creation_time", "limit": a.limit}))


# ── messenger ──

def cmd_inbox(a):
    show(api("%s/conversations" % page_id(), {
        "fields": "id,snippet,updated_time,unread_count,participants", "limit": a.limit}))


def cmd_convo(a):
    show(api("%s/messages" % a.conversation, {
        "fields": "from,message,created_time,attachments", "limit": a.limit}))


def cmd_send(a):
    show(api("%s/messages" % page_id(), {
        "recipient": json.dumps({"id": a.psid}),
        "message": json.dumps({"text": a.text}),
        "messaging_type": "RESPONSE"}, "POST"))


# ── insights & page ──

def cmd_insights(a):
    show(api("%s/insights" % page_id(), {"metric": a.metric, "period": a.period}))


def cmd_post_insights(a):
    show(api("%s/insights" % a.post, {
        "metric": "post_impressions,post_impressions_unique,post_clicks,post_reactions_by_type_total"}))


def cmd_info(a):
    show(api(page_id(), {"fields": "id,name,about,description,category,fan_count,followers_count,link,phone,website,emails,is_published,overall_star_rating,rating_count"}))


def cmd_update(a):
    p = {"about": a.about, "description": a.desc, "phone": a.phone, "website": a.website}
    if not any(v is not None for v in p.values()):
        die("nothing to update - pass --about / --desc / --phone / --website")
    show(api(page_id(), p, "POST"))


def cmd_ratings(a):
    show(api("%s/ratings" % page_id(), {"fields": "review_text,rating,created_time", "limit": a.limit}))


def cmd_me(a):
    show(api("me", {"fields": "id,name,category,link"}))


def cmd_raw(a):
    method = a.method.upper()
    if method not in ("GET", "POST", "DELETE"):
        die("method must be GET, POST or DELETE")
    params = {}
    for pair in a.params:
        if "=" not in pair:
            die("raw params must be key=value, got: " + pair)
        k, v = pair.split("=", 1)
        params[k] = v
    show(api(a.path, params, method))


def main():
    ap = argparse.ArgumentParser(prog="fb", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def sp(name, fn, help_):
        s = sub.add_parser(name, help=help_)
        s.set_defaults(fn=fn)
        s.add_argument("-p", "--page", help="target page: id, name match, or list index")
        return s

    def sched_opts(s):
        s.add_argument("--schedule", metavar='"YYYY-MM-DD HH:MM"', help="native FB scheduling (10 min - 75 days ahead)")
        s.add_argument("--tz", default="+00:00", help="UTC offset for --schedule, e.g. +06:00")

    s = sp("post", cmd_post, "publish or schedule a text/link post")
    s.add_argument("text"); s.add_argument("--link"); sched_opts(s)
    s = sp("photo", cmd_photo, "post a photo (local file or URL)")
    s.add_argument("source"); s.add_argument("--caption"); sched_opts(s)
    s = sp("video", cmd_video, "post a video (local file or URL)")
    s.add_argument("source"); s.add_argument("--title"); s.add_argument("--desc"); sched_opts(s)
    s = sp("edit", cmd_edit, "edit a post's text")
    s.add_argument("post"); s.add_argument("text")
    s = sp("del", cmd_del, "delete a post or comment by id")
    s.add_argument("object")
    s = sp("posts", cmd_posts, "list published posts (--scheduled for queued ones)")
    s.add_argument("--limit", type=int, default=10); s.add_argument("--scheduled", action="store_true")
    s = sp("comments", cmd_comments, "list comments on a post")
    s.add_argument("post"); s.add_argument("--limit", type=int, default=25)
    s = sp("comment", cmd_comment, "comment on a post / reply to a comment")
    s.add_argument("object"); s.add_argument("text")
    s = sp("hide", cmd_hide, "hide a comment"); s.add_argument("comment")
    s = sp("unhide", cmd_unhide, "unhide a comment"); s.add_argument("comment")
    s = sp("like", cmd_like, "like a post/comment as the Page"); s.add_argument("object")
    s = sp("unlike", cmd_unlike, "remove the Page's like"); s.add_argument("object")
    s = sp("private-reply", cmd_private_reply, "send a private Messenger reply to a commenter")
    s.add_argument("comment"); s.add_argument("text")
    s = sp("inbox", cmd_inbox, "list Messenger conversations")
    s.add_argument("--limit", type=int, default=10)
    s = sp("convo", cmd_convo, "read messages in a conversation")
    s.add_argument("conversation"); s.add_argument("--limit", type=int, default=25)
    s = sp("send", cmd_send, "send a Messenger message (24h window)")
    s.add_argument("psid"); s.add_argument("text")
    s = sp("insights", cmd_insights, "page analytics")
    s.add_argument("--metric", default="page_impressions_unique,page_post_engagements,page_fans")
    s.add_argument("--period", default="day", choices=["day", "week", "days_28"])
    s = sp("post-insights", cmd_post_insights, "analytics for one post")
    s.add_argument("post")
    sp("info", cmd_info, "page profile, fans, rating")
    s = sp("update", cmd_update, "update page about/description/phone/website")
    s.add_argument("--about"); s.add_argument("--desc"); s.add_argument("--phone"); s.add_argument("--website")
    s = sp("ratings", cmd_ratings, "page reviews")
    s.add_argument("--limit", type=int, default=10)
    sp("me", cmd_me, "verify the token / show which Page it controls")
    s = sp("reel", cmd_reel, "publish a Reel (vertical video, can be scheduled)")
    s.add_argument("source"); s.add_argument("--caption"); sched_opts(s)
    s = sp("album", cmd_album, "one post with 2-10 photos")
    s.add_argument("sources", nargs="+"); s.add_argument("--caption"); sched_opts(s)
    s = sp("story", cmd_story, "post a photo/video Story (24h)")
    s.add_argument("source"); s.add_argument("--video", action="store_true", help="force video story")
    s = sp("live", cmd_live, "create a live video - returns the RTMP stream URL (schedulable)")
    s.add_argument("title"); s.add_argument("--desc"); sched_opts(s)
    s = sp("golive", cmd_golive, "create live AND stream a video file via ffmpeg")
    s.add_argument("source"); s.add_argument("--title", default="Live"); s.add_argument("--desc")
    s.add_argument("--loop", action="store_true", help="loop the file forever")
    s.add_argument("--encode", action="store_true", help="re-encode for compatibility")
    s = sp("live-end", cmd_live_end, "end a live video")
    s.add_argument("live_id")
    s = sp("lives", cmd_lives, "list live videos")
    s.add_argument("--limit", type=int, default=10)
    sp("pages", cmd_pages, "list all pages this token can manage")
    s = sp("raw", cmd_raw, "raw Graph API call: fb raw GET PAGE_ID/feed limit=5")
    s.add_argument("method"); s.add_argument("path"); s.add_argument("params", nargs="*")

    args = ap.parse_args()
    _select_page(getattr(args, "page", None))
    args.fn(args)


if __name__ == "__main__":
    main()
