import asyncio, os, re, signal, subprocess, threading, time, uuid
import requests as rq
from flask import Flask, request, jsonify, Response, send_file
from werkzeug.utils import secure_filename

TOKEN = os.environ.get("PANEL_TOKEN", "hermes99")
GROQ = os.environ.get("GROQ_API_KEY", "").strip()
try:
    import edge_tts
    EDGE = True
except Exception:
    EDGE = False

S_EN = "Hello. This is my voice. I am online and ready."
S_BN = "\u09a8\u09ae\u09b8\u09cd\u0995\u09be\u09b0\u0964 \u098f\u099f\u09be \u0986\u09ae\u09be\u09b0 \u0995\u09a3\u09cd\u09a0\u09b8\u09cd\u09ac\u09b0\u0964 \u0986\u09ae\u09bf \u09aa\u09cd\u09b0\u09b8\u09cd\u09a4\u09c1\u09a4\u0964"
S_HI = "\u0928\u092e\u0938\u094d\u0924\u0947\u0964 \u092f\u0939 \u092e\u0947\u0930\u0940 \u0906\u0935\u093e\u091c\u093c \u0939\u0948\u0964 \u092e\u0948\u0902 \u0924\u0948\u092f\u093e\u0930 \u0939\u0942\u0901\u0964"
G_US = "ENGLISH \u00b7 UNITED STATES"
G_XX = "ENGLISH \u00b7 UK / AU / INDIA"
G_BN = "BANGLA \u00b7 \u09ac\u09be\u0982\u09b2\u09be"
G_HI = "HINDI \u00b7 \u0939\u093f\u0928\u094d\u0926\u0940"
VOICES = [
    {"id": "en-US-GuyNeural", "name": "Guy", "meta": "Male \u00b7 warm narrator", "group": G_US, "sample": S_EN},
    {"id": "en-US-ChristopherNeural", "name": "Christopher", "meta": "Male \u00b7 deep, calm", "group": G_US, "sample": S_EN},
    {"id": "en-US-EricNeural", "name": "Eric", "meta": "Male \u00b7 crisp assistant", "group": G_US, "sample": S_EN},
    {"id": "en-US-AndrewMultilingualNeural", "name": "Andrew", "meta": "Male \u00b7 natural, multilingual", "group": G_US, "sample": S_EN},
    {"id": "en-US-BrianMultilingualNeural", "name": "Brian", "meta": "Male \u00b7 smooth, multilingual", "group": G_US, "sample": S_EN},
    {"id": "en-US-JennyNeural", "name": "Jenny", "meta": "Female \u00b7 friendly assistant", "group": G_US, "sample": S_EN},
    {"id": "en-US-AriaNeural", "name": "Aria", "meta": "Female \u00b7 clear newsreader", "group": G_US, "sample": S_EN},
    {"id": "en-US-AvaMultilingualNeural", "name": "Ava", "meta": "Female \u00b7 expressive, multilingual", "group": G_US, "sample": S_EN},
    {"id": "en-GB-RyanNeural", "name": "Ryan", "meta": "Male \u00b7 British butler vibe", "group": G_XX, "sample": S_EN},
    {"id": "en-GB-ThomasNeural", "name": "Thomas", "meta": "Male \u00b7 refined British", "group": G_XX, "sample": S_EN},
    {"id": "en-GB-SoniaNeural", "name": "Sonia", "meta": "Female \u00b7 British", "group": G_XX, "sample": S_EN},
    {"id": "en-AU-WilliamNeural", "name": "William", "meta": "Male \u00b7 Australian", "group": G_XX, "sample": S_EN},
    {"id": "en-IN-PrabhatNeural", "name": "Prabhat", "meta": "Male \u00b7 Indian English", "group": G_XX, "sample": S_EN},
    {"id": "en-IN-NeerjaNeural", "name": "Neerja", "meta": "Female \u00b7 Indian English", "group": G_XX, "sample": S_EN},
    {"id": "bn-BD-PradeepNeural", "name": "Pradeep", "meta": "Male \u00b7 Bangladesh", "group": G_BN, "sample": S_BN},
    {"id": "bn-BD-NabanitaNeural", "name": "Nabanita", "meta": "Female \u00b7 Bangladesh", "group": G_BN, "sample": S_BN},
    {"id": "bn-IN-BashkarNeural", "name": "Bashkar", "meta": "Male \u00b7 India", "group": G_BN, "sample": S_BN},
    {"id": "bn-IN-TanishaaNeural", "name": "Tanishaa", "meta": "Female \u00b7 India", "group": G_BN, "sample": S_BN},
    {"id": "hi-IN-MadhurNeural", "name": "Madhur", "meta": "Male \u00b7 Hindi", "group": G_HI, "sample": S_HI},
    {"id": "hi-IN-SwaraNeural", "name": "Swara", "meta": "Female \u00b7 Hindi", "group": G_HI, "sample": S_HI},
]
VOICE_IDS = set(v["id"] for v in VOICES)
DEFAULT_VOICES = {"en-US": "en-US-GuyNeural", "bn-BD": "bn-BD-PradeepNeural", "hi-IN": "hi-IN-MadhurNeural"}

