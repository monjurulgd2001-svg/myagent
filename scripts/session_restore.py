import glob, json, os, re, sqlite3
home = os.path.expanduser("~/.hermes")
sf = os.path.join(home, "sessions", "sessions.json")
db = os.path.join(home, "state.db")
LIMIT = 45000
def db_tokens(con, sid):
    # exact token counter first, then a chars/4 estimate: some
    # Hermes builds leave token_count empty, which made bloated
    # sessions invisible ("max 0 tokens" while the real session
    # was 200k+ and every API call paid for all of it)
    for q in (
        "SELECT COALESCE(SUM(token_count),0) FROM messages WHERE session_id=?",
        "SELECT COALESCE(SUM(LENGTH(content)),0)/4 FROM messages WHERE session_id=?",
        "SELECT COALESCE(SUM(LENGTH(CAST(data AS TEXT))),0)/4 FROM messages WHERE session_id=?",
    ):
        try:
            n = con.execute(q, (sid,)).fetchone()[0] or 0
            if n:
                return int(n)
        except Exception:
            pass
    return 0
try:
    raw = open(sf).read()
    ids = set(re.findall(r"\d{8}_\d{6}_[0-9a-f]+", raw))
    worst = 0
    if ids and os.path.exists(db):
        con = sqlite3.connect(db)
        for sid in ids:
            worst = max(worst, db_tokens(con, sid))
        con.close()
    if not worst:
        # last resort: biggest session artifact on disk (~4 chars
        # per token) so bloat is never invisible again
        for p in glob.glob(os.path.join(home, "sessions", "**", "*"),
                           recursive=True):
            if os.path.isfile(p):
                worst = max(worst, os.path.getsize(p) // 4)
    if worst > LIMIT:
        os.remove(sf)
        print("session context too big (~%d tokens) - fresh session" % worst)
    else:
        print("keeping sessions (max ~%d tokens)" % worst)
except Exception as e:
    print("session check skipped:", e)
