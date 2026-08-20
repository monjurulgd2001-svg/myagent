#!/usr/bin/env python3
"""Hermes email toolkit - one CLI for EVERY email task.
Multi-account + multi-provider (Gmail / Yahoo / Outlook / custom IMAP).
Accounts: ~/.hermes/email-accounts.txt, one "email : app-password" per line
(first line = default). Pick another with --account <email or substring>.
Never prints passwords. Run with --help or <command> --help for usage.
"""
import argparse, csv, datetime, email, imaplib, mimetypes, os, re, smtplib, ssl, sys, time
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr

HOME = os.path.expanduser("~/.hermes")
ACCOUNTS_FILE = os.path.join(HOME, "email-accounts.txt")
OUTBOX = os.path.join(HOME, "work", "outputs")

PROVIDERS = [
    {"domains": ["gmail.com", "googlemail.com"], "imap": "imap.gmail.com",
     "smtp": ("smtp.gmail.com", 465, "ssl"), "trash": ["[Gmail]/Trash", "Trash"],
     "archive": [], "gmail": True},
    {"domains": ["yahoo.", "ymail.com", "rocketmail.com"], "imap": "imap.mail.yahoo.com",
     "smtp": ("smtp.mail.yahoo.com", 465, "ssl"), "trash": ["Trash"], "archive": ["Archive"]},
    {"domains": ["outlook.", "hotmail.", "live.", "msn.com"], "imap": "outlook.office365.com",
     "smtp": ("smtp-mail.outlook.com", 587, "starttls"), "trash": ["Deleted Items", "Deleted"],
     "archive": ["Archive"]},
]

def provider_for(addr):
    dom = addr.rsplit("@", 1)[-1].lower()
    for p in PROVIDERS:
        for d in p["domains"]:
            if dom == d or (d.endswith(".") and dom.startswith(d)):
                return p
    return {"domains": [dom], "imap": "imap." + dom, "smtp": ("smtp." + dom, 465, "ssl"),
            "trash": ["Trash"], "archive": ["Archive"]}