# ---- Supertonic 3: free on-device neural TTS (ONNX, CPU). No API, no limits.
# Loads in the background; until ready, /tts transparently uses Edge instead.
SUPER = {"ready": False, "tts": None, "styles": {}, "voices": [], "status": "off", "err": ""}
ST_LOCK = threading.Lock()

def _slog(m):
    try:
        with open("/tmp/supertonic.log", "a") as f:
            f.write("%s %s\n" % (time.strftime("%I:%M:%S %p"), m))
    except Exception:
        pass

def _super_init():
    # Tolerant loader: the SDK surface can differ between versions, so every
    # step tries several shapes and logs what happened to /tmp/supertonic.log.
    try:
        from supertonic import TTS as _ST
    except Exception as e:
        SUPER["status"] = "missing"
        SUPER["err"] = "supertonic package not installed (%s)" % e
        _slog("import failed: %s" % e)
        return
    SUPER["status"] = "loading"
    for attempt in range(3):
        t = None
        for kw in ({"auto_download": True}, {}):
            try:
                t = _ST(**kw)
                _slog("constructed with %s" % (kw or "no args"))
                break
            except Exception as e:
                _slog("ctor %s failed: %s" % (kw, e))
        if t is None:
            time.sleep(10)
            continue
        names = []
        for attr in ("list_voice_styles", "list_voices", "voice_names", "voices", "styles"):
            try:
                v = getattr(t, attr)
                names = [str(x) for x in (v() if callable(v) else v)]
                if names:
                    _slog("voices via %s: %s" % (attr, names[:12]))
                    break
            except Exception:
                pass
        if not names:
            names = ["M1", "M2", "M3", "M4", "F1", "F2", "F3", "F4"]
            _slog("falling back to preset names")
        got = {}
        for n in names[:12]:
            for call in (lambda n=n: t.get_voice_style(voice_name=n),
                         lambda n=n: t.get_voice_style(n)):
                try:
                    got["st:" + n] = call()
                    break
                except Exception as e:
                    last = e
        if not got:
            _slog("no voice styles loaded; retrying")
            time.sleep(10)
            continue
        # prove synthesis actually works before advertising the engine
        probe_key = sorted(got)[0]
        try:
            wav, _d = t.synthesize("Systems online.", voice_style=got[probe_key], lang="en")
            if wav is None:
                raise RuntimeError("empty audio")
        except Exception as e:
            SUPER["err"] = "synthesis test failed: %s" % e
            _slog("probe failed: %s" % e)
            time.sleep(10)
            continue
        SUPER["tts"] = t
        SUPER["styles"] = got
        SUPER["voices"] = []
        for k in sorted(got):
            nm = k[3:]
            sex = "Female" if nm.upper().startswith("F") else "Male"
            SUPER["voices"].append({"id": k, "name": "Supertonic " + nm,
                "meta": sex + " \u00b7 on-device \u00b7 EN/HI",
                "group": "SUPERTONIC 3 \u00b7 ON-DEVICE", "sample": S_EN})
        SUPER["ready"] = True
        SUPER["status"] = "ready"
        SUPER["err"] = ""
        _slog("READY with %d voices" % len(got))
        return
    SUPER["status"] = "error"
    if not SUPER.get("err"):
        SUPER["err"] = "model could not be loaded after 3 attempts"
    _slog("giving up: %s" % SUPER["err"])

def wait_super(seconds):
    # Don't dump the user back to Edge just because the model is still warming
    # up - give it a chance to finish loading first.
    end = time.time() + seconds
    while time.time() < end:
        if SUPER["ready"]:
            return True
        if SUPER["status"] in ("error", "missing", "off"):
            return False
        time.sleep(0.5)
    return SUPER["ready"]

threading.Thread(target=_super_init, daemon=True).start()

def script_lang_srv(t):
    for ch in t:
        if "\u0980" <= ch <= "\u09ff":
            return "bn"
        if "\u0900" <= ch <= "\u097f":
            return "hi"
    return "en"

def _st_split(text, limit=280):
    # Supertonic chokes on long inputs - feed it sentence-sized pieces.
    out, cur = [], ""
    clean = text.replace("\n", " ")
    parts, buf = [], ""
    for ch in clean:
        buf += ch
        if ch in ".!?;" or ch == u"\u0964":
            parts.append(buf.strip()); buf = ""
    if buf.strip():
        parts.append(buf.strip())
    for sent in parts:
        while len(sent) > limit:
            cut = sent.rfind(" ", 40, limit)
            if cut < 40:
                cut = limit
            if cur:
                out.append(cur); cur = ""
            out.append(sent[:cut].strip())
            sent = sent[cut:].strip()
        if not sent:
            continue
        if len(cur) + len(sent) + 1 <= limit:
            cur = (cur + " " + sent).strip()
        else:
            if cur:
                out.append(cur)
            cur = sent
    if cur:
        out.append(cur)
    return out or [text[:limit]]

