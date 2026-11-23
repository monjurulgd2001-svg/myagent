/// v86 — Charging Animation engine: drives the user's own signed-in
/// Gemini session in the app's Gecko browser to make videos, and
/// keeps the finished MP4s on the device.
///
/// v87 adds per-video AI metadata + panel upload (the same listing
/// metadata and R2 + Firebase queue the image sets use), through
/// injected StudioEngine functions so this engine stays testable
/// without a Gemini session or network.
///
/// Flow (the same session the image pipeline uses — no API key, no
/// per-clip cost; his Google AI plan's daily video limit applies):
///  1. [start] opens gemini.google.com in the in-app browser and
///     hands the prompt + model to the in-page video driver (the
///     extension's content script, see
///     android/app/src/main/assets/ais_cookies/content.js).
///  2. The driver picks the model (Neon default), opens the web
///     chat's "Create video" tool, sends the prompt, waits for the
///     finished video, and reports back over the `browserRequest`
///     channel as `video_progress` / `video_ready` / `video_error`.
///  3. [handleRequest] downloads the MP4 (plain https URL, or the
///     in-page data-URL fallback for blob-only videos), saves it
///     under the app documents `animations/` folder, and prepends
///     it to [videos]. Task mode (on by default) holds the
///     foreground keep-alive while waiting and fires the completion
///     notification, so he can leave the app and come back to a
///     finished animation.
///
/// The driver automation is text-based and blind from here (the
/// Gemini web UI cannot be inspected without his login): every
/// failure reports the exact step plus the buttons the page actually
/// shows, so one live-test report is enough to fix the selectors.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'animation_models.dart';
import 'foreground_keep_alive.dart';
import 'mp4_info.dart';
import 'gecko_browser.dart';
import 'gecko_signin.dart';
import 'session_store.dart';
import 'models.dart';
import 'task_backend.dart';
import 'video_cover.dart';

/// Where the finished videos live on the device, and where the
/// video list + Task-mode choice are persisted.
const String kAnimationVideosKey = 'animationVideosJson';
const String kAnimationTaskModeKey = 'animTaskMode';
const String kAnimationErrorLogKey = 'animErrorLog';
const String kGeminiChatUrl = 'https://gemini.google.com/app';

/// Status lines shown under the Generate button (Banglish, like the
/// rest of the app).
String animationPhaseText(AnimationPhase phase, [String detail = '']) {
  switch (phase) {
    case AnimationPhase.idle:
      return '';
    case AnimationPhase.opening:
      return 'Gemini khulche…';
    case AnimationPhase.selectingModel:
      return 'Neon select korche…';
    case AnimationPhase.openingTool:
      return 'Create video khulche…';
    case AnimationPhase.creating:
      return 'Video banacche… (1–2 min lagte pare)';
    case AnimationPhase.downloading:
      return 'MP4 download hocche…';
    case AnimationPhase.ready:
      return 'Animation ready ✓';
    case AnimationPhase.error:
      return detail.isEmpty ? 'Animation hoyni.' : 'Animation hoyni: $detail';
  }
}

/// v87 — injected by the app: AI metadata for one video (the
/// StudioEngine's Gemini session) and the panel upload (R2 +
/// Firebase queue). Null in tests that do not provide them.
typedef VideoMetadataGenerator = Future<SetMetadata> Function(
    AnimationVideo video);
typedef VideoPanelUploader = Future<
    ({
      String accountName,
      String firebaseKey,
      SetMetadata? metadata,
      // v158 — the cover URL when a cover was captured + uploaded
      // (null when the video goes without one).
      String? thumbUrl,
      // v159 — the failed cover step (capture vs R2 upload) when
      // the video went without a cover, so the failure lands in
      // the persisted error log instead of being swallowed;
      // null when a cover was uploaded (or a cached one reused).
      // v159 SECOND PASS — the hard guarantee: a total cover
      // failure now THROWS in the uploader before the Firebase
      // record is pushed, so it never reaches this return; the
      // field is kept for API compatibility and for the
      // defensive log branch in AnimationEngine.uploadVideoToPanel.
      String? coverError,
    })> Function(AnimationVideo video, {String targetAccount});

/// v166 — the manual cover picker: fetches the candidate cover
/// frames for one video (panel percentage points of its
/// duration), plus a per-path diagnostic. Injected so the screen
/// stays testable without a real video file; the app wires the
/// StudioEngine path.
typedef CoverCandidatesFetcher = Future<CoverCandidatesResult> Function(
    AnimationVideo video);

/// v88 — injected by the app: polishes a rough animation idea
/// into a production-ready video prompt (the StudioEngine's
/// Gemini session). Null in tests that do not provide it.
typedef VideoPromptPolisher = Future<String> Function(String prompt);

/// v92 — injected by the app: the Task-mode video BACKEND (no
/// browser). Returns the finished MP4 bytes, or throws
/// [TaskBackendException] naming the failed step. v106 — the backend
/// was the ONLY path (user order 2026-11-20: "Backend a jeno sob
/// hoy browser jeno open na hoy"): a null runner refused the job,
/// it never fell back to the browser.
/// v145 — the backend NEVER succeeded live (channel khule, kintu
/// Gemini kono task thread banayni — 2026-11-21 22:50 live test),
/// so a backend failure now falls back to the browser driver
/// instead of ending the job (v146: headless driver — browser
/// show na kore, backend-e chole).
typedef TaskBackendRunner = Future<Uint8List> Function(
  String taskText, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
});

/// v164 — injected by the app: opens ONE shared backend session
/// for a whole bulk run (StudioEngine.openTaskVideoSession). The
/// bulk opens it once and runs every line's Task inside it, so
/// Gemini sees one continuous bulk job instead of a fresh channel
/// per line (user order 2026-11-22: "jate o doshta na mone kore").
/// Null in tests that do not provide it — the bulk then falls back
/// to the per-line runner, exactly like v163.
typedef TaskBackendSessionOpener = Future<SharedBackendSession>
    Function({required DateTime deadline});

/// v145 — injected by the app: the in-page Gemini video driver.
/// v146 — HEADLESS (user order: browser show na kore, backend-e
/// chole): no browser window ever opens — the job runs inside the
/// invisible headless GeckoSession (GeckoBridge.browserVideoHeadless,
/// v136), where the driver types the Task prompt in Task mode
/// itself. Hands [prompt] + [modelId] + [jobId] over and returns
/// once the job was handed over. The finished video / error comes
/// back through [AnimationEngine.handleRequest] as `video_ready` /
/// `video_error`, never through this call. The app wires it to
/// `GeckoBrowser.instance.startVideoHeadless(...)`.
/// v150 — returns true when Kotlin posted the job to the extension
/// port at once, false when it was queued (port not connected yet)
/// or the call failed. The engine logs the queued case so the next
/// report shows which side of the bridge the job is stuck on.
typedef VideoDriverRunner = Future<bool> Function({
  required String prompt,
  required String modelId,
  required String jobId,
});

/// v151 — injected by the app: tells the in-page driver (and the
/// Kotlin / background.js queues in front of it) to drop a job. Called
/// when Dart gives up on a job or the user cancels it, so a job the
/// page never reported on cannot start later on its own (late-start
/// = silent quota use + stale events) and the driver's `running`
/// flag is freed for the next job.
typedef VideoCancelRunner = Future<void> Function(String jobId);

/// v154 — injected by the app: the signed-in session's Cookie header
/// for the video download (the driver URL branch). The download link
/// is auth-gated: without cookies Gemini answers HTTP 200 with an
/// HTML sign-in page, which used to be saved as `.mp4` and marked
/// "Animation ready ✓" — then the player failed with ExoPlayer
/// "Source error" (live 2026-11-22). The app wires it to
/// `GeminiApi().getSession()`; null in tests (plain GET, as before).
/// A provider failure is swallowed — the download still tries
/// without cookies rather than failing on a session hiccup.
typedef VideoCookieHeaderProvider = Future<String> Function();

