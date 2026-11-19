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
import 'gecko_browser.dart';
import 'models.dart';
import 'task_backend.dart';

/// Where the finished videos live on the device, and where the
/// video list + Task-mode choice are persisted.
const String kAnimationVideosKey = 'animationVideosJson';
const String kAnimationTaskModeKey = 'animTaskMode';
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

typedef OpenBrowser = Future<void> Function(String url);
typedef SendVideoJob = Future<void> Function(
    String prompt, String modelId, String jobId);

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
    })> Function(AnimationVideo video, {String targetAccount});

/// v88 — injected by the app: polishes a rough animation idea
/// into a production-ready video prompt (the StudioEngine's
/// Gemini session). Null in tests that do not provide it.
typedef VideoPromptPolisher = Future<String> Function(String prompt);

/// v92 — injected by the app: the Task-mode video BACKEND (no
/// browser). Returns the finished MP4 bytes, or throws
/// [TaskBackendException] naming the failed step. Null in tests and
/// in builds without a backend — the browser driver runs instead.
typedef TaskBackendRunner = Future<Uint8List> Function(
  String taskText, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
});

Future<void> _defaultOpenBrowser(String url) =>
    GeckoBrowser.instance.open(url);

Future<void> _defaultSendVideoJob(
        String prompt, String modelId, String jobId) =>
    GeckoBrowser.instance.startVideo(prompt, modelId, jobId);

class AnimationEngine {
  AnimationEngine({
    OpenBrowser? openBrowser,
    SendVideoJob? sendVideoJob,
    http.Client? httpClient,
    Duration jobTimeout = const Duration(minutes: 9),
    VideoMetadataGenerator? metadataGenerator,
    VideoPanelUploader? panelUploader,
    VideoPromptPolisher? promptPolisher,
    TaskBackendRunner? taskBackendRunner,
    this.onChanged,
  })  : _openBrowser = openBrowser ?? _defaultOpenBrowser,
        _sendVideoJob = sendVideoJob ?? _defaultSendVideoJob,
        _httpClient = httpClient,
        _jobTimeout = jobTimeout,
        _metadataGenerator = metadataGenerator,
        _panelUploader = panelUploader,
        _promptPolisher = promptPolisher,
        _taskBackendRunner = taskBackendRunner;

  final OpenBrowser _openBrowser;
  final SendVideoJob _sendVideoJob;
  final http.Client? _httpClient;
  final Duration _jobTimeout;
  // v89: last driver phase + when it last reported, so a timeout
  // can say WHERE the job died instead of a blind "time out".
  // (v88: the user got only the blind message after 6 min — the
  // job had never even reached the driver.)
  String _lastDriverPhase = '';
  DateTime? _lastProgressAt;
  final VideoMetadataGenerator? _metadataGenerator;
  final VideoPanelUploader? _panelUploader;
  final VideoPromptPolisher? _promptPolisher;
  final TaskBackendRunner? _taskBackendRunner;

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
    _emit();
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

  /// v88 — polishes a rough animation idea into a production-ready
  /// video prompt. Returns null when no polisher is wired or the
  /// polish fails (status says why); the user's prompt is kept.
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
      final polished = await polisher(text);
      status = 'Prompt polished ✓';
      _emit();
      return polished.trim();
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
  Future<bool> start({
    required String rawPrompt,
    required String modelId,
    required bool signedIn,
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
    );
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
    currentPrompt = rawPrompt.trim();
    currentModelId = model.id;
    currentJobId = DateTime.now().millisecondsSinceEpoch.toString();
    _lastDriverPhase = '';
    _lastProgressAt = null;
    _setPhase(AnimationPhase.opening);
    _jobTimer?.cancel();
    _jobTimer = Timer(_jobTimeout, () {
      if (busy && currentJobId.isNotEmpty) {
        _setPhase(AnimationPhase.error, _timeoutMessage());
        currentJobId = '';
      }
    });
    try {
      if (taskMode) {
        await ForegroundKeepAlive.acquire(
            'Making animation in the background — safe to switch apps');
      }
      // v92 — backend FIRST when Task mode is on: the video comes
      // through the Task channel + hNvQHb poll with no browser at
      // all. The backend runs async (same job id, same timeout);
      // any backend failure falls back to the browser driver once.
      if (taskMode && _taskBackendRunner != null) {
        unawaited(_runBackend(prompt));
        return true;
      }
      await _openBrowser(kGeminiChatUrl);
      await _sendVideoJob(prompt, model.id, currentJobId);
    } catch (e) {
      _jobTimer?.cancel();
      if (taskMode) ForegroundKeepAlive.release();
      _setPhase(AnimationPhase.error, 'Browser khola jayni: $e');
      currentJobId = '';
      return false;
    }
    return true;
  }