def supertonic_speak(text, voice, lang):
    import wave, io
    try:
        frames, params = [], None
        for piece in _st_split(text[:1500]):
            with ST_LOCK:
                wav, _dur = SUPER["tts"].synthesize(piece,
                    voice_style=SUPER["styles"][voice], lang=lang)
            p = "/tmp/st_%s.wav" % uuid.uuid4().hex
            SUPER["tts"].save_audio(wav, p)
            wf = wave.open(p, "rb")
            try:
                if params is None:
                    params = wf.getparams()
                frames.append(wf.readframes(wf.getnframes()))
            finally:
                wf.close()
            os.remove(p)
        if not frames or params is None:
            return None
        buf = io.BytesIO()
        ow = wave.open(buf, "wb")
        try:
            ow.setparams(params)
            for fr in frames:
                ow.writeframes(fr)
        finally:
            ow.close()
        return buf.getvalue()
    except Exception as e:
        SUPER["err"] = str(e)[:120]
        return None
UPLOAD_DIR = os.path.expanduser("~/.hermes/work/uploads")
# Anything the agent drops here is delivered straight into the chat.
OUT_DIR = os.path.expanduser("~/.hermes/work/outputs")
FILES = {}          # short id -> absolute path (download registry)
FILE_LOCK = threading.Lock()

IMG_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg")
VID_EXT = (".mp4", ".webm", ".mov", ".mkv", ".avi")
AUD_EXT = (".mp3", ".wav", ".ogg", ".oga", ".m4a", ".opus")
DOC_EXT = (".pdf", ".txt", ".md", ".csv", ".json", ".log", ".html", ".xml",
           ".yml", ".yaml", ".zip", ".tar", ".gz", ".xlsx", ".docx", ".pptx", ".py")
OK_EXT = IMG_EXT + VID_EXT + AUD_EXT + DOC_EXT

# Only files under these roots can ever be served.
SAFE_ROOTS = [os.path.realpath(os.path.expanduser(x)) for x in (
    "~/.hermes/work", "~/Desktop", "~/Pictures", "~/Videos", "~/Downloads",
    "~/screenshots", "/tmp",
)]

MIMES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
         ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
         ".bmp": "image/bmp", ".mp4": "video/mp4", ".webm": "video/webm",
         ".mov": "video/quicktime", ".mp3": "audio/mpeg", ".wav": "audio/wav",
         ".ogg": "audio/ogg", ".oga": "audio/ogg", ".m4a": "audio/mp4",
         ".opus": "audio/ogg", ".pdf": "application/pdf"}


def kind_of(path):
    e = os.path.splitext(path)[1].lower()
    if e in IMG_EXT:
        return "image"
    if e in VID_EXT:
        return "video"
    if e in AUD_EXT:
        return "audio"
    return "file"


def safe_path(path):
    """True only for real files inside SAFE_ROOTS (blocks ../ traversal)."""
    try:
        rp = os.path.realpath(path)
    except Exception:
        return None
    if not os.path.isfile(rp):
        return None
    for root in SAFE_ROOTS:
        if rp == root or rp.startswith(root + os.sep):
            return rp
    return None


def register_file(path):
    """Add a file to the download registry and return its chat descriptor."""
    rp = safe_path(path)
    if not rp:
        return None
    try:
        size = os.path.getsize(rp)
    except Exception:
        return None
    if size <= 0 or size > 200 * 1024 * 1024:
        return None
    fid = uuid.uuid4().hex[:12]
    with FILE_LOCK:
        FILES[fid] = rp
    return {"id": fid, "name": os.path.basename(rp), "size": size,
            "kind": kind_of(rp), "url": "/file?p=" + fid}


# Absolute-ish paths mentioned anywhere in the agent's reply text.
PATH_RE = re.compile(r"(?:(?<=\s)|^|[\"'`(\[])((?:~|/|\./)[^\s\"'`)\]<>,;]+\.[A-Za-z0-9]{1,5})")


def collect_files(reply, since):
    """Find files the agent produced: any it named, plus anything new in OUT_DIR."""
    out, seen = [], set()

    def take(pth):
        rp = safe_path(pth)
        if not rp or rp in seen:
            return
        if os.path.splitext(rp)[1].lower() not in OK_EXT:
            return
        seen.add(rp)
        d = register_file(rp)
        if d:
            out.append(d)

    for m in PATH_RE.findall(reply or ""):
        take(os.path.expanduser(m.rstrip(".,:;")))

    # Sweep the outbox for files created/modified during this job.
    try:
        for root, _dirs, names in os.walk(OUT_DIR):
            for n in names:
                fp = os.path.join(root, n)
                try:
                    if os.path.getmtime(fp) >= since - 2:
                        take(fp)
                except Exception:
                    pass
    except Exception:
        pass
    return out[:12]
# Lives inside ~/.hermes so it is backed up to the private repo and restored
# on the next run - this is what makes the voice choice stick.
PREFS_FILE = os.path.expanduser("~/.hermes/hud_prefs.json")
PREFS_KEYS = ("voice", "lang", "speak", "autoEar",
              "vr_engine", "vr_st_voice", "vr_edge_voice", "vr_bn_voice")