class AnimationEngine {
  AnimationEngine({
    http.Client? httpClient,
    // v129 — null = unlimited timeout (user request: video generation
    // can take anywhere from a few seconds to a long time). Tests can
    // still pass an explicit Duration.
    Duration? jobTimeout,
    // v140 — progress watchdog: how long the job may go with NO phase
    // progress before it fails with the last step named. This is NOT
    // a job timeout (v129's unlimited job stands — a slow generation
    // that keeps reporting progress is never cut off); it only fires
    // when the backend goes quiet, e.g. stuck on 'Task thread toiri
    // hocche…' with no conversation id (live 2026-11-21, 1 hour+).
    // The download phase is exempt — an MP4 download on his slow
    // network is legitimately quiet for a long time. Tests pass a
    // short value.
    this.watchdogQuiet = const Duration(minutes: 10),
    // v150 — driver handover deadline: how long the driver may go
    // after taking over WITHOUT reporting any phase at all before
    // the job fails with step `driver_handover`. The headless job
    // can sit stuck in Kotlin waitingForPort / background.js
    // pendingVideo — neither has a timeout of its own — so without
    // this the job sits silent for hours (live 2026-11-22
    // 01:48→07:39: 21080s of silence). 3 min is generous for a slow
    // page load; a driver that reports progress is exempt (the
    // 10-min quiet check is its backstop). Tests pass a short value.
    this.driverHandoverDeadline = const Duration(minutes: 3),
    VideoMetadataGenerator? metadataGenerator,
    VideoPanelUploader? panelUploader,
    VideoPromptPolisher? promptPolisher,
    CoverCandidatesFetcher? coverCandidatesFetcher,
    TaskBackendRunner? taskBackendRunner,
    TaskBackendSessionOpener? taskBackendSessionOpener,
    VideoDriverRunner? videoDriverRunner,
    VideoCancelRunner? videoCancelRunner,
    VideoCookieHeaderProvider? cookieHeaderProvider,
    // v151 — false = driver FIRST: the Task backend never succeeded
    // live (no f4/f5 token), so waiting for it (up to the 10-min quiet
    // window) before the driver only delays the job — and a backend
    // that already created a Task thread would make the fallback
    // generate twice. The backend stays available (tests, future).
    this.backendFirst = true,
    this.onChanged,
  })  : _httpClient = httpClient,
        _jobTimeout = jobTimeout,
        _metadataGenerator = metadataGenerator,
        _panelUploader = panelUploader,
        _coverCandidatesFetcher = coverCandidatesFetcher,
        _promptPolisher = promptPolisher,
        _taskBackendRunner = taskBackendRunner,
        _taskBackendSessionOpener = taskBackendSessionOpener,
        _videoDriverRunner = videoDriverRunner,
        _videoCancelRunner = videoCancelRunner,
        _cookieHeaderProvider = cookieHeaderProvider;

  final bool backendFirst;
  final VideoCancelRunner? _videoCancelRunner;
  final VideoCookieHeaderProvider? _cookieHeaderProvider;
  // v151 — jobs the user cancelled: late events for them are ignored.
  final Set<String> _cancelledJobIds = {};
  final http.Client? _httpClient;
  final Duration? _jobTimeout;
  final Duration watchdogQuiet;
  final Duration driverHandoverDeadline;
  Timer? _watchdogTimer;
  DateTime? _jobStartedAt;
  // v150 — when the driver took over this job (null = the driver
  // never owned it). The handover deadline is measured from here.
  DateTime? _driverHandoverAt;
  // v89: last driver phase + when it last reported, so a timeout
  // can say WHERE the job died instead of a blind "time out".
  // (v88: the user got only the blind message after 6 min — the
  // job had never even reached the driver.)
  String _lastDriverPhase = '';
  DateTime? _lastProgressAt;
  // v100 — the backend's failure line, kept so a later driver
  // failure reports BOTH causes: live 2026-11-20 the driver error
  // overwrote the backend step, so nobody could tell whether the
  // page transport had failed at 'transport' or at a real step.
  String _backendFailure = '';
  // v140 — error log: every backend job failure is kept here
  // (time + step + detail) so the Animation screen can show WHAT
  // failed, not just that it failed. Persisted — it survives an
  // app restart, so he can read the last error and report it.
  List<String> errorLog = [];
  final VideoMetadataGenerator? _metadataGenerator;
  final VideoPanelUploader? _panelUploader;
  // v166 — the manual cover picker's candidate fetcher (the app
  // wires the StudioEngine path; null = no candidates, e.g.
  // tests that do not provide it).
  final CoverCandidatesFetcher? _coverCandidatesFetcher;
  final VideoPromptPolisher? _promptPolisher;
  final TaskBackendRunner? _taskBackendRunner;
  final TaskBackendSessionOpener? _taskBackendSessionOpener;
  // v164 — the bulk run's shared backend session (null outside a
  // bulk run, or when the session could not be opened).
  SharedBackendSession? _bulkBackendSession;
  final VideoDriverRunner? _videoDriverRunner;
  // v145 — driver fallback state, per job: the full Task prompt
  // the driver must send (same text the backend tried), whether
  // the driver already owns this job, and whether it was tried.
  // Once the driver owns the job the backend's late failure /
  // success must not end it or finish it twice.
  String _currentTaskPrompt = '';
  bool _driverTried = false;
  bool _driverActive = false;
  // v163 — one completer per launched job, completed when the job
  // TRULY ends (ready incl. the auto-metadata await, or any
  // error/idle). The bulk runner awaits it so the next line only
  // starts after the previous video is fully finished — one video
  // at a time, exactly like tapping Generate by hand.
  Completer<void>? _jobDoneCompleter;

  // v163 — bulk queue (in-memory; the bulk box text is the source
  // of truth the user can re-run from, so a restart loses the
  // queue but never the prompts). Per-line status is shown live
  // in the bulk card; a failed line never stops the rest.
  List<BulkAnimationItem> bulkItems = [];
  bool _bulkRunning = false;
  bool get bulkRunning => _bulkRunning;
  bool _bulkCancelled = false;

  List<AnimationVideo> videos = [];
  AnimationPhase phase = AnimationPhase.idle;
  String status = '';
  String currentJobId = '';
  String currentPrompt = '';
  String currentModelId = kDefaultAnimationModel;

  /// v87 — which video a metadata / panel action is running on
  /// right now ('metadata' or 'upload'), so the card can disable
  /// its buttons while the action runs.
  String? busyVideoId;
  String busyAction = '';

  /// The model the picker shows (persisted; Neon default). The job
  /// copies it into [currentModelId] when it starts.
  String selectedModelId = kDefaultAnimationModel;
  bool taskMode = true;

  /// v88 — the style/mood, clip length and seamless-loop choices
  /// (persisted; Cinematic / 10s / loop on by default).
  String selectedStyleId = kDefaultAnimationMoodId;
  int selectedDurationSec = kDefaultAnimationDurationSec;
  bool seamlessMode = kDefaultAnimationSeamless;

  /// Called after every state change so the screen can setState.
  void Function()? onChanged;

  Timer? _jobTimer;
  bool _loaded = false;

  void _emit() => onChanged?.call();

  void _setPhase(AnimationPhase p, [String detail = '']) {
    phase = p;
    status = animationPhaseText(p, detail);
    // v163 — a job that ends in error/idle is DONE for the bulk
    // runner (ready is different: _finishBytes completes the job
    // only AFTER the auto-metadata await, so the next line never
    // starts while the previous video's metadata is still
    // fetching — a metadata completion would otherwise clobber
    // the new job's status line mid-generation).
    if (p == AnimationPhase.error || p == AnimationPhase.idle) {
      _markJobDone();
    }
    _emit();
  }