  /// v92 — runs the Task backend and finishes with its MP4 bytes;
  /// on any backend failure falls back to the browser driver once
  /// (same job id, same timeout) so the video still gets made.
  Future<void> _runBackend(String prompt) async {
    final jobId = currentJobId;
    final deadline = DateTime.now().add(_jobTimeout);
    try {
      final bytes = await _taskBackendRunner!(
        prompt,
        onPhase: _applyBackendPhase,
        deadline: deadline,
      );
      if (currentJobId != jobId || jobId.isEmpty) return;
      await _finishBytes(bytes,
          durationSec: selectedDurationSec.toDouble());
    } catch (e) {
      if (currentJobId != jobId || jobId.isEmpty) return;
      final step = e is TaskBackendException ? e.step : 'backend';
      // v94 — the failure detail (e.g. the HTTP status) rides along
      // so the next report names the cause, not just the step.
      final detail = e is TaskBackendException ? e.message : '$e';
      final short = detail.length > 80
          ? '${detail.substring(0, 80)}…'
          : detail;
      status = 'Backend hoyni ($step — $short) — browser diye cholche…';
      _emit();
      try {
        await _openBrowser(kGeminiChatUrl);
        await _sendVideoJob(prompt, currentModelId, jobId);
      } catch (err) {
        _jobTimer?.cancel();
        if (taskMode) ForegroundKeepAlive.release();
        _setPhase(AnimationPhase.error, 'Browser khola jayni: $err');
        currentJobId = '';
      }
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
    switch (ev.action) {
      case 'video_progress':
        _applyDriverPhase(ev.phase, ev.message);
        return true;
      case 'video_ready':
        await _finishReady(ev);
        return true;
      case 'video_error':
        _jobTimer?.cancel();
        if (taskMode) ForegroundKeepAlive.release();
        final detail = [
          if (ev.step.isNotEmpty) '(${ev.step})',
          ev.message,
          if (ev.buttons.isNotEmpty) 'Page-e ja chilo: ${ev.buttons}',
        ].join(' ').trim();
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
      return 'time out — driver-er sathe kono jogajog hoyni '
          '(browser-e Gemini page khulchilo?). Abar try koro.';
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
          final res = await client
              .get(Uri.parse(ev.url))
              .timeout(const Duration(minutes: 10));
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
      durationSec: durationSec,
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
  }

  String _titleFor(String prompt) {
    final p = prompt.trim();
    if (p.isEmpty) return 'Animation ${videos.length + 1}';
    return p.length <= 40 ? p : '${p.substring(0, 40)}…';
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
      _replaceVideo(video.copyWith(metadata: meta));
      await _save();
      status = 'AI Metadata ready: "${meta.title}"';
      return true;
    } catch (e) {
      status = 'Metadata hoyni: $e';
      return false;
    } finally {
      busyVideoId = null;
      busyAction = '';
      _emit();
    }
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
        uploadedToPanel: {
          'accountName': result.accountName,
          'firebaseKey': result.firebaseKey,
          'uploadedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ));
      await _save();
      status = 'Panel-e upload hoye geche (${result.accountName}) ✓';
      return true;
    } catch (e) {
      status = 'Panel upload hoyni: $e';
      return false;
    } finally {
      busyVideoId = null;
      busyAction = '';
      _emit();
    }
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
  }
}