def load_accounts():
    if not os.path.exists(ACCOUNTS_FILE):
        sys.exit("No email accounts configured - ask the user to add them in the setup panel.")
    accts = []
    for line in open(ACCOUNTS_FILE, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line and ":" in line:
            a, p = line.split(":", 1)
            accts.append((a.strip(), p.strip().replace(" ", "")))
    if not accts:
        sys.exit("email-accounts.txt is empty - ask the user to add accounts in the setup panel.")
    return accts

def pick_account(sel):
    accts = load_accounts()
    if not sel:
        return accts[0]
    for a in accts:
        if sel.lower() in a[0].lower():
            return a
    sys.exit("No account matching '%s'. Configured: %s" % (sel, ", ".join(a[0] for a in accts)))

def imap_connect(addr, pw):
    M = imaplib.IMAP4_SSL(provider_for(addr)["imap"], 993)
    M.login(addr, pw)
    return M

def smtp_send(addr, pw, msg):
    host, port, mode = provider_for(addr)["smtp"]
    ctx = ssl.create_default_context()
    if mode == "ssl":
        server = smtplib.SMTP_SSL(host, port, context=ctx, timeout=60)
    else:
        server = smtplib.SMTP(host, port, timeout=60)
    with server:
        if mode != "ssl":
            server.starttls(context=ctx)
        server.login(addr, pw)
        server.send_message(msg)

def dec(s):
    try:
        return str(make_header(decode_header(s or ""))).strip()
    except Exception:
        return (s or "").strip()

def imap_date(s):
    return datetime.date.fromisoformat(s).strftime("%d-%b-%Y")

def build_criteria(a):
    crit = []
    if getattr(a, "unread", False): crit.append("UNSEEN")
    if getattr(a, "from_", None): crit += ["FROM", '"%s"' % a.from_]
    if getattr(a, "to", None): crit += ["TO", '"%s"' % a.to]
    if getattr(a, "subject", None): crit += ["SUBJECT", '"%s"' % a.subject]
    if getattr(a, "text", None): crit += ["TEXT", '"%s"' % a.text]
    if getattr(a, "since", None): crit += ["SINCE", imap_date(a.since)]
    if getattr(a, "before", None): crit += ["BEFORE", imap_date(a.before)]
    return crit or ["ALL"]

def uid_search(M, folder, crit, readonly=True):
    st, _ = M.select('"%s"' % folder, readonly=readonly)
    if st != "OK":
        sys.exit("Cannot open folder: %s" % folder)
    st, data = M.uid("search", None, *crit)
    if st != "OK":
        sys.exit("IMAP search failed")
    return data[0].split()

def fetch_headers(M, uid):
    st, data = M.uid("fetch", uid, "(FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])")
    if st != "OK" or not data or data[0] is None:
        return None
    flags = " ".join(imaplib.ParseFlags(data[0][0]) and [f.decode() for f in imaplib.ParseFlags(data[0][0])] or [])
    msg = email.message_from_bytes(data[0][1])
    return {"uid": uid.decode(), "unread": "\\Seen" not in flags,
            "from": dec(msg.get("From")), "to": dec(msg.get("To")),
            "subject": dec(msg.get("Subject")) or "(no subject)", "date": dec(msg.get("Date"))}

def print_rows(M, uids, limit):
    uids = uids[-limit:][::-1]
    for u in uids:
        h = fetch_headers(M, u)
        if h:
            print("%s | %s | %s | %s | %s" % (h["uid"], "NEW" if h["unread"] else "   ",
                                              h["date"][:22], h["from"][:45], h["subject"][:70]))
    print("-- %d shown (uid | status | date | from | subject)" % len(uids))

def body_text(msg, limit):
    text = ""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and "attachment" not in str(part.get("Content-Disposition") or ""):
                text = (part.get_payload(decode=True) or b"").decode(part.get_content_charset() or "utf-8", "replace")
                break
        if not text:
            for part in msg.walk():
                if part.get_content_type() == "text/html":
                    html = (part.get_payload(decode=True) or b"").decode(part.get_content_charset() or "utf-8", "replace")
                    text = re.sub(r"<[^>]+>", " ", html)
                    break
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            text = payload.decode(msg.get_content_charset() or "utf-8", "replace")
            if msg.get_content_type() == "text/html":
                text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    return text[:limit] + ("\n[... truncated, use --chars for more ...]" if len(text) > limit else "")

def fetch_full(M, uid):
    st, data = M.uid("fetch", uid, "(BODY.PEEK[])")
    if st != "OK" or not data or data[0] is None:
        sys.exit("Message uid %s not found" % uid)
    return email.message_from_bytes(data[0][1])

def find_folder(M, candidates):
    st, boxes = M.list()
    names = []
    if st == "OK":
        for b in boxes or []:
            m = re.search(rb'"([^"]+)"$|\s(\S+)$', b or b"")
            if m:
                names.append((m.group(1) or m.group(2)).decode(errors="replace"))
    for c in candidates:
        for n in names:
            if c.lower() in n.lower():
                return n
    return candidates[0] if candidates else None

def build_message(addr, to, subject, body, html=False, cc=None, bcc=None, attach=None, extra=None):
    m = EmailMessage()
    m["From"] = addr
    m["To"] = to
    m["Subject"] = subject
    if cc: m["Cc"] = cc
    if bcc: m["Bcc"] = bcc
    m["Date"] = formatdate(localtime=True)
    m["Message-ID"] = make_msgid()
    for k, v in (extra or {}).items():
        m[k] = v
    if html:
        m.set_content(re.sub(r"<[^>]+>", " ", body))
        m.add_alternative(body, subtype="html")
    else:
        m.set_content(body)
    for path in attach or []:
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        maint, sub = ctype.split("/", 1)
        with open(path, "rb") as f:
            m.add_attachment(f.read(), maintype=maint, subtype=sub, filename=os.path.basename(path))
    return m

def expunge_uids(M, uids):
    M.uid("store", b",".join(uids), "+FLAGS", "(\\Deleted)")
    M.expunge()

# ---------------- commands ----------------

def cmd_accounts(a):
    accts = load_accounts()
    for i, (addr, _) in enumerate(accts):
        print("%s%s" % (addr, "  (default)" if i == 0 else ""))

def cmd_folders(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    st, boxes = M.list()
    for b in boxes or []:
        print(b.decode(errors="replace"))
    M.logout()

def cmd_list(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    uids = uid_search(M, a.folder, build_criteria(a))
    print("Account: %s | Folder: %s | Matches: %d" % (addr, a.folder, len(uids)))
    print_rows(M, uids, a.limit)
    M.logout()

def cmd_read(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    uid_search(M, a.folder, ["ALL"])
    msg = fetch_full(M, a.uid.encode())
    print("From: %s\nTo: %s\nDate: %s\nSubject: %s" % (dec(msg.get("From")), dec(msg.get("To")), dec(msg.get("Date")), dec(msg.get("Subject"))))
    atts = [dec(p.get_filename()) for p in msg.walk() if p.get_filename()]
    if atts:
        print("Attachments: %s" % ", ".join(atts))
    print("---")
    print(body_text(msg, a.chars))
    if not a.keep_unread:
        M.select('"%s"' % a.folder)
        M.uid("store", a.uid.encode(), "+FLAGS", "(\\Seen)")
    M.logout()

def cmd_stats(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    st, data = M.status('"%s"' % a.folder, "(MESSAGES UNSEEN)")
    print("Account: %s | %s" % (addr, (data[0] or b"").decode(errors="replace")))
    uids = uid_search(M, a.folder, ["ALL"])
    sample = uids[-a.sample:]
    senders, subjects_unread = {}, []
    for u in sample:
        h = fetch_headers(M, u)
        if not h:
            continue
        nm, em = parseaddr(h["from"])
        key = em.lower() or h["from"]
        senders[key] = senders.get(key, 0) + 1
        if h["unread"] and len(subjects_unread) < 10:
            subjects_unread.append("%s | %s | %s" % (h["uid"], h["from"][:40], h["subject"][:60]))
    print("Top senders (last %d mails):" % len(sample))
    for em, n in sorted(senders.items(), key=lambda x: -x[1])[:a.top]:
        print("  %4d  %s" % (n, em))
    if subjects_unread:
        print("Recent unread:")
        for s in subjects_unread:
            print("  " + s)
    M.logout()

def cmd_send(a):
    addr, pw = pick_account(a.account)
    body = open(a.body_file, encoding="utf-8").read() if a.body_file else a.body
    if body is None:
        sys.exit("Provide --body or --body-file")
    msg = build_message(addr, a.to, a.subject, body, html=a.html, cc=a.cc, bcc=a.bcc, attach=a.attach)
    smtp_send(addr, pw, msg)
    print("Sent to %s from %s (subject: %s)" % (a.to, addr, a.subject))

def cmd_reply(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    uid_search(M, a.folder, ["ALL"])
    orig = fetch_full(M, a.uid.encode())
    M.logout()
    to = a.to or (parseaddr(orig.get("Reply-To") or orig.get("From"))[1])
    subj = dec(orig.get("Subject")) or ""
    if not subj.lower().startswith("re:"):
        subj = "Re: " + subj
    extra = {}
    if orig.get("Message-ID"):
        extra["In-Reply-To"] = orig["Message-ID"]
        extra["References"] = ((orig.get("References") or "") + " " + orig["Message-ID"]).strip()
    body = open(a.body_file, encoding="utf-8").read() if a.body_file else a.body
    if body is None:
        sys.exit("Provide --body or --body-file")
    msg = build_message(addr, to, subj, body, html=a.html, cc=a.cc, attach=a.attach, extra=extra)
    smtp_send(addr, pw, msg)
    print("Replied to %s (subject: %s)" % (to, subj))

def cmd_forward(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    uid_search(M, a.folder, ["ALL"])
    orig = fetch_full(M, a.uid.encode())
    M.logout()
    subj = dec(orig.get("Subject")) or ""
    if not subj.lower().startswith("fwd:"):
        subj = "Fwd: " + subj
    note = (a.body or "") + "\n\n---------- Forwarded message ----------\nFrom: %s\nDate: %s\nSubject: %s\n\n%s" % (
        dec(orig.get("From")), dec(orig.get("Date")), dec(orig.get("Subject")), body_text(orig, 20000))
    msg = build_message(addr, a.to, subj, note)
    smtp_send(addr, pw, msg)
    print("Forwarded uid %s to %s" % (a.uid, a.to))

def cmd_bulk_send(a):
    addr, pw = pick_account(a.account)
    rows = []
    if a.csv:
        with open(a.csv, newline="", encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                r = {k.strip(): (v or "").strip() for k, v in r.items()}
                if r.get("email"):
                    rows.append(r)
    elif a.to_list:
        rows = [{"email": e.strip()} for e in a.to_list.split(",") if e.strip()]
    if not rows:
        sys.exit("No recipients (need --csv with an 'email' column, or --to-list)")
    body_tpl = open(a.body_file, encoding="utf-8").read() if a.body_file else a.body
    if body_tpl is None:
        sys.exit("Provide --body or --body-file")
    if not a.yes:
        print("DRY RUN - would send to %d recipients from %s:" % (len(rows), addr))
        for r in rows[:8]:
            print("  %s | subject: %s" % (r["email"], safe_format(a.subject, r)))
        if len(rows) > 8:
            print("  ... and %d more" % (len(rows) - 8))
        print("Re-run with --yes to actually send (delay between mails: %ss)." % a.delay)
        return
    sent, failed = 0, []
    for i, r in enumerate(rows, 1):
        try:
            msg = build_message(addr, r["email"], safe_format(a.subject, r), safe_format(body_tpl, r), html=a.html, attach=a.attach)
            smtp_send(addr, pw, msg)
            sent += 1
            print("[%d/%d] sent -> %s" % (i, len(rows), r["email"]))
        except Exception as e:
            failed.append("%s (%s)" % (r["email"], e))
            print("[%d/%d] FAILED -> %s : %s" % (i, len(rows), r["email"], e))
        if i < len(rows):
            time.sleep(a.delay)
    print("Done. Sent %d/%d." % (sent, len(rows)))
    if failed:
        print("Failed: " + "; ".join(failed))

def safe_format(tpl, row):
    class D(dict):
        def __missing__(self, k):
            return ""
    return tpl.format_map(D(row))

def _uid_list(a):
    return [u.strip().encode() for u in a.uids.split(",") if u.strip()]

def cmd_mark(a, seen):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    M.select('"%s"' % a.folder)
    M.uid("store", b",".join(_uid_list(a)), ("+FLAGS" if seen else "-FLAGS"), "(\\Seen)")
    M.logout()
    print("Marked %s uid(s) as %s" % (len(_uid_list(a)), "read" if seen else "unread"))

def cmd_move(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    M.select('"%s"' % a.folder)
    uids = _uid_list(a)
    M.uid("copy", b",".join(uids), '"%s"' % a.to_folder)
    expunge_uids(M, uids)
    M.logout()
    print("Moved %d mail(s) %s -> %s" % (len(uids), a.folder, a.to_folder))

def cmd_archive(a):
    addr, pw = pick_account(a.account)
    p = provider_for(addr)
    M = imap_connect(addr, pw)
    M.select('"%s"' % a.folder)
    uids = _uid_list(a)
    if p.get("gmail"):
        expunge_uids(M, uids)  # removing from INBOX archives in Gmail (stays in All Mail)
    else:
        dest = find_folder(M, p["archive"]) or "Archive"
        M.uid("copy", b",".join(uids), '"%s"' % dest)
        expunge_uids(M, uids)
    M.logout()
    print("Archived %d mail(s)" % len(uids))

def cmd_delete(a):
    addr, pw = pick_account(a.account)
    p = provider_for(addr)
    M = imap_connect(addr, pw)
    M.select('"%s"' % a.folder)
    uids = _uid_list(a)
    if a.forever:
        expunge_uids(M, uids)
    else:
        trash = find_folder(M, p["trash"]) or "Trash"
        M.uid("copy", b",".join(uids), '"%s"' % trash)
        expunge_uids(M, uids)
    M.logout()
    print("Deleted %d mail(s)%s" % (len(uids), " permanently" if a.forever else " (moved to Trash)"))

def cmd_clean(a):
    addr, pw = pick_account(a.account)
    p = provider_for(addr)
    M = imap_connect(addr, pw, )
    uids = uid_search(M, a.folder, build_criteria(a), readonly=not a.yes)
    print("Account: %s | Folder: %s | Matches: %d" % (addr, a.folder, len(uids)))
    if not uids:
        M.logout()
        return
    print_rows(M, uids, min(len(uids), 10))
    if not a.yes:
        print("DRY RUN - nothing changed. Show this preview to the user; after an explicit YES,")
        print("re-run the exact same command with --yes to %s these %d mail(s)." % (a.action, len(uids)))
        M.logout()
        return
    if a.action == "delete":
        trash = find_folder(M, p["trash"]) or "Trash"
        M.uid("copy", b",".join(uids), '"%s"' % trash)
        expunge_uids(M, uids)
    elif a.action == "archive":
        if p.get("gmail"):
            expunge_uids(M, uids)
        else:
            dest = find_folder(M, p["archive"]) or "Archive"
            M.uid("copy", b",".join(uids), '"%s"' % dest)
            expunge_uids(M, uids)
    elif a.action == "read":
        M.uid("store", b",".join(uids), "+FLAGS", "(\\Seen)")
    M.logout()
    print("Cleaned %d mail(s) (%s)." % (len(uids), a.action))

def cmd_attachments(a):
    addr, pw = pick_account(a.account)
    M = imap_connect(addr, pw)
    uid_search(M, a.folder, ["ALL"])
    msg = fetch_full(M, a.uid.encode())
    M.logout()
    os.makedirs(a.save_dir, exist_ok=True)
    saved = []
    for part in msg.walk():
        fn = part.get_filename()
        if fn:
            fn = re.sub(r"[^\w.\- ]", "_", dec(fn)) or "attachment.bin"
            path = os.path.join(a.save_dir, fn)
            with open(path, "wb") as f:
                f.write(part.get_payload(decode=True) or b"")
            saved.append(path)
    print("Saved %d attachment(s):" % len(saved))
    for s in saved:
        print("  " + s)

# ---------------- argparse ----------------

def add_common(sp, folder=True):
    sp.add_argument("--account", help="email or substring; default = first configured account")
    if folder:
        sp.add_argument("--folder", default="INBOX")

def add_search_args(sp):
    sp.add_argument("--from", dest="from_")
    sp.add_argument("--to")
    sp.add_argument("--subject")
    sp.add_argument("--text")
    sp.add_argument("--since", help="YYYY-MM-DD")
    sp.add_argument("--before", help="YYYY-MM-DD")
    sp.add_argument("--unread", action="store_true")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("accounts", help="list configured accounts")
    s.set_defaults(fn=cmd_accounts)

    s = sub.add_parser("folders", help="list mailbox folders")
    add_common(s, folder=False)
    s.set_defaults(fn=cmd_folders)

    s = sub.add_parser("list", help="list/search mails (newest first)")
    add_common(s); add_search_args(s)
    s.add_argument("--limit", type=int, default=10)
    s.set_defaults(fn=cmd_list)

    s = sub.add_parser("read", help="read one mail by uid")
    add_common(s)
    s.add_argument("uid")
    s.add_argument("--chars", type=int, default=4000)
    s.add_argument("--keep-unread", action="store_true")
    s.set_defaults(fn=cmd_read)

    s = sub.add_parser("stats", help="inbox analysis: counts, top senders, recent unread")
    add_common(s)
    s.add_argument("--sample", type=int, default=200)
    s.add_argument("--top", type=int, default=10)
    s.set_defaults(fn=cmd_stats)

    s = sub.add_parser("send", help="send one mail")
    add_common(s, folder=False)
    s.add_argument("--to", required=True)
    s.add_argument("--subject", required=True)
    s.add_argument("--body"); s.add_argument("--body-file")
    s.add_argument("--html", action="store_true")
    s.add_argument("--cc"); s.add_argument("--bcc")
    s.add_argument("--attach", action="append")
    s.set_defaults(fn=cmd_send)

    s = sub.add_parser("reply", help="reply to a mail (threads correctly)")
    add_common(s)
    s.add_argument("uid")
    s.add_argument("--body"); s.add_argument("--body-file")
    s.add_argument("--to", help="override recipient")
    s.add_argument("--html", action="store_true")
    s.add_argument("--cc")
    s.add_argument("--attach", action="append")
    s.set_defaults(fn=cmd_reply)

    s = sub.add_parser("forward", help="forward a mail")
    add_common(s)
    s.add_argument("uid")
    s.add_argument("--to", required=True)
    s.add_argument("--body", help="note above the forwarded text")
    s.set_defaults(fn=cmd_forward)

    s = sub.add_parser("bulk-send", help="personalized 1-by-1 bulk send (dry-run unless --yes)")
    add_common(s, folder=False)
    s.add_argument("--csv", help="CSV with 'email' column; other columns usable as {placeholders}")
    s.add_argument("--to-list", help="comma separated addresses")
    s.add_argument("--subject", required=True)
    s.add_argument("--body"); s.add_argument("--body-file")
    s.add_argument("--html", action="store_true")
    s.add_argument("--attach", action="append")
    s.add_argument("--delay", type=float, default=3.0)
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_bulk_send)

    s = sub.add_parser("mark-read", help="mark uids read")
    add_common(s); s.add_argument("uids")
    s.set_defaults(fn=lambda a: cmd_mark(a, True))

    s = sub.add_parser("mark-unread", help="mark uids unread")
    add_common(s); s.add_argument("uids")
    s.set_defaults(fn=lambda a: cmd_mark(a, False))

    s = sub.add_parser("move", help="move uids to another folder")
    add_common(s); s.add_argument("uids"); s.add_argument("--to-folder", required=True)
    s.set_defaults(fn=cmd_move)

    s = sub.add_parser("archive", help="archive uids")
    add_common(s); s.add_argument("uids")
    s.set_defaults(fn=cmd_archive)

    s = sub.add_parser("delete", help="delete uids (to Trash unless --forever)")
    add_common(s); s.add_argument("uids")
    s.add_argument("--forever", action="store_true")
    s.set_defaults(fn=cmd_delete)

    s = sub.add_parser("clean", help="bulk clean by search criteria (dry-run unless --yes)")
    add_common(s); add_search_args(s)
    s.add_argument("--action", choices=["delete", "archive", "read"], default="delete")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_clean)

    s = sub.add_parser("attachments", help="save a mail's attachments")
    add_common(s); s.add_argument("uid")
    s.add_argument("--save-dir", default=OUTBOX)
    s.set_defaults(fn=cmd_attachments)

    a = ap.parse_args()
    try:
        a.fn(a)
    except (imaplib.IMAP4.error, smtplib.SMTPException) as e:
        sys.exit("Email server error: %s" % e)

if __name__ == "__main__":
    main()