def load_prefs():
    try:
        import json as _j
        with open(PREFS_FILE) as f:
            d = _j.load(f)
        return {k: v for k, v in d.items() if k in PREFS_KEYS}
    except Exception:
        return {}

def save_prefs(new):
    import json as _j
    cur = load_prefs()
    for k in PREFS_KEYS:
        if k in new:
            cur[k] = new[k]
    try:
        os.makedirs(os.path.dirname(PREFS_FILE), exist_ok=True)
        tmp = PREFS_FILE + ".tmp"
        with open(tmp, "w") as f:
            _j.dump(cur, f)
        os.replace(tmp, PREFS_FILE)
    except Exception:
        pass
    return cur
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TG_CHAT = os.environ.get("TELEGRAM_USER_ID", "").strip()
SLACK_TOKEN = os.environ.get("SLACK_BOT_TOKEN", "").strip()
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024   # 200 MB uploads
JOBS = {}
PUSHED = []   # files the agent pushed on its own via /share
PROCS = {}
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
HTML = open("/tmp/jarvis/index.html").read()

def edge_speak(text, voice):
    # Free Microsoft Edge neural TTS - no API key needed.
    if not EDGE:
        return None
    if voice not in VOICE_IDS:
        voice = DEFAULT_VOICES["en-US"]

    async def _gen():
        buf = b""
        com = edge_tts.Communicate(text[:2500], voice)
        async for ch in com.stream():
            if ch["type"] == "audio":
                buf += ch["data"]
        return buf

    for _ in range(2):
        try:
            audio = asyncio.run(_gen())
            if audio:
                return audio
        except Exception:
            time.sleep(0.4)
    return None

def do_stt(blob, mime, lang):
    short = (lang or "").split("-")[0]
    if GROQ:
        try:
            data = {"model": "whisper-large-v3"}
            # Never force English: Whisper auto-detects the spoken language,
            # so Bangla / Hindi are recognized even when the selector says
            # ENGLISH. A non-English selector is passed as an accuracy hint.
            if short and short != "en":
                data["language"] = short
            r = rq.post("https://api.groq.com/openai/v1/audio/transcriptions",
                        headers={"Authorization": "Bearer " + GROQ},
                        files={"file": ("audio.webm", blob, mime)},
                        data=data,
                        timeout=90)
            if r.status_code == 200:
                return (r.json().get("text") or "").strip()
        except Exception:
            pass
    return None

def extract_reply(out):
    # `hermes chat` prints a full CLI dump (banner, "Query:", box art,
    # session stats). Only the text inside the Hermes reply box(es)
    # is the assistant actually speaking - extract just that.
    boxes = []
    cur = None
    for ln in out.split("\n"):
        s = ln.strip()
        if cur is None and s.startswith("\u256d") and "Hermes" in s:
            cur = []
        elif cur is not None and s.startswith("\u2570"):
            boxes.append("\n".join(cur).strip())
            cur = None
        elif cur is not None:
            if s.startswith("\u2502"):
                s = s.strip("\u2502").strip()
            cur.append(s)
    if cur:
        boxes.append("\n".join(cur).strip())
    boxes = [b for b in boxes if b]
    if boxes:
        return "\n\n".join(boxes)
    # Fallback (box style changed): drop known noise lines instead.
    noise = ("Query:", "Initializing", "Resume this session",
             "hermes --resume", "Session:", "Duration:",
             "Messages:", "Tokens:", "Cost:")
    box_chars = set("\u2500\u256d\u256e\u2570\u256f\u2502\u2550 \t")
    keep = []
    for ln in out.split("\n"):
        s = ln.strip()
        if not s or s.startswith(noise) or set(s) <= box_chars:
            continue
        keep.append(s)
    return "\n".join(keep).strip() or out


ROUTER = "http://localhost:4000/v1/chat/completions"
FAST_SYS = ("You are Hermes, an AI agent speaking to the user through a "
            "voice HUD. You also have a separate FULL AGENT mode with tools (terminal, "
            "web browsing, web search, files, code execution) that is powerful but slow. "
            "Decide how to handle the user's message: "
            "(a) If it is small talk, a greeting, a quick factual or opinion question you "
            "can answer from knowledge, or a short writing/translation request - answer "
            "it DIRECTLY yourself. Be concise and speech-friendly (1-4 short sentences) "
            "and plain — no persona, no honorifics like Boss or Sir. Reply in the user's language. "
            "(b) If it genuinely needs tools, live/current information, browsing, scraping, "
            "files, running code, or long multi-step work - reply with EXACTLY this token "
            "and nothing else: [[AGENT]]")

def fast_answer(text, hist):
    # One quick call to the local pool router. Returns a direct reply,
    # or None when the message should go to the full agent.
    msgs = [{"role": "system", "content": FAST_SYS}]
    for m in hist[-6:]:
        if (isinstance(m, dict) and m.get("role") in ("user", "assistant")
                and isinstance(m.get("content"), str)):
            msgs.append({"role": m["role"], "content": m["content"][:1200]})
    msgs.append({"role": "user", "content": text[:4000]})
    try:
        r = rq.post(ROUTER,
                    headers={"Authorization": "Bearer sk-local",
                             "Content-Type": "application/json"},
                    json={"model": "pool-auto", "messages": msgs,
                          "max_tokens": 500, "temperature": 0.6},
                    timeout=15)
        if r.status_code == 200:
            out = (r.json()["choices"][0]["message"]["content"] or "").strip()
            if out and "[[AGENT]]" not in out:
                return out
    except Exception:
        pass
    return None