  /// v163 — completes the current job's done-signal, once. No-op
  /// when no job is in flight (guard failures call _setPhase
  /// before any job starts, and _finishBytes ends with this too).
  void _markJobDone() {
    final c = _jobDoneCompleter;
    _jobDoneCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<Directory> videosDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/animations');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    taskMode = prefs.getBool(kAnimationTaskModeKey) ?? true;
    selectedModelId =
        prefs.getString('animModelId') ?? kDefaultAnimationModel;
    if (animationModelById(selectedModelId).locked) {
      selectedModelId = kDefaultAnimationModel;
    }
    selectedStyleId =
        prefs.getString('animStyleId') ?? kDefaultAnimationMoodId;
    selectedDurationSec =
        prefs.getInt('animDurationSec') ?? kDefaultAnimationDurationSec;
    if (!kAnimationDurations.contains(selectedDurationSec)) {
      selectedDurationSec = kDefaultAnimationDurationSec;
    }
    seamlessMode = prefs.getBool('animSeamless') ?? kDefaultAnimationSeamless;
    final raw = prefs.getString(kAnimationVideosKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        videos = list
            .whereType<Map>()
            .map((e) => AnimationVideo.fromJson(
                Map<String, dynamic>.from(e)))
            .whereType<AnimationVideo>()
            .toList();
      } catch (_) {
        videos = [];
      }
    }
    // v154 — videos saved by v153 or earlier carry the ASSUMED
    // 60fps (the field defaulted to 60 and nothing ever measured
    // it): re-probe the real file once and fix fps / duration, so
    // the old card stops claiming 60fps it never had — no
    // regeneration needed, the file itself is the truth. Files are
    // capped at 25 MB by the driver, so a bounded read is cheap;
    // a missing or unreadable file keeps its stored values.
    var fixed = false;
    for (var i = 0; i < videos.length; i++) {
      final v = videos[i];
      try {
        if (v.localPath.isEmpty) continue;
        final f = File(v.localPath);
        if (!await f.exists()) continue;
        final len = await f.length();
        if (len <= 0) continue;
        var next = v;
        // v159 second pass — the real file length is the truth
        // for the card's size too (old records were saved with
        // sizeBytes 0). The live 36 MB file is above the 32 MB
        // probe cap below, so the size fix must NOT ride on the
        // probe — it is fixed from the length alone.
        if (len != v.sizeBytes) {
          next = next.copyWith(sizeBytes: len);
          fixed = true;
        }
        if (len <= 32 * 1024 * 1024) {
          final info = readMp4Info(await f.readAsBytes());
          if (info != null) {
            final fps = info.fps > 0 ? info.fps : next.fps;
            final dur = info.durationSec > 0
                ? info.durationSec
                : next.durationSec;
            if (fps != next.fps || dur != next.durationSec) {
              next = next.copyWith(fps: fps, durationSec: dur);
              fixed = true;
            }
          }
        }
        videos[i] = next;
      } catch (_) {}
    }
    if (fixed) await _save();
    errorLog = prefs.getStringList(kAnimationErrorLogKey) ?? [];
    _emit();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kAnimationVideosKey,
        jsonEncode([for (final v in videos) v.toJson()]));
  }

  Future<void> setTaskMode(bool value) async {
    taskMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAnimationTaskModeKey, value);
    _emit();
  }

  Future<void> setModelId(String id) async {
    final model = animationModelById(id);
    selectedModelId = model.locked ? kDefaultAnimationModel : model.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('animModelId', selectedModelId);
    _emit();
  }

  /// v88 — style / duration / seamless choices (persisted).
  Future<void> setStyleId(String id) async {
    selectedStyleId = animationMoodById(id).id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('animStyleId', selectedStyleId);
    _emit();
  }

  Future<void> setDurationSec(int seconds) async {
    selectedDurationSec = kAnimationDurations.contains(seconds)
        ? seconds
        : kDefaultAnimationDurationSec;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('animDurationSec', selectedDurationSec);
    _emit();
  }

  Future<void> setSeamless(bool value) async {
    seamlessMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('animSeamless', value);
    _emit();
  }

  /// v140 — appends one line to the error log (newest last, max
  /// 20 kept) and persists it. Called on every job failure so the
  /// step + detail stay visible in the Animation section.
  Future<void> _logError(String text) async {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    errorLog = [...errorLog, '$hh:$mm — $text'];
    if (errorLog.length > 20) {
      errorLog = errorLog.sublist(errorLog.length - 20);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(kAnimationErrorLogKey, errorLog);
    _emit();
  }

  /// v140 — clears the error log (the Clear button in the log card).
  Future<void> clearErrorLog() async {
    errorLog = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(kAnimationErrorLogKey, errorLog);
    _emit();
  }

  /// v88 — polishes a rough animation idea into a production-ready
  /// video prompt. Returns null when no polisher is wired or the
  /// polish fails (status says why); the user's prompt is kept.
  /// v145 — wand repeat fix: Gemini often hands the input back
  /// unchanged (same subject, same wording — the instruction
  /// never asked for a fresh version, and a second tap polishes
  /// the already-polished text). When the first answer IS the
  /// input, ask once more with an explicit "completely different
  /// version" ask; only then accept what came back.
  static bool _samePromptText(String a, String b) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final na = norm(a);
    return na.isNotEmpty && na == norm(b);
  }

  Future<String?> polishPrompt(String raw) async {
    final polisher = _promptPolisher;
    if (polisher == null) {
      status = 'Prompt polish ei build-e nei.';
      _emit();
      return null;
    }
    final text = raw.trim();
    if (text.isEmpty) return null;
    status = 'Prompt polish hocche…';
    _emit();
    try {
      var polished = (await polisher(text)).trim();
      if (_samePromptText(polished, text)) {
        try {
          polished = (await polisher(
            '$text\n\n[Write a completely different version of this idea — '
            'different wording, different composition, different '
            'viewpoint and details. Never return the same text again.]',
          ))
              .trim();
        } catch (_) {
          // Retry failed — keep the first answer, don't fail polish.
        }
      }
      status = 'Prompt polished ✓';
      _emit();
      return polished;
    } catch (e) {
      status = 'Polish hoyni: $e';
      _emit();
      return null;
    }
  }

  bool get busy =>
      phase != AnimationPhase.idle &&
      phase != AnimationPhase.ready &&
      phase != AnimationPhase.error;

  /// Starts one animation. Returns false when it cannot start
  /// (blank prompt, already busy, not signed in, copyright-risk
  /// prompt) — [status] says why.
  /// v154 — [fpsRetry] is the manual "60fps-e abar banaw" retry: the
  /// previous clip came back under 60fps, so the prompt asks for
  /// 60fps emphatically (see buildAnimationPrompt). Always the
  /// user's tap, never automatic — a regeneration spends quota.
  Future<bool> start({
    required String rawPrompt,
    required String modelId,
    required bool signedIn,
    bool fpsRetry = false,
  }) async {
    // v88 — copyright guard FIRST: a prompt naming a brand,
    // character or celebrity can get his Zedge account struck,
    // so it never reaches Gemini.
    final flags = checkAnimationPromptSafety(rawPrompt);
    if (flags.isNotEmpty) {
      _setPhase(AnimationPhase.error,
          'Copyright risk: "${flags.join(', ')}" — eta brand/character '
          'thakle Zedge account-e strike khete pare. Onno word diye lekho.');
      return false;
    }
    final prompt = buildAnimationPrompt(
      rawPrompt,
      styleId: selectedStyleId,
      durationSec: selectedDurationSec,
      seamless: seamlessMode,
      fpsRetry: fpsRetry,
    );
    // v101 — the Task agent must hear "video" FIRST and
    // unambiguously: live 2026-11-20 it answered a video request
    // with a still keyframe image instead ("I can adjust the
    // keyframe's framing…"). The lead sits on the ONE text both the
    // backend and the driver send, so they can never disagree (the
    // driver's own v91 prepend is gone — see content.js).
    final taskPrompt = taskMode
        ? 'Create a video now — an animation video, an animated MP4 '
            'file, not an image and not a keyframe. Video size '
            '1620x2880, 9:16 vertical, 60 frames per second. '
            // v154 — "60 frames per second" spelled out in the lead
            // (the spec suffix already said "60fps" once, buried at
            // the end): live 2026-11-22 the file came back 30fps.
            // Gemini's encoder decides the output — the prompt is
            // the only lever, so ask in both places and measure the
            // file honestly (see _finishBytes) instead of assuming.
            'Make it original and unique — not a copy of any existing '
            'video, artwork, character or brand, no copyrighted '
            'element, and avoid common generic scenes. $prompt'
        : prompt;
    if (prompt.isEmpty) {
      _setPhase(AnimationPhase.error, 'Age ekta prompt likho.');
      return false;
    }
    if (busy) {
      _setPhase(AnimationPhase.error, 'Ekta animation cholche — sesh hok.');
      return false;
    }
    if (!signedIn) {
      _setPhase(AnimationPhase.error,
          'Age Gemini-te sign in koro (Login tab).');
      return false;
    }
    final model = animationModelById(modelId);
    if (model.locked) {
      _setPhase(AnimationPhase.error,
          '${model.label} ekhono lock kora — Neon diye banaw.');
      return false;
    }
    // v106 — backend-only (user order 2026-11-20: "Backend a jeno
    // sob hoy browser jeno open na hoy"): Task mode OFF means there
    // is no backend path, so the job refuses instead of opening the
    // browser. The driver needs Task mode too (content.js: Task
    // mandatory, v103), so this guard stays.
    // v145 — a null backend runner no longer refuses when the
    // driver exists: the job goes straight to the driver.
    if (!taskMode) {
      _setPhase(AnimationPhase.error,
          'Task mode ON koro — animation ekhon sudhu backend-e hoy, '
          'browser khulbe na.');
      return false;
    }
    if (_taskBackendRunner == null && _videoDriverRunner == null) {
      _setPhase(AnimationPhase.error,
          'Backend ready na — browser khulbe na, tai video hobe na.');
      return false;
    }
    // v163 — the job is really starting now: arm its done-signal
    // BEFORE any phase change, so a job can never be busy with no
    // completer for the bulk runner to wait on.
    _jobDoneCompleter = Completer<void>();
    currentPrompt = rawPrompt.trim();
    currentModelId = model.id;
    currentJobId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentTaskPrompt = taskPrompt;
    _driverTried = false;
    _driverActive = false;
    _driverHandoverAt = null;
    _lastDriverPhase = '';
    _lastProgressAt = null;
    _jobStartedAt = DateTime.now();
    _backendFailure = '';
    _setPhase(AnimationPhase.opening);
    _jobTimer?.cancel();
    if (_jobTimeout != null) {
      _jobTimer = Timer(_jobTimeout, () {
        if (busy && currentJobId.isNotEmpty) {
          _setPhase(AnimationPhase.error, _timeoutMessage());
          currentJobId = '';
        }
      });
    }
    // v140 — progress watchdog: a quiet job fails instead of
    // spinning forever (see _checkWatchdog). The check runs every
    // 60s in production; a short watchdogQuiet (tests) checks at
    // the same cadence so the failure lands promptly.
    _armWatchdog();
    try {
      await ForegroundKeepAlive.acquire(
          'Making animation in the background — safe to switch apps');
    } catch (e) {
      _jobTimer?.cancel();
      _watchdogTimer?.cancel();
      ForegroundKeepAlive.release();
      _setPhase(AnimationPhase.error, 'Background service chalu hoyni: $e');
      currentJobId = '';
      return false;
    }
    // v145 — backend FIRST, driver on failure (see _runBackend):
    // the backend never succeeded live, so a backend failure
    // hands the SAME task prompt to the headless driver instead
    // of ending the job. No backend at all? Straight to the driver.
    if (_taskBackendRunner == null ||
        (!backendFirst && _videoDriverRunner != null)) {
      unawaited(_startDriver());
      return true;
    }
    unawaited(_runBackend(taskPrompt));
    return true;
  }

  /// v140 — (re)arms the quiet-job watchdog. A driver fallback
  /// re-arms it too, so the driver gets its own fresh quiet
  /// window instead of inheriting the backend's. The tick cadence
  /// is the shortest deadline the watchdog enforces (v150): the
  /// handover deadline is 3 min in production, so the 60s tick is
  /// the binding one there; tests pass a short deadline and get a
  /// matching cadence instead of waiting out the quiet window.
  void _armWatchdog() {
    _watchdogTimer?.cancel();
    var checkEvery = watchdogQuiet < const Duration(seconds: 60)
        ? watchdogQuiet
        : const Duration(seconds: 60);
    if (driverHandoverDeadline < checkEvery) {
      checkEvery = driverHandoverDeadline;
    }
    _watchdogTimer =
        Timer.periodic(checkEvery, (_) => _checkWatchdog());
  }

  /// v145 — hands the job to the browser driver: the in-page
  /// driver types the Task prompt itself. The driver answers through
  /// [handleRequest] (`video_progress` / `video_ready` /
  /// `video_error`); this call only hands the job over. A handover
  /// failure ends the job — there is nothing left to try.
  /// v146 — HEADLESS: no window opens at all (user order: browser
  /// show na kore, backend-e chole) — the same handover, inside
  /// the invisible headless GeckoSession.
  /// v150 — the handover is logged (time + jobId) and the stale
  /// backend phase is reset; if the driver never reports a phase
  /// within [driverHandoverDeadline], the watchdog fails the job
  /// with step `driver_handover` instead of sitting silent.
  Future<void> _startDriver() async {
    final jobId = currentJobId;
    if (jobId.isEmpty || _videoDriverRunner == null) return;
    _driverTried = true;
    _driverActive = true;
    // v150 — reset the backend's stale phase: a timeout must never
    // again quote 'creating' ("video banacche") for a job the driver
    // never touched (live 2026-11-22 01:48→07:39 the driver reported
    // nothing for 21080s, yet the timeout named the backend's old
    // step). The handover deadline is measured from here.
    _lastDriverPhase = '';
    _driverHandoverAt = DateTime.now();
    _lastProgressAt = DateTime.now();
    _armWatchdog();
    _setPhase(AnimationPhase.opening);
    status = 'Driver-e video banacche… (browser khulbe na, backend-e cholche)';
    _emit();
    // v150 — persistent handover line (time + jobId in the error
    // log), so the next report proves the handover ran even if the
    // driver then stays silent.
    unawaited(_logError(
        'Driver-e job dilam (job $jobId) — page theke khobor-er opekkha…'));
    try {
      final posted = await _videoDriverRunner(
        prompt: _currentTaskPrompt,
        modelId: currentModelId,
        jobId: jobId,
      );
      // v150 — Kotlin queued the job instead of posting it: the
      // headless extension port was not connected yet. The handover
      // deadline below fails the job if the port never connects;
      // this line says which side of the bridge it is stuck on.
      if (!posted) {
        unawaited(_logError('Driver job queued — headless port connect '
            'hoyni ekhono, waiting for port…'));
      }
    } catch (e) {
      if (currentJobId != jobId || jobId.isEmpty) return;
      _driverActive = false;
      final detail = 'Driver-eo hoyni: $e'
          '${_backendFailure.isNotEmpty ? ' — $_backendFailure' : ''}';
      unawaited(_logError(detail));
      _jobTimer?.cancel();
      _watchdogTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      _setPhase(AnimationPhase.error, detail);
      currentJobId = '';
    }
  }

  /// v164 — one backend call, on the bulk's shared session when one
  /// is open, else on the per-line runner. A session-dead failure
  /// re-opens the session ONCE and retries this line on the fresh
  /// one; any other failure (or a second session death) propagates
  /// to [_runBackend]'s driver fallback, exactly like before.
  Future<Uint8List> _callBackend(String prompt,
      {required DateTime deadline}) async {
    final session = _bulkBackendSession;
    if (session == null) {
      return _taskBackendRunner!(
        prompt,
        onPhase: _applyBackendPhase,
        deadline: deadline,
      );
    }
    try {
      return await session.runTask(
        prompt,
        onPhase: _applyBackendPhase,
        deadline: deadline,
      );
    } on TaskBackendException catch (e) {
      if (!e.sessionDead) rethrow;
      unawaited(_logError('Shared backend session more geche '
          '(${e.step}) — notun session khulchi, line-ta abar try korchi.'));
      try {
        await session.close();
      } catch (_) {}
      _bulkBackendSession = null;
      final reopened =
          await _taskBackendSessionOpener?.call(deadline: deadline);
      if (reopened == null) rethrow;
      _bulkBackendSession = reopened;
      return reopened.runTask(
        prompt,
        onPhase: _applyBackendPhase,
        deadline: deadline,
      );
    }
  }

  /// v92 — runs the Task backend and finishes with its MP4 bytes.
  /// v145 — a backend failure NO LONGER ends the job when the
  /// driver exists: it hands the same prompt to the headless
  /// browser driver (user order: browser show na kore, backend-e
  /// chole). Only when there is no driver — or the driver already
  /// owns the job — does the failure end it.
  Future<void> _runBackend(String prompt) async {
    final jobId = currentJobId;
    final deadline = DateTime.now().add(_jobTimeout ?? const Duration(days: 365));
    try {
      final bytes = await _callBackend(prompt, deadline: deadline);
      if (currentJobId != jobId || jobId.isEmpty) return;
      // The watchdog already handed this job to the driver while
      // the backend was quiet — the driver owns it now.
      if (_driverActive) return;
      await _finishBytes(bytes,
          durationSec: selectedDurationSec.toDouble());
    } catch (e) {
      if (currentJobId != jobId || jobId.isEmpty) return;
      // The driver already owns this job (watchdog fallback) —
      // the backend's late failure must not kill it.
      if (_driverActive) return;
      final step = e is TaskBackendException ? e.step : 'backend';
      // v94 — the failure detail (e.g. the HTTP status) rides along
      // so the next report names the cause, not just the step.
      // v145 — the old 80-char cut hid the v142 stream diagnostics
      // ("stream: N poll, sesh HTTP S, B byte") that say whether
      // Gemini ignored the task or the stream itself was blocked
      // (live 2026-11-21 22:50: the log ended in "…." with no
      // diagnostics). Keep 400 chars so the full diagnosis survives.
      final detail = e is TaskBackendException ? e.message : '$e';
      final short = detail.length > 400
          ? '${detail.substring(0, 400)}…'
          : detail;
      _backendFailure = 'Backend hoyni ($step — $short)';
      // v140 — the failure goes into the error log too, so the
      // step + detail stay visible in the Animation section.
      unawaited(_logError(_backendFailure));
      if (_videoDriverRunner != null && !_driverTried) {
        status = '$_backendFailure — browser driver diye try korchi…';
        _emit();
        unawaited(_startDriver());
        return;
      }
      _jobTimer?.cancel();
      _watchdogTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      _setPhase(AnimationPhase.error,
          '$_backendFailure — driver-eo try kora hoise, tai video hoyni. '
          'Abar try koro.');
      currentJobId = '';
    }
  }

  /// v140 — progress watchdog (checked every 60s while a job runs):
  /// when the backend goes quiet for [watchdogQuiet] with no phase
  /// progress, the job fails with the last step named instead of
  /// spinning forever. A healthy job keeps reporting progress (the
  /// poll calls onPhase every pollInterval), so it is never cut off
  /// — this is a quiet-detector, not a job timeout (v129 stands).
  /// The download phase is exempt: an MP4 download on a slow
  /// network is legitimately quiet for a long time. The timer stops
  /// itself once the job ends (busy goes false).
  void _checkWatchdog() {
    if (currentJobId.isEmpty || !busy) {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      return;
    }
    // v150 — handover deadline: the driver owns the job but the
    // page never reported back — not even 'opening'. The headless
    // job may be stuck in Kotlin waitingForPort / background.js
    // pendingVideo, neither of which has a timeout of its own, so
    // fail loudly here with the step named instead of sitting
    // silent for hours (live 2026-11-22 01:48→07:39: 21080s of
    // silence). A driver that reports any phase is exempt — the
    // 10-min quiet check below is its backstop. Note: no Dart-side
    // timer can fire while the OS freezes the app (Doze/HiOS), so
    // after a freeze this still only lands on the first tick after
    // thaw — but now it lands with the true cause named.
    if (_driverActive &&
        _driverHandoverAt != null &&
        _lastDriverPhase.isEmpty &&
        DateTime.now().difference(_driverHandoverAt!) >
            driverHandoverDeadline) {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _jobTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      _cancelDriverJob(currentJobId);
      const message = 'Driver-e job dilam kintu page theke kono khobor '
          'asheni (driver_handover) — headless tab/port connect hoyni. '
          'Abar try koro.';
      unawaited(_logError(message));
      _setPhase(AnimationPhase.error, message);
      currentJobId = '';
      return;
    }
    if (_lastDriverPhase == 'downloading') return;
    final ref = _lastProgressAt ?? _jobStartedAt;
    if (ref == null) return;
    if (DateTime.now().difference(ref) > watchdogQuiet) {
      // v145 — a quiet BACKEND is not a dead job anymore: hand it
      // to the driver instead of failing (the backend went quiet
      // for 10 min on 'Task thread toiri hocche…' live 2026-11-21).
      // Only when the driver already owns the job — and went quiet
      // itself — does the watchdog fail it.
      if (_videoDriverRunner != null && !_driverTried) {
        final message = _timeoutMessage();
        unawaited(_logError('$message — browser driver diye try korchi.'));
        status = 'Backend chup kore ache — browser driver diye try korchi…';
        _emit();
        unawaited(_startDriver());
        return;
      }
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _jobTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      _cancelDriverJob(currentJobId);
      // v140 — the stuck step goes into the error log, so the
      // quiet failure is visible in the Animation section too.
      final message = _timeoutMessage();
      unawaited(_logError(message));
      _setPhase(AnimationPhase.error, message);
      currentJobId = '';
    }
  }

  /// v92 — backend progress lines reuse the driver phases (the
  /// status text carries the live detail).
  void _applyBackendPhase(String phase, String message) {
    _lastDriverPhase =
        phase == 'downloading' ? 'downloading' : phase;
    _lastProgressAt = DateTime.now();
    switch (phase) {
      case 'opening':
        _setPhase(AnimationPhase.opening);
        break;
      case 'downloading':
        _setPhase(AnimationPhase.downloading);
        break;
      default:
        _setPhase(AnimationPhase.creating);
    }
    if (message.isNotEmpty) {
      status = message;
      _emit();
    }
  }

  /// v151 — tells the driver side to drop [jobId] (fire-and-forget;
  /// no-op without a cancel runner or when the driver never owned it).
  void _cancelDriverJob(String jobId) {
    final runner = _videoCancelRunner;
    if (runner == null || jobId.isEmpty || !_driverTried) return;
    unawaited(() async {
      try {
        await runner(jobId);
      } catch (_) {}
    }());
  }

  /// v151 — the user stops the running animation (Cancel button).
  /// Frees the foreground service, drops the job from the driver /
  /// Kotlin / background.js queues and returns to idle, so Generate
  /// works again at once. Late events for this job are ignored.
  Future<void> cancelJob() async {
    final jobId = currentJobId;
    if (jobId.isEmpty || !busy) return;
    // v163 — a Cancel mid-bulk stops the whole queue, not just
    // this line: the runner would otherwise start the next line
    // at once and the tap would look like it did nothing.
    _bulkCancelled = true;
    _cancelledJobIds.add(jobId);
    _jobTimer?.cancel();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    if (taskMode) ForegroundKeepAlive.release();
    _cancelDriverJob(jobId);
    unawaited(_logError('Job cancel kora holo (job $jobId).'));
    currentJobId = '';
    _driverActive = false;
    _setPhase(AnimationPhase.idle);
    status = 'Cancel kora hoyeche.';
    _emit();
  }

  /// v163 — bulk animation (user order 2026-11-22: "line by line
  /// prompt dilam"): [prompts] is the parsed bulk box (one prompt
  /// per line, already trimmed + deduped by
  /// [parseBulkAnimationPrompts]). Every line runs through the
  /// SAME [start] as a hand-tapped Generate — same master prompt,
  /// same backend-then-driver route, same Task mode, same Neon
  /// default, same per-video card + auto-metadata + cover — one
  /// line at a time, in order. Each line is its OWN separate
  /// request to Gemini (its own Task prompt / generation job) —
  /// the lines are NEVER combined into one prompt or one request
  /// (user clarification 2026-11-22: "Gemini-teo jeno oivabe
  /// requests jay"). A failed line is logged (v140 log)
  /// and the queue CONTINUES with the next line; a copyright-risk
  /// line is skipped up front with its reason and never reaches
  /// Gemini. Returns when the whole queue is done (or stopped);
  /// the caller does not await it. The bulk box text is NOT
  /// cleared here — the screen keeps it until the user taps Clear,
  /// so a failed line can be re-run by generating again.
  Future<void> startBulk({
    required List<String> prompts,
    required String modelId,
    required bool signedIn,
  }) async {
    if (_bulkRunning) {
      status = 'Bulk cholche — sesh hok, tarpor abar dao.';
      _emit();
      return;
    }
    if (busy) {
      status = 'Ekta animation cholche — sesh hok, tarpor bulk dao.';
      _emit();
      return;
    }
    if (!signedIn) {
      _setPhase(AnimationPhase.error,
          'Age Gemini-te sign in koro (Login tab).');
      return;
    }
    final model = animationModelById(modelId);
    if (model.locked) {
      _setPhase(AnimationPhase.error,
          '${model.label} ekhono lock kora — Neon diye banaw.');
      return;
    }
    bulkItems = [
      for (var i = 0; i < prompts.length; i++)
        BulkAnimationItem(id: 'bulk_$i', prompt: prompts[i]),
    ];
    // Guard pre-check per line: a risky line is skipped here with
    // its reason — it never reaches Gemini, and the rest still run.
    for (final item in bulkItems) {
      final flags = checkAnimationPromptSafety(item.prompt);
      if (flags.isNotEmpty) {
        item.status = BulkAnimationStatus.skipped;
        item.note = 'Copyright risk: "${flags.join(', ')}" — eta '
            'brand/character thakle Zedge account-e strike khete pare. '
            'Onno word diye lekho.';
      }
    }
    final runnable = bulkItems
        .where((i) => i.status == BulkAnimationStatus.queued)
        .length;
    if (runnable == 0) {
      status = 'Bulk-e kono chalano-joggo line nai — shob skip hoyeche.';
      _emit();
      return;
    }
    _bulkRunning = true;
    _bulkCancelled = false;
    _emit();
    try {
      // v164 — one shared backend session for the whole bulk: the
      // channel opens ONCE here and every line runs its Task
      // inside it, instead of a fresh channel per line. Only when
      // the backend is the path in use (backendFirst): with the
      // driver first the backend is never called, so an opened
      // session would only idle-poll the stream on his slow
      // network. An open failure is NOT fatal — the lines fall
      // back to the per-line runner (v163 behaviour) and the run
      // continues.
      final bulkDeadline =
          DateTime.now().add(_jobTimeout ?? const Duration(days: 365));
      if (backendFirst && _taskBackendSessionOpener != null) {
        status = 'Bulk session khulche — ek session-e sob line cholbe…';
        _emit();
        try {
          _bulkBackendSession =
              await _taskBackendSessionOpener(deadline: bulkDeadline);
        } catch (e) {
          _bulkBackendSession = null;
          unawaited(_logError('Bulk backend session kholeni ($e) — '
              'prottek line alada session-e cholbe.'));
        }
      }
      var done = 0;
      var failed = 0;
      final skipped = bulkItems
          .where((i) => i.status == BulkAnimationStatus.skipped)
          .length;
      for (final item in bulkItems) {
        if (_bulkCancelled) break;
        if (item.status != BulkAnimationStatus.queued) continue;
        // A single job the user started by hand mid-bulk (the
        // Generate button is live between lines): wait for it to
        // finish instead of failing this line on the busy guard.
        while (busy) {
          final doneFuture = _jobDoneCompleter?.future;
          if (doneFuture == null) break;
          await doneFuture;
          if (_bulkCancelled) break;
        }
        if (_bulkCancelled) break;
        item.status = BulkAnimationStatus.running;
        _emit();
        final ok = await start(
            rawPrompt: item.prompt, modelId: modelId, signedIn: signedIn);
        if (!ok) {
          // A global blocker (signed out / Task mode off / locked
          // model / no backend) would fail EVERY remaining line
          // the same way — stop the run and say why instead of
          // failing the whole queue one line at a time. A real
          // per-line failure (backend/driver error) never stops
          // the rest — it is marked failed below, after the wait.
          if (_isBulkStoppingReason(status)) {
            item.status = BulkAnimationStatus.failed;
            item.note = status;
            failed++;
            unawaited(_logError('Bulk "${item.prompt}" — $status'));
            status = 'Bulk thamlo: $status';
            _emit();
            break;
          }
          item.status = BulkAnimationStatus.failed;
          item.note = status;
          failed++;
          unawaited(_logError('Bulk "${item.prompt}" — $status'));
          _emit();
          continue;
        }
        // The job runs in the background (backend → driver): wait
        // for its true end (ready incl. auto-metadata, or any
        // error/idle) before the next line.
        await _jobDoneCompleter?.future;
        if (_bulkCancelled) {
          // Stopped mid-line: the video either landed just before
          // the cancel (done) or never did (failed, with the
          // cancel note) — never leave the line stuck on running.
          if (phase == AnimationPhase.ready) {
            item.status = BulkAnimationStatus.done;
            done++;
          } else {
            item.status = BulkAnimationStatus.failed;
            item.note = status;
            failed++;
          }
          _emit();
          break;
        }
        if (phase == AnimationPhase.ready) {
          item.status = BulkAnimationStatus.done;
          done++;
        } else {
          item.status = BulkAnimationStatus.failed;
          item.note = status;
          failed++;
          unawaited(_logError('Bulk "${item.prompt}" — $status'));
        }
        _emit();
      }
      final total = bulkItems.length;
      status = _bulkCancelled
          ? 'Bulk thamano hoyeche — $done/$total hoyeche.'
          : 'Bulk sesh ✓ — $done done, $failed failed, $skipped '
              'skipped (mot $total).';
      _emit();
    } finally {
      final bulkSession = _bulkBackendSession;
      _bulkBackendSession = null;
      if (bulkSession != null) {
        try {
          await bulkSession.close();
        } catch (_) {}
      }
      _bulkRunning = false;
      _emit();
    }
  }

  /// v163 — the [start] guard messages that mean the WHOLE bulk
  /// run cannot proceed (not a per-line failure): signed out,
  /// Task mode off, locked model, or no backend/driver at all.
  /// Matched on the guard's own status text, in one place.
  bool _isBulkStoppingReason(String s) =>
      s.contains('sign in') ||
      s.contains('Task mode ON koro') ||
      s.contains('lock kora') ||
      s.contains('Backend ready na');

  /// v163 — stops a running bulk queue: the current job is
  /// cancelled (same as the Cancel button) and the remaining
  /// lines never start. Lines still queued stay queued, so the
  /// user can see what never ran.
  Future<void> cancelBulk() async {
    _bulkCancelled = true;
    if (busy) await cancelJob();
    _emit();
  }

  /// v163 — clears the bulk run's per-line list (the Clear button
  /// in the bulk card). Only when no bulk run is active — clearing
  /// mid-run would hide the running line's status.
  void clearBulkItems() {
    if (_bulkRunning) return;
    bulkItems = [];
    _emit();
  }

  /// Routes one `browserRequest` from the in-page driver. Returns
  /// true when the request was a video event for the current job.
  Future<bool> handleRequest(GeckoBrowserRequest req) async {
    final ev = AnimationVideoEvent.fromData(req.action, req.data);
    if (ev == null || !ev.isVideo) {
      return false;
    }
    if (ev.jobId.isNotEmpty &&
        currentJobId.isNotEmpty &&
        ev.jobId != currentJobId) {
      return false;
    }
    // v151 — a job the user cancelled never comes back to life.
    if (ev.jobId.isNotEmpty && _cancelledJobIds.contains(ev.jobId)) {
      return false;
    }
    switch (ev.action) {
      case 'video_progress':
        // v151 — a late progress event after the job ended (3-min
        // handover deadline, watchdog, cancel) used to flip the phase
        // back to opening/creating with no job id and no watchdog:
        // `busy` stayed true forever and Generate refused every new
        // job. Progress only counts while a job is current.
        if (currentJobId.isEmpty) return false;
        _applyDriverPhase(ev.phase, ev.message);
        return true;
      case 'video_ready':
        await _finishReady(ev);
        return true;
      case 'video_error':
        _jobTimer?.cancel();
        if (taskMode) ForegroundKeepAlive.release();
        final detail = [
          // v100 — the backend already failed once on this job; name
          // its step too, or the next report is blind again.
          if (_backendFailure.isNotEmpty) '$_backendFailure — driver-eo hoyni:',
          if (ev.step.isNotEmpty) '(${ev.step})',
          ev.message,
          if (ev.buttons.isNotEmpty) 'Page-e ja chilo: ${ev.buttons}',
        ].join(' ').trim();
        // v140 — the driver failure goes into the error log too.
        unawaited(_logError(detail));
        _setPhase(AnimationPhase.error, detail);
        currentJobId = '';
        return true;
    }
    return false;
  }

  /// v89: what the timeout reports — the last driver step and how
  /// long it has been quiet, so one live-test report names the
  /// exact stuck step instead of a blind "time out".
  String _timeoutMessage() {
    const labels = {
      'opening': 'Gemini khulche',
      'task_mode': 'Task mode-e cholche',
      'selecting_model': 'model select hocche',
      'opening_tool': 'video tool khulche',
      'typing': 'prompt likhche',
      'creating': 'video banacche',
      'downloading': 'MP4 download hocche',
    };
    if (_lastDriverPhase.isEmpty) {
      // v150 — the driver owns the job but never reported a phase:
      // say so, instead of the backend's stale label or the generic
      // backend line (live 2026-11-22: the timeout said "video
      // banacche" for a job the driver never touched).
      if (_driverActive) {
        return 'time out — driver-e job dilam kintu page theke kono '
            'khobor asheni. Abar try koro.';
      }
      return 'time out — backend-er sathe kono jogajog hoyni. '
          'Abar try koro.';
    }
    final label = labels[_lastDriverPhase] ?? _lastDriverPhase;
    final quiet = _lastProgressAt == null
        ? ''
        : ' (${DateTime.now().difference(_lastProgressAt!).inSeconds}s dhore kono khobor nai)';
    return 'time out — sesh step: $label$quiet. '
        'Gemini theke kono video asheni, abar try koro.';
  }

  void _applyDriverPhase(String driverPhase, String message) {
    _lastDriverPhase = driverPhase;
    _lastProgressAt = DateTime.now();
    switch (driverPhase) {
      case 'opening':
        _setPhase(AnimationPhase.opening);
        break;
      case 'selecting_model':
        _setPhase(AnimationPhase.selectingModel);
        break;
      case 'opening_tool':
        _setPhase(AnimationPhase.openingTool);
        break;
      case 'creating':
        _setPhase(AnimationPhase.creating);
        break;
      default:
        if (message.isNotEmpty) {
          status = message;
          _emit();
        }
    }
  }

  Future<void> _finishReady(AnimationVideoEvent ev) async {
    _setPhase(AnimationPhase.downloading);
    try {
      final Uint8List bytes;
      if (ev.dataUrl.isNotEmpty) {
        final comma = ev.dataUrl.indexOf(',');
        final b64 = comma >= 0 ? ev.dataUrl.substring(comma + 1) : ev.dataUrl;
        bytes = base64Decode(b64);
      } else if (ev.url.isNotEmpty) {
        final client = _httpClient ?? http.Client();
        try {
          // v154 — send the session cookies: an auth-gated Gemini
          // download link answers HTTP 200 with an HTML sign-in
          // page when no cookies ride along, and that HTML used to
          // be saved as `.mp4` (see _finishBytes).
          String cookie = '';
          try {
            cookie = await _cookieHeaderProvider?.call() ?? '';
          } catch (_) {}
          final res = await client.get(
            Uri.parse(ev.url),
            headers: cookie.isEmpty ? null : {'Cookie': cookie},
          );
          if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
            throw 'Download failed: HTTP ${res.statusCode}';
          }
          bytes = res.bodyBytes;
        } finally {
          if (_httpClient == null) {
            client.close();
          }
        }
      } else {
        throw 'Gemini video-r URL deyni.';
      }
      await _finishBytes(bytes,
          width: ev.width, height: ev.height, durationSec: ev.durationSec);
    } catch (e) {
      _jobTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      currentJobId = '';
      _setPhase(AnimationPhase.error, e.toString());
    }
  }

  /// Shared save path for the driver (video bytes from the page) and
  /// the v92 backend (MP4 bytes from the channel). The backend does
  /// not know the detected size/duration, so it passes the requested
  /// ones as the estimate (width/height default to the 1620x2880
  /// Zedge spec).
  Future<void> _finishBytes(Uint8List bytes,
      {int width = 1620,
      int height = 2880,
      double durationSec = 0}) async {
    // v154 — the choke point: the bytes MUST be an MP4 before
    // anything is saved. Live 2026-11-22 an auth-gated download
    // answered HTTP 200 with an HTML sign-in page, which was saved
    // as `.mp4` and marked "Animation ready ✓"; the player then
    // failed with ExoPlayer "Source error" and the card claimed
    // 60fps for a file that was never a video. A bad download now
    // fails the job here, with a clear message, instead.
    if (!isMp4Bytes(bytes)) {
      throw 'Video download thik hoyni — file-ti MP4 na '
          '(${bytes.length} byte pelam). Abar try koro.';
    }
    // v154 — the real fps + duration from the file itself, never a
    // hardcoded 60fps: live 2026-11-22 the rendered file was 30fps
    // while the card claimed 60fps. The prompt asks for 60fps
    // (see start() lead + spec suffix) but Gemini's encoder
    // decides — so the record + card show what actually arrived.
    final info = readMp4Info(bytes);
    final fps = info?.fps ?? 0;
    final realDurationSec = (info != null && info.durationSec > 0)
        ? info.durationSec
        : durationSec;
    final dir = await videosDir();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final fileName = 'anim_$id.mp4';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    final size = await file.length();
    final title = _titleFor(currentPrompt);
    final video = AnimationVideo(
      id: id,
      title: title,
      prompt: currentPrompt,
      modelId: currentModelId,
      styleId: selectedStyleId,
      requestedDurationSec: selectedDurationSec,
      localPath: file.path,
      fileName: fileName,
      width: width,
      height: height,
      durationSec: realDurationSec,
      fps: fps,
      sizeBytes: size,
      createdAt: DateTime.now(),
    );
    videos = [video, ...videos];
    await _save();
    _jobTimer?.cancel();
    if (taskMode) {
      ForegroundKeepAlive.release();
      await ForegroundKeepAlive.notifyDone(
          'Animation ready', '"$title" download hoye geche.');
    }
    currentJobId = '';
    _setPhase(AnimationPhase.ready);
    // v154 — say so on the status line when Gemini rendered slower
    // than the 60fps that was asked for, so the next report names
    // it instead of the card silently claiming 60fps.
    // v159 second pass — same for an over-target file: the clip
    // was asked for under 10 MB, so when Gemini gives a bigger
    // file the status names it (the card's sizeNote shows it too).
    // The video itself stays usable — size never blocks anything.
    final sizeNotes = <String>[];
    if (fps > 0 && fps != 60) {
      sizeNotes.add('video ${fps}fps-e esheche (60fps chawa hoyechilo)');
    }
    if (size > kVideoTargetMaxSizeBytes) {
      sizeNotes.add(
          'file ${(size / 1000000).toStringAsFixed(1)} MB — 10 MB chawa hoyechilo');
    }
    if (sizeNotes.isNotEmpty) {
      status = 'Animation ready ✓ — ${sizeNotes.join('; ')}.';
      _emit();
    }
    // v161 — AUTO AI metadata on video-ready (user order
    // 2026-11-22: "ভিডিও জেনারেশন শেষ হলে অটো মেটা ডেটা নেবে"):
    // a finished video fetches its own metadata — no sparkle
    // tap needed. Only when a generator exists (tests / builds
    // without one keep the old behaviour exactly — the null
    // early-return in generateMetadataForVideo would otherwise
    // clobber the ready status). A failure never blocks the
    // video: generateMetadataForVideo records metadataFailed on
    // it, and the ready status (with the fps/size notes) is
    // restored instead of being overwritten by the error.
    if (_metadataGenerator != null) {
      final readyStatus = status;
      final ok = await generateMetadataForVideo(video);
      if (!ok) {
        status = readyStatus;
        _emit();
      }
    }
    // v163 — the video is FULLY finished now (metadata included):
    // the bulk runner may start the next line.
    _markJobDone();
  }

  String _titleFor(String prompt) {
    final p = prompt.trim();
    if (p.isEmpty) return 'Animation ${videos.length + 1}';
    // v154 — the title IS the prompt, not a 40-char fragment: live
    // 2026-11-22 the card read "High-angle vertical 9:16 c…" for a
    // long polished prompt, which identifies nothing. Cap at 120
    // chars on a word boundary instead; the card ellipsises anyway.
    if (p.length <= 120) return p;
    final cut = p.substring(0, 120);
    final lastSpace = cut.lastIndexOf(' ');
    final head = lastSpace > 60 ? cut.substring(0, lastSpace) : cut;
    return '$head…';
  }

  Future<void> deleteVideo(AnimationVideo video) async {
    videos = videos.where((v) => v.id != video.id).toList();
    await _save();
    try {
      await File(video.localPath).delete();
    } catch (_) {}
    _emit();
  }

  void _replaceVideo(AnimationVideo updated) {
    videos = [
      for (final v in videos) v.id == updated.id ? updated : v,
    ];
  }

  /// v87 — generates AI listing metadata for one video (title /
  /// tags / category / description) via the injected generator
  /// (the app wires the StudioEngine's Gemini session). Returns
  /// false when it cannot run — [status] says why.
  Future<bool> generateMetadataForVideo(AnimationVideo video) async {
    if (_metadataGenerator == null) {
      status = 'Metadata generation ei build-e nei.';
      _emit();
      return false;
    }
    if (busyVideoId == video.id) return false;
    busyVideoId = video.id;
    busyAction = 'metadata';
    status = 'AI Metadata banacche…';
    _emit();
    try {
      final meta = await _metadataGenerator(video);
      _replaceVideo(
          video.copyWith(metadata: meta, metadataFailed: false));
      await _save();
      status = 'AI Metadata ready: "${meta.title}"';
      return true;
    } catch (e) {
      status = 'Metadata hoyni: $e';
      // v161 — the failure is recorded ON the video, so the card
      // can show the Banglish note + manual retry (the video
      // itself stays usable; a failed fetch never blocks it).
      // A later success clears the flag (see above).
      _replaceVideo(video.copyWith(metadataFailed: true));
      await _save();
      return false;
    } finally {
      busyVideoId = null;
      busyAction = '';
      _emit();
    }
  }

  /// v166 — candidate cover frames for the manual picker on the
  /// video card (an empty result when the fetcher is not wired,
  /// e.g. tests, or when nothing could be captured). v167: an
  /// empty or all-dark result is written to the Error log with
  /// the per-path diagnostic, so the next black-thumb failure
  /// names the path instead of failing silently. A fetch failure
  /// is swallowed the same way — the card shows its own note.
  Future<CoverCandidatesResult> coverCandidates(AnimationVideo video) async {
    final fetcher = _coverCandidatesFetcher;
    if (fetcher == null) {
      return const CoverCandidatesResult(frames: []);
    }
    try {
      final result = await fetcher(video);
      if (result.frames.isEmpty || result.allDark) {
        unawaited(_logError('Cover frame: '
            '${result.diagnostic.isEmpty ? 'kono frame pelam na' : result.diagnostic}'));
      }
      return result;
    } catch (e) {
      return CoverCandidatesResult(
          frames: [], diagnostic: 'fetch korte giye vul: $e');
    }
  }

  /// v166 — the user picked a cover frame on the card ([timeMs]
  /// into the video; -1 = back to Auto). Persisted on the video
  /// so the pick survives a restart and the next panel upload
  /// captures exactly this timestamp.
  Future<void> pickCoverFrame(AnimationVideo video, int timeMs) async {
    _replaceVideo(video.copyWith(pickedCoverTimeMs: timeMs));
    await _save();
    status = timeMs >= 0
        ? 'Cover frame beche neoa holo (${(timeMs / 1000).toStringAsFixed(1)}s) — porer upload-e eitai jabe.'
        : 'Cover frame Auto-te firlo — upload-e gate-passing frame use hobe.';
    _emit();
  }

  /// v87 — uploads one video to the panel (R2 file + Firebase
  /// queue record). Generates the AI metadata first when the
  /// video has none yet (same as the image sets). Returns false
  /// on failure — [status] says why.
  Future<bool> uploadVideoToPanel(AnimationVideo video,
      {String targetAccount = 'spread'}) async {
    if (_panelUploader == null) {
      status = 'Panel upload ei build-e nei.';
      _emit();
      return false;
    }
    if (busyVideoId == video.id) return false;
    busyVideoId = video.id;
    busyAction = 'upload';
    status = 'Panel-e upload hocche…';
    _emit();
    try {
      final result =
          await _panelUploader(video, targetAccount: targetAccount);
      _replaceVideo(video.copyWith(
        metadata: result.metadata,
        // v158 — the cover URL the upload returned (null keeps
        // the video's stored cover, e.g. a previous upload's).
        thumbUrl: result.thumbUrl,
        uploadedToPanel: {
          'accountName': result.accountName,
          'firebaseKey': result.firebaseKey,
          'uploadedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ));
      await _save();
      // v159 — the video uploaded fine, but a cover failure must
      // not vanish: write the actual step + reason into the
      // persisted error log so the Animation screen shows WHY the
      // panel card has no cover (live 2026-11-22: v158 swallowed
      // it with a brief status note and the record went without
      // thumbUrl, with nothing to diagnose from).
      if (result.coverError != null && result.coverError!.isNotEmpty) {
        await _logError('Cover (${video.fileName}): ${result.coverError}');
      }
      status = 'Panel-e upload hoye geche (${result.accountName}) ✓';
      return true;
    } catch (e) {
      // v159 second pass — the thumbnail block must land in the
      // persisted error log (step + exception), not just the
      // status line: the StudioEngine throws 'Thumbnail banano
      // jayni…' before the Firebase push, and the video stays on
      // the device — the log is how the Animation screen shows
      // WHY it is still there. Other upload failures keep the
      // old behaviour (status only).
      if ('$e'.contains('Thumbnail banano jayni')) {
        await _logError('Cover (${video.fileName}): $e');
      }
      status = 'Panel upload hoyni: $e';
      return false;
    } finally {
      busyVideoId = null;
      busyAction = '';
      _emit();
    }
  }

  /// v157 — the per-video panel section choice (Live Wallpaper /
  /// Charging Animation) from the card chips. Persisted with the
  /// video, so Upload-all uses each video's own choice and the
  /// choice survives a restart. No-op when unchanged.
  Future<void> setVideoPanelType(
      AnimationVideo video, String panelType) async {
    final type = normalizeVideoPanelType(panelType);
    if (type == video.panelType) return;
    _replaceVideo(video.copyWith(panelType: type));
    await _save();
    _emit();
  }

  /// v87 — uploads every video to the panel, one by one. Returns
  /// how many succeeded; failures are reported in [status].
  Future<int> uploadAllToPanel({String targetAccount = 'spread'}) async {
    var done = 0;
    for (final v in List<AnimationVideo>.from(videos)) {
      if (await uploadVideoToPanel(v, targetAccount: targetAccount)) {
        done++;
      }
    }
    status = done == videos.length
        ? 'Shob video Panel-e upload hoye geche ✓'
        : '$done/${videos.length} video upload hoyeche — baki gulo hoyni, status dekho.';
    _emit();
    return done;
  }

  /// Zips all finished videos (MP4 + a metadata.json with prompt /
  /// model per file), mirroring the image Ready ZIP. The caller
  /// shows the system save picker with the returned file.
  Future<File> buildVideosZip() async {
    final archive = Archive();
    for (final v in videos) {
      final file = File(v.localPath);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(v.fileName, bytes.length, bytes));
    }
    final meta = jsonEncode({
      'app': 'Zedge Studio — Charging Animations',
      'videos': [
        for (final v in videos)
          {
            'file': v.fileName,
            'title': v.title,
            'prompt': v.prompt,
            'model': animationModelById(v.modelId).label,
            // v88: what was asked for (style + requested length) —
            // the tool may return a shorter clip than asked.
            'style': animationMoodById(v.styleId).label,
            'requestedDurationSec': v.requestedDurationSec,
            'spec': v.specLine,
            // v87: the AI listing metadata + panel queue state ride
            // along when the video has them.
            if (v.metadata != null) 'metadata': v.metadata!.toJson(),
            if (v.isUploaded) 'uploadedToPanel': v.uploadedToPanel,
          }
      ],
    });
    final metaBytes = utf8.encode(meta);
    archive.addFile(ArchiveFile('metadata.json', metaBytes.length, metaBytes));
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) throw 'ZIP banano jayni.';
    final dir = await getTemporaryDirectory();
    final out = File(
        '${dir.path}/zedge-studio-animations-${DateTime.now().millisecondsSinceEpoch}.zip');
    await out.writeAsBytes(zipBytes);
    return out;
  }

  void dispose() {
    _jobTimer?.cancel();
    _watchdogTimer?.cancel();
    // v163 — a bulk run in flight must not dangle on a completer
    // that will never complete: stop it and release the waiter.
    _bulkCancelled = true;
    _bulkRunning = false;
    _markJobDone();
  }
}