def run_dispatch(jid, text, hist, deep):
    # Try the fast lane first (unless files are attached / forced deep);
    # fall back to the full agent when the router says [[AGENT]].
    if not deep:
        fast = fast_answer(text, hist)
        if JOBS.get(jid, {}).get("done"):
            return  # interrupted while the fast lane was running
        if fast is not None:
            JOBS[jid] = {"done": True, "reply": fast[-6000:]}
            return
    run_job(jid, text)

def run_job(jid, text):
    started = time.time()
    try:
        os.makedirs(OUT_DIR, exist_ok=True)
    except Exception:
        pass
    env = dict(os.environ, NO_COLOR="1", TERM="dumb", DISPLAY=":99",
               HERMES_OUTPUT_DIR=OUT_DIR)
    try:
        p = subprocess.Popen(
            ["hermes", "chat", "-q", text, "--source", "tool"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True, env=env)
        PROCS[jid] = p
        # Stream output as it happens (instead of communicate()) so /poll can
        # show the panel WHAT the agent is doing while a long task runs.
        buf, ebuf = [], []

        def _reader(pipe, into, live):
            try:
                for line in iter(pipe.readline, ""):
                    into.append(line)
                    if live:
                        ln = ANSI.sub("", line).strip()
                        ln = ln.strip("\u2502\u256d\u2570\u251c\u2500 ").strip()
                        if len(ln) >= 4 and not ln.startswith(("Query:", "Session", "Hermes")):
                            j = JOBS.get(jid)
                            if j is not None and not j.get("done"):
                                j["live"] = ln[:120]
            except Exception:
                pass

        tr1 = threading.Thread(target=_reader, args=(p.stdout, buf, True), daemon=True)
        tr2 = threading.Thread(target=_reader, args=(p.stderr, ebuf, False), daemon=True)
        tr1.start(); tr2.start()
        deadline = time.time() + 1800
        while p.poll() is None and time.time() < deadline:
            time.sleep(0.5)
        if p.poll() is None:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception:
                p.kill()
            JOBS[jid] = {"done": True, "reply": "Task timed out after 30 minutes."}
            return
        tr1.join(timeout=5)
        tr2.join(timeout=5)
        out = "".join(buf)
        err = "".join(ebuf)
        if JOBS.get(jid, {}).get("done"):
            return  # already marked interrupted via /stop
        outc = ANSI.sub("", (out or "")).strip()
        if not outc:
            outc = ANSI.sub("", (err or "")).strip() or "(no output)"
        rep = extract_reply(outc)[-6000:]
        JOBS[jid] = {"done": True, "reply": rep,
                     "files": collect_files(rep, started)}
    except Exception as e:
        JOBS[jid] = {"done": True, "reply": "Error: %s" % e}
    finally:
        PROCS.pop(jid, None)

@app.route("/")
def home():
    return Response(HTML, mimetype="text/html")

@app.route("/config")
def config():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    return jsonify(tts=EDGE, stt=bool(GROQ),
                   voices=VOICES + SUPER["voices"], defaults=DEFAULT_VOICES,
                   st=SUPER["status"], sterr=SUPER.get("err", ""),
                   prefs=load_prefs())

@app.route("/prefs", methods=["POST"])
def prefs_route():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    return jsonify(ok=True, prefs=save_prefs(request.get_json(silent=True) or {}))

@app.route("/tts", methods=["POST"])
def tts_route():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify(error="empty"), 400
    voice = (data.get("voice") or "").strip()
    why = ""
    if voice.startswith("st:"):
        sl = script_lang_srv(text)
        if sl == "bn":
            why = "Supertonic 3 has no Bangla voice - using your Edge Bangla voice"
        else:
            if not SUPER["ready"]:
                wait_super(25)          # warm-up, not a real failure
            if SUPER["ready"] and voice in SUPER["styles"]:
                audio = supertonic_speak(text, voice, sl)
                if audio:
                    r = Response(audio, mimetype="audio/wav")
                    r.headers["X-TTS-Engine"] = "supertonic"
                    return r
                why = "Supertonic failed (%s) - used Edge for this line" % (SUPER.get("err") or "synthesis error")
            elif SUPER["status"] == "loading":
                why = "Supertonic is still loading - using Edge for now"
            else:
                why = "Supertonic unavailable (%s) - using Edge" % (SUPER.get("err") or SUPER["status"])
        voice = (DEFAULT_VOICES["bn-BD"] if sl == "bn"
                 else DEFAULT_VOICES["hi-IN"] if sl == "hi"
                 else DEFAULT_VOICES["en-US"])
    audio = edge_speak(text, voice)
    if audio:
        r = Response(audio, mimetype="audio/mpeg")
        r.headers["X-TTS-Engine"] = "edge"
        if why:
            r.headers["X-TTS-Note"] = why
        return r
    return jsonify(error="tts unavailable"), 503

def synth_best(text):
    """Speaks with the user's chosen voice (/edge vocal, /supersonic vocal).
    Bangla ALWAYS uses the Edge Bangla voice (Supertonic has no Bangla);
    everything else uses the local Supertonic model unless the user
    switched the engine to Edge. Returns (audio, extension, engine)."""
    sl = script_lang_srv(text)
    pf = _vr_prefs()
    if sl != "bn" and pf["engine"] == "supertonic":
        if not SUPER["ready"]:
            wait_super(8)       # short wait only - Edge covers the gap
            pf = _vr_prefs()    # styles may have just become available
        if SUPER["ready"] and pf["st"]:
            a = supertonic_speak(text, pf["st"], sl)
            if a:
                return a, "wav", "supertonic"
    v = (pf["bn"] if sl == "bn"
         else DEFAULT_VOICES["hi-IN"] if sl == "hi"
         else pf["en"])
    a = edge_speak(text, v)
    if a:
        return a, "mp3", "edge"
    return None, None, None

# ---- voice-model picker: "/edge vocal" & "/supersonic vocal" ----
def _vr_prefs():
    p = load_prefs()
    st = p.get("vr_st_voice") or ""
    if st not in SUPER["styles"]:
        st = next((k for k in sorted(SUPER["styles"])), "")
    return {"engine": (p.get("vr_engine") or "supertonic"),
            "st": st,
            "en": p.get("vr_edge_voice") or DEFAULT_VOICES["en-US"],
            "bn": p.get("vr_bn_voice") or DEFAULT_VOICES["bn-BD"]}

def _engine_voices(engine):
    return list(SUPER["voices"]) if engine == "supertonic" else list(VOICES)

def _norm_engine(e):
    e = (e or "").strip().lower()
    if e in ("supertonic", "supersonic", "st", "local"):
        return "supertonic"
    return "edge"

def _tg_text(chat, text):
    if not (TG_TOKEN and chat):
        return
    try:
        rq.post("https://api.telegram.org/bot" + TG_TOKEN + "/sendMessage",
                data={"chat_id": chat, "text": text[:4000]}, timeout=30)
    except Exception:
        pass

def _tg_audio(chat, audio, ext, title, caption):
    if not (TG_TOKEN and chat):
        return
    try:
        rq.post("https://api.telegram.org/bot" + TG_TOKEN + "/sendAudio",
                data={"chat_id": chat, "title": title,
                      "caption": caption[:900], "performer": "voice sample"},
                files={"audio": (title.replace(" ", "_") + "." + ext, audio)},
                timeout=60)
    except Exception:
        pass

def _sample_audio(v):
    if v["id"].startswith("st:"):
        if SUPER["ready"]:
            return supertonic_speak(v.get("sample") or S_EN, v["id"], "en"), "wav"
        return None, "wav"
    return edge_speak(v.get("sample") or S_EN, v["id"]), "mp3"

def _demo_worker(engine, chat):
    # Sends a numbered list + one PLAYABLE audio sample per voice, so
    # the user can listen inside Telegram and reply with their pick.
    if engine == "supertonic" and not SUPER["ready"]:
        _tg_text(chat, "Supertonic model is still loading - samples coming shortly...")
        wait_super(120)
    vs = _engine_voices(engine)
    if not vs:
        _tg_text(chat, "No %s voices available right now (%s)"
                 % (engine, SUPER.get("err") or SUPER["status"]))
        return
    pf = _vr_prefs()
    cur = pf["st"] if engine == "supertonic" else pf["en"]
    lines = ["VOICE MODEL: %s - listen to the samples below, then reply with a number or name to select." % engine.upper()]
    for i, v in enumerate(vs, 1):
        mark = " (current)" if v["id"] in (cur, pf["bn"]) else ""
        lines.append("%d. %s - %s%s" % (i, v["name"], v.get("meta", ""), mark))
    _tg_text(chat, "\n".join(lines))
    for i, v in enumerate(vs, 1):
        audio, ext = _sample_audio(v)
        if audio:
            _tg_audio(chat, audio, ext, "%d. %s" % (i, v["name"]), v.get("meta", ""))
        time.sleep(0.4)
    _tg_text(chat, "Reply with the number or name you like (example: 3 or Nabanita) and I will set it.")

@app.route("/voices")
def voices_route():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    if request.args.get("engine"):
        vs = _engine_voices(_norm_engine(request.args.get("engine")))
    else:
        vs = VOICES + SUPER["voices"]
    return jsonify(voices=[{"n": i, "id": v["id"], "name": v["name"],
                            "meta": v.get("meta", ""), "group": v.get("group", "")}
                           for i, v in enumerate(vs, 1)],
                   current=_vr_prefs(), st=SUPER["status"])

@app.route("/voicedemo", methods=["POST"])
def voicedemo():
    """"/edge vocal" & "/supersonic vocal": switches the reply engine and
    drops a numbered, playable sample of every voice into the chat."""
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    d = request.get_json(silent=True) or {}
    engine = _norm_engine(d.get("engine"))
    save_prefs({"vr_engine": engine})
    chat = (d.get("chat_id") or TG_CHAT).strip()
    if not (TG_TOKEN and chat):
        return jsonify(error="no telegram chat to send samples to"), 400
    threading.Thread(target=_demo_worker, args=(engine, chat), daemon=True).start()
    return jsonify(ok=True, engine=engine,
                   note="engine switched; the sample list is being sent to the chat")

@app.route("/setvoice", methods=["POST"])
def setvoice():
    """Body: {"voice": "<number | name | id>", "engine"?, "chat_id"?}.
    Persists the pick in ~/.hermes (survives runs via the data repo)."""
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    d = request.get_json(silent=True) or {}
    want = str(d.get("voice") or "").strip()
    if not want:
        return jsonify(error="empty voice"), 400
    engine = _norm_engine(d.get("engine") or load_prefs().get("vr_engine") or "supertonic")
    vs = _engine_voices(engine)
    pick = None
    if want.isdigit() and 1 <= int(want) <= len(vs):
        pick = vs[int(want) - 1]
    if pick is None:
        for v in VOICES + SUPER["voices"]:
            if want.lower() in (v["id"].lower(), v["name"].lower(),
                                v["name"].split()[-1].lower()):
                pick = v
                break
    if pick is None:
        return jsonify(error="unknown voice: %s (send a number from the list or a name)" % want), 404
    if pick["id"].startswith("st:"):
        upd = {"vr_engine": "supertonic", "vr_st_voice": pick["id"]}
    elif pick["id"].startswith("bn-"):
        upd = {"vr_bn_voice": pick["id"]}
    else:
        upd = {"vr_engine": "edge", "vr_edge_voice": pick["id"]}
    save_prefs(upd)
    chat = (d.get("chat_id") or "").strip()
    if TG_TOKEN and chat:
        audio, ext = _sample_audio(pick)
        if audio:
            _tg_audio(chat, audio, ext, pick["name"], "This is your new voice.")
    return jsonify(ok=True, set=upd, voice=pick["name"], prefs=_vr_prefs())

@app.route("/voicereply", methods=["POST"])
def voicereply():
    """Speak a reply back into Telegram or Slack.
    The agent calls this after answering a VOICE message.
    Body: {"text": "...", "chat_id": "optional", "channel": "optional"}"""
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    d = request.get_json(silent=True) or {}
    text = (d.get("text") or "").strip()
    if not text:
        return jsonify(error="empty"), 400
    chat0 = (d.get("chat_id") or TG_CHAT).strip()
    ch0 = (d.get("channel") or "").strip()
    if not ((TG_TOKEN and chat0) or (SLACK_TOKEN and ch0)):
        return jsonify(error="no destination: pass chat_id or channel"), 400
    # Respond IMMEDIATELY - synthesis + upload happen in the background
    # so the agent's curl never blocks the reply loop.
    threading.Thread(target=_vr_deliver, args=(text, chat0, ch0),
                     daemon=True).start()
    return jsonify(ok=True, queued=True,
                   note="voice is being synthesized and sent in the background")

def _vr_deliver(text, chat, ch):
    # Heavy lifting off the request thread (TTS + ffmpeg + upload).
    audio, ext, engine = synth_best(text[:1500])
    if not audio:
        return
    path = "/tmp/vr_%s.%s" % (uuid.uuid4().hex, ext)
    with open(path, "wb") as f:
        f.write(audio)
    sent = []
    if TG_TOKEN and chat:
        try:
            # Telegram voice notes want OGG/Opus; convert when ffmpeg exists,
            # otherwise fall back to sendAudio which accepts mp3/wav.
            ogg = path.rsplit(".", 1)[0] + ".ogg"
            conv = subprocess.run(["ffmpeg", "-y", "-i", path, "-c:a", "libopus",
                                   "-b:a", "32k", ogg],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            api = "https://api.telegram.org/bot" + TG_TOKEN
            if conv.returncode == 0 and os.path.exists(ogg):
                with open(ogg, "rb") as f:
                    r = rq.post(api + "/sendVoice", data={"chat_id": chat},
                                files={"voice": ("reply.ogg", f, "audio/ogg")}, timeout=60)
                os.remove(ogg)
            else:
                with open(path, "rb") as f:
                    r = rq.post(api + "/sendAudio", data={"chat_id": chat},
                                files={"audio": ("reply." + ext, f)}, timeout=60)
            sent.append("telegram" if r.status_code == 200 else "telegram_failed")
        except Exception as e:
            sent.append("telegram_error:%s" % e)
    if SLACK_TOKEN and ch:
        try:
            with open(path, "rb") as f:
                r = rq.post("https://slack.com/api/files.upload",
                            headers={"Authorization": "Bearer " + SLACK_TOKEN},
                            data={"channels": ch, "filename": "reply." + ext,
                                  "title": "Voice reply"},
                            files={"file": ("reply." + ext, f)}, timeout=60)
            ok = r.status_code == 200 and (r.json() or {}).get("ok")
            sent.append("slack" if ok else "slack_failed")
        except Exception as e:
            sent.append("slack_error:%s" % e)
    try:
        os.remove(path)
    except Exception:
        pass
    try:
        print("voicereply: engine=%s sent=%s" % (engine, ",".join(sent) or "none"),
              flush=True)
    except Exception:
        pass

@app.route("/file")
def file_route():
    # <img>/<video> tags cannot send headers, so a query token is allowed here.
    t = request.headers.get("X-Token", "") or request.args.get("t", "")
    if t != TOKEN:
        return jsonify(error="bad token"), 401
    fid = request.args.get("p", "")
    with FILE_LOCK:
        path = FILES.get(fid)
    if not path or not safe_path(path):
        return jsonify(error="unknown or expired file"), 404
    ext = os.path.splitext(path)[1].lower()
    dl = request.args.get("dl") == "1"
    try:
        return send_file(path, mimetype=MIMES.get(ext),
                         as_attachment=dl,
                         download_name=os.path.basename(path),
                         conditional=True)
    except TypeError:
        # older Flask: attachment_filename instead of download_name
        return send_file(path, mimetype=MIMES.get(ext), as_attachment=dl,
                         attachment_filename=os.path.basename(path))
    except Exception as e:
        return jsonify(error=str(e)), 500


@app.route("/share", methods=["POST"])
def share_route():
    """Agent-facing: push a file straight into the chat, no waiting for a reply."""
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    data = request.get_json(silent=True) or {}
    paths = data.get("paths") or ([data.get("path")] if data.get("path") else [])
    got = []
    for pth in paths:
        if isinstance(pth, str):
            d = register_file(os.path.expanduser(pth.strip()))
            if d:
                got.append(d)
    if not got:
        return jsonify(error="no readable file at that path"), 400
    PUSHED.append({"text": (data.get("text") or "").strip(), "files": got,
                   "ts": time.time()})
    del PUSHED[:-20]
    return jsonify(ok=True, files=got)


@app.route("/stt", methods=["POST"])
def stt_route():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    blob = request.get_data()
    if not blob or len(blob) < 1000:
        return jsonify(error="no audio received"), 400
    text = do_stt(blob, request.headers.get("Content-Type", "audio/webm"),
                  request.args.get("lang", "en-US"))
    if text is None:
        return jsonify(error="transcription unavailable (add the GROQ_API_KEY secret)"), 503
    return jsonify(text=text)

@app.route("/upload", methods=["POST"])
def upload():
    # Files land in ~/.hermes/work/uploads/ - inside the persisted+backed-up
    # ~/.hermes tree, so uploads survive the run and the agent can read them.
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify(error="no file received"), 400
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    name = secure_filename(f.filename) or ("file_%d" % int(time.time()))
    path = os.path.join(UPLOAD_DIR, time.strftime("%Y%m%d_%H%M%S_") + name)
    f.save(path)
    return jsonify(path=path, name=name, size=os.path.getsize(path))

@app.route("/ask", methods=["POST"])
def ask():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    fpaths = data.get("files") or []
    safe = []
    root = os.path.realpath(UPLOAD_DIR)
    for pth in fpaths:
        if isinstance(pth, str):
            rp = os.path.realpath(pth)
            if rp.startswith(root + os.sep) and os.path.isfile(rp):
                safe.append(rp)
    if not text and not safe:
        return jsonify(error="empty command"), 400
    if safe:
        text = ("The user uploaded file(s) for you, already saved on this machine at: "
                + ", ".join(safe)
                + " - use your terminal/files tools to read them. "
                + (text or "Inspect the file(s) and report what they contain."))
    hist = data.get("history") or []
    if not isinstance(hist, list):
        hist = []
    jid = uuid.uuid4().hex
    JOBS[jid] = {"done": False}
    threading.Thread(target=run_dispatch, args=(jid, text, hist[-8:], bool(safe)),
                     daemon=True).start()
    return jsonify(job=jid)

@app.route("/stop", methods=["POST"])
def stop_route():
    # Interrupt a running task: kill the hermes chat process group.
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    jid = request.args.get("id", "")
    if jid not in JOBS:
        return jsonify(ok=False, error="unknown job")
    JOBS[jid] = {"done": True, "reply": "Task interrupted by you. Standing by."}
    p = PROCS.get(jid)
    if not p:
        return jsonify(ok=True)
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        try:
            p.terminate()
        except Exception:
            pass
    return jsonify(ok=True)

@app.route("/poll")
def poll():
    if request.headers.get("X-Token", "") != TOKEN:
        return jsonify(error="bad token"), 401
    j = JOBS.get(request.args.get("id", ""))
    if not j:
        return jsonify(error="unknown job"), 404
    out = dict(j)
    try:
        since = float(request.args.get("since", "0") or 0)
    except Exception:
        since = 0
    out["pushed"] = [x for x in PUSHED if x["ts"] > since]
    out["now"] = time.time()
    return jsonify(**out)

app.run(host="127.0.0.1", port=7777, threaded=True)
