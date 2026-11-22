/// v86 — Charging Animation section: models, prompt builder and the
/// finished-video record. Pure Dart (no Flutter imports) so the unit
/// tests can run without pumping widgets.
///
/// The section drives the user's own signed-in Gemini session in the
/// app's Gecko browser (the same session the image pipeline uses):
/// pick a model (Neon default — the user marked "Deeper analysis —
/// 4 Neon" in his Gemini app), open the web chat's "Create video"
/// tool, send the prompt, and harvest the MP4. No API key, no
/// per-clip cost; the daily video limit of his Google AI plan
/// applies instead.
library;

import 'models.dart';

/// One model in the Gemini app's picker (from the user's 2026-11-19
/// screenshot: Auto / Everyday help — 4 Hydrogen / Deeper analysis —
/// 4 Neon / Code & complex work — 4 Carbon). [locked] is true for
/// Carbon: his screenshot shows it with a padlock, so the picker
/// shows it disabled instead of letting him tap a dead option.
class AnimationModel {
  final String id;
  final String label;
  final String subtitle;
  final bool locked;
  const AnimationModel({
    required this.id,
    required this.label,
    required this.subtitle,
    this.locked = false,
  });

  /// Texts the in-page driver matches against the picker option
  /// (the web chat shows the same labels as the app).
  List<String> get matchTexts {
    switch (id) {
      case 'auto':
        return const ['Auto'];
      case 'hydrogen':
        return const ['Everyday help', 'Hydrogen'];
      case 'neon':
        return const ['Deeper analysis', 'Neon'];
      case 'carbon':
        return const ['Code & complex work', 'Carbon'];
      default:
        return [label];
    }
  }
}

const List<AnimationModel> kAnimationModels = [
  AnimationModel(id: 'auto', label: 'Auto', subtitle: 'Adapts to your needs'),
  AnimationModel(
      id: 'hydrogen', label: 'Everyday help', subtitle: '4 Hydrogen'),
  AnimationModel(
      id: 'neon', label: 'Deeper analysis', subtitle: '4 Neon'),
  AnimationModel(
      id: 'carbon',
      label: 'Code & complex work',
      subtitle: '4 Carbon',
      locked: true),
];

/// The model the section starts on: Neon, the one the user picked in
/// his Gemini app and marked for the Animation section.
const String kDefaultAnimationModel = 'neon';

AnimationModel animationModelById(String id) => kAnimationModels.firstWhere(
      (m) => m.id == id,
      orElse: () => kAnimationModels[2],
    );

/// v159 second pass — file-size ask: the user ordered generated
/// files to stay within 5–10 MB; the live "Copper Pine Energy
/// Surge" clip came back 36,279,534 bytes (29 Mbps H.264). The MP4
/// is rendered by GEMINI's encoder, not the app — the app cannot
/// re-encode it on the phone (no ffmpeg in the app; Android
/// MediaCodec cannot even decode these files; a browser
/// MediaRecorder re-encode would change the format to WebM,
/// breaking the MP4 the panel/Zedge bot expects) — so the prompt
/// ASKS for an efficiently compressed small file. It is an ask,
/// not a guarantee: the card measures the real size and names it
/// when Gemini gives a bigger file (see sizeNote).
const String kAnimationSizeAsk =
    ', efficiently compressed small file under 10 MB, mobile-optimized H.264';

/// The Zedge spec the section appends to every animation prompt
/// (mirrors the prompt the user sent Neon himself: "1620x2880 9:16
/// 60fps creative thought, realistic no logo"). The loop phrase
/// is NOT in here — the seamless switch owns it (v88), so turning
/// the switch off really removes it.
/// v154 — the frame rate is spelled out in words too ("60 frames
/// per second"): live 2026-11-22 the clip came back 30fps although
/// the prompt said "60fps", so the spec now says it twice, in
/// full, instead of relying on the bare "60fps" token.
const String kAnimationSpecSuffix =
    ', 1620x2880 vertical 9:16, 60fps, 60 frames per second, '
    'realistic, no text, no logo, no watermark';

/// v104 — originality + motion clause, appended to EVERY animation
/// prompt (not only the no-size branch). Same language the Prompt
/// Polish instruction already uses (buildVideoPolishInstruction):
/// the SENT prompt carries it too, so videos come out original
/// even when Polish was never pressed — not a copy of any existing
/// video/artwork/character/brand, no copyrighted element, no
/// common generic scene, and real continuous motion (a video, not
/// a still keyframe).
const String kAnimationOriginalityClause =
    ', original unique concept, not copied from any existing video, '
    'artwork, character or brand, no copyrighted element, avoid '
    'common generic scenes, continuous motion throughout the '
    'animation';

/// v88 — one style / mood for the animation. The [suffix] is the
/// phrase the prompt builder appends (empty for "No style").
class AnimationMood {
  final String id;
  final String label;
  final String suffix;
  const AnimationMood({
    required this.id,
    required this.label,
    this.suffix = '',
  });
}

const List<AnimationMood> kAnimationMoods = [
  AnimationMood(id: 'none', label: 'No style'),
  AnimationMood(
      id: 'cinematic',
      label: 'Cinematic',
      suffix: 'cinematic lighting, editorial photography, dramatic depth'),
  AnimationMood(
      id: 'neon',
      label: 'Neon Glow',
      suffix: 'vibrant neon glow, high contrast, electric colors'),
  AnimationMood(
      id: 'golden',
      label: 'Golden Luxury',
      suffix:
          'warm golden luxury, premium product photography, rich gold tones'),
  AnimationMood(
      id: 'calm',
      label: 'Calm',
      suffix: 'calm serene mood, soft diffused light, peaceful atmosphere'),
  AnimationMood(
      id: 'energetic',
      label: 'Energetic',
      suffix: 'dynamic energetic motion, bold vivid colors, high energy'),
  AnimationMood(
      id: 'dark',
      label: 'Dark Moody',
      suffix: 'dark moody atmosphere, dramatic rim light, deep shadows'),
];

/// The style the section starts on: Cinematic — his MH Motion
/// house standard (cinematic photoreal 3D).
const String kDefaultAnimationMoodId = 'cinematic';

AnimationMood animationMoodById(String id) =>
    kAnimationMoods.firstWhere(
      (s) => s.id == id,
      orElse: () => kAnimationMoods[1],
    );

/// v88 — clip-length choices (seconds). The video tool decides
/// the real length (his Neon clips came out ~6s); the choice is
/// the request written into the prompt, and his 10s standard is
/// the default.
const List<int> kAnimationDurations = [6, 8, 10];
const int kDefaultAnimationDurationSec = 10;

/// v159 second pass — the file-size target (user order 2026-11-22:
/// generated files must stay within 5–10 MB; the live "Copper Pine
/// Energy Surge" clip came back 36,279,534 bytes). Decimal MB, so
/// the card's number matches the byte count he knows (36.3 MB for
/// that file). The target is an ASK in the prompt (see
/// kAnimationSizeAsk) and a NOTE on the card (see sizeNote) — the
/// app cannot force Gemini's encoder, and size never blocks the
/// video itself (unlike the thumbnail guarantee).
const int kVideoTargetMaxSizeBytes = 10 * 1000 * 1000;

/// v88 — seamless loop on by default (today's behaviour).
const bool kDefaultAnimationSeamless = true;

/// v157 — the panel section a finished video uploads to. The
/// panel has no generic "Animation" type: its video types are
/// only Live Wallpaper and Charging Animation, and it files by
/// the record's contentType verbatim — so the choice lives on
/// the video and is written into the queue record at upload
/// time. Default is Charging Animation (user decision
/// 2026-11-22: per-video choice, not all-to-Charging).
const String kVideoPanelTypeCharging = 'CHARGING_ANIMATION';
const String kVideoPanelTypeLive = 'LIVE_WALLPAPER';
const String kDefaultVideoPanelType = kVideoPanelTypeCharging;

/// Normalises any stored/unknown panel type to one of the two
/// the panel knows — unknown values fall back to Charging
/// Animation instead of mis-filing the video.
String normalizeVideoPanelType(String? raw) =>
    raw == kVideoPanelTypeLive ? kVideoPanelTypeLive : kVideoPanelTypeCharging;

/// Short label for the panel-type chips on the video card.
String videoPanelTypeLabel(String type) =>
    type == kVideoPanelTypeLive ? 'Live Wallpaper' : 'Charging Animation';

/// v88 — copyright-risk terms. If the prompt names one of these,
/// the video could be a copy of someone's brand, character or
/// work — and a copy gets his Zedge account struck. The check is
/// deliberately strict (a false positive only asks him to
/// reword); the list covers the brands, franchises, characters
/// and celebrities uploaders most often type, plus "in the
/// style of" (style-copying is a strike risk too).
const List<String> kAnimationBlockedTerms = [
  'iphone',
  'samsung',
  'galaxy',
  'nike',
  'adidas',
  'puma',
  'gucci',
  'louis vuitton',
  'chanel',
  'rolex',
  'ferrari',
  'lamborghini',
  'bmw',
  'mercedes',
  'audi',
  'toyota',
  'honda',
  'tesla',
  'coca-cola',
  'coca cola',
  'pepsi',
  'mcdonald',
  'starbucks',
  'lego',
  'barbie',
  'disney',
  'pixar',
  'marvel',
  'batman',
  'superman',
  'spider-man',
  'spiderman',
  'iron man',
  'avengers',
  'star wars',
  'harry potter',
  'pokemon',
  'pikachu',
  'mario',
  'sonic',
  'minions',
  'frozen',
  'elsa',
  'mickey mouse',
  'playstation',
  'xbox',
  'nintendo',
  'fortnite',
  'minecraft',
  'call of duty',
  'fifa',
  'messi',
  'ronaldo',
  'taylor swift',
  'bts',
  'blackpink',
  'ariana grande',
  'justin bieber',
  'drake',
  'eminem',
  'michael jackson',
  'elvis',
  'netflix',
  'tiktok',
  'instagram',
  'facebook',
  'youtube',
  'google',
  'in the style of',
];

/// Returns the blocked terms found in [prompt] (case-insensitive,
/// whole-word match), in list order, deduped. Empty = safe.
List<String> checkAnimationPromptSafety(String prompt) {
  final text = prompt.toLowerCase();
  final found = <String>[];
  for (final term in kAnimationBlockedTerms) {
    final pattern =
        RegExp('\\b${RegExp.escape(term)}\\b', caseSensitive: false);
    if (pattern.hasMatch(text) && !found.contains(term)) {
      found.add(term);
    }
  }
  return found;
}

/// Builds the prompt the driver sends to Gemini: the user's words
/// plus the picked style, the requested clip length, the seamless
/// loop (when on) and the Zedge spec. Returns '' for a blank
/// prompt (the Generate button stays disabled then). A prompt
/// that already carries the size keeps it (never written twice);
/// a prompt that already asks for a loop never gets it twice.
/// v154 — [fpsRetry] is the manual "abar 60fps-e banaw" retry: the
/// previous clip came back under 60fps, so the prompt says it once
/// more, emphatically (NOT 30fps). A retry is always the user's
/// tap, never automatic — a regeneration spends video quota.
String buildAnimationPrompt(
  String raw, {
  String styleId = kDefaultAnimationMoodId,
  int durationSec = kDefaultAnimationDurationSec,
  bool seamless = kDefaultAnimationSeamless,
  bool fpsRetry = false,
}) {
  final p = raw.trim();
  if (p.isEmpty) return '';
  final lower = p.toLowerCase();
  final out = StringBuffer(p);
  final style = animationMoodById(styleId);
  if (style.suffix.isNotEmpty) out.write(', ${style.suffix}');
  if (durationSec > 0) out.write(', $durationSec seconds long');
  if (seamless && !lower.contains('seamless loop')) {
    out.write(', seamless loop');
  }
  // v104 — originality + motion on EVERY prompt (see
  // kAnimationOriginalityClause). Skipped only when the user
  // already asked for originality themselves.
  if (!lower.contains('original')) {
    out.write(kAnimationOriginalityClause);
  }
  if (p.contains('1620') || p.contains('9:16')) {
    // v154 — the size branch skipped the spec suffix, so it also
    // skipped the frame rate: a prompt that already carries the
    // size still gets the 60fps ask in full words.
    if (!lower.contains('60fps') &&
        !lower.contains('frames per second')) {
      out.write(', 60fps, 60 frames per second');
    }
    if (!lower.contains('no text')) {
      out.write(', no text, no logo, no watermark');
    }
  } else {
    out.write(kAnimationSpecSuffix);
  }
  // v159 second pass — the size ask rides on EVERY prompt (both
  // branches: the size branch above skips the spec suffix, so
  // this lives outside the if/else). Short, so it does not dilute
  // the rest of the prompt; skipped only when the user already
  // asked for a small file themselves.
  if (!lower.contains('under 10 mb') && !lower.contains('10 mb')) {
    out.write(kAnimationSizeAsk);
  }
  if (fpsRetry) {
    out.write(', IMPORTANT: render this at 60 frames per second '
        '(60fps) — smooth high-frame-rate motion, NOT 30fps');
  }
  return out.toString();
}

/// One finished charging animation, stored on the device.
///
/// v87: [metadata] is the AI listing metadata (title / tags /
/// category / description — the same SetMetadata the image sets
/// use, generated by the user's own Gemini session from the video
/// prompt). [uploadedToPanel] mirrors SetEntry.uploadedToPanel:
/// {accountName, firebaseKey, uploadedAt} once the video is queued
/// on the panel.
/// v88: [styleId] is the style/mood the video was asked for and
/// [requestedDurationSec] the clip length that was asked for —
/// what the video tool actually returned can differ ([durationSec]
/// is the detected real length), so both are kept for the ZIP
/// metadata and for re-running the same settings.
class AnimationVideo {
  final String id;
  final String title;
  final String prompt;
  final String modelId;
  final String styleId;
  final int requestedDurationSec;
  final String localPath;
  final String fileName;
  final int width;
  final int height;
  // v154 — the MEASURED frame rate of the saved file (MP4 probe in
  // _finishBytes / load). The 60 default is only the fallback for a
  // file whose rate could not be read — the card never shows the
  // asked 60fps as if it were measured (live 2026-11-22: the clip
  // was 30fps while the card said 60fps).
  final int fps;
  final double durationSec;
  final int sizeBytes;
  // v157 — the panel section this video uploads to (per-video
  // choice on the card, default Charging Animation). Persisted
  // with the video so Upload-all uses each video's own choice.
  final String panelType;
  // v158 — the panel cover URL for this video (uploaded beside
  // the MP4 as the record's thumbUrl). Persisted with the video
  // so a re-upload/retry reuses the same cover instead of
  // capturing and uploading the frame again. Empty when the
  // video has never carried a cover.
  final String thumbUrl;
  final DateTime createdAt;
  final SetMetadata? metadata;
  final Map<String, dynamic>? uploadedToPanel;

  const AnimationVideo({
    required this.id,
    required this.title,
    required this.prompt,
    required this.modelId,
    this.styleId = kDefaultAnimationMoodId,
    this.requestedDurationSec = kDefaultAnimationDurationSec,
    required this.localPath,
    required this.fileName,
    this.width = 1620,
    this.height = 2880,
    this.fps = 60,
    this.durationSec = 0,
    this.sizeBytes = 0,
    this.panelType = kDefaultVideoPanelType,
    this.thumbUrl = '',
    required this.createdAt,
    this.metadata,
    this.uploadedToPanel,
  });

  AnimationVideo copyWith({
    SetMetadata? metadata,
    Map<String, dynamic>? uploadedToPanel,
    // v154 — the MP4 probe corrects these after the file lands
    // (real fps / duration / size instead of the requested spec).
    int? fps,
    double? durationSec,
    int? width,
    int? height,
    // v159 second pass — the measured file size (load() re-probes
    // it from the file; without this the size could never be
    // corrected after the fact).
    int? sizeBytes,
    // v157 — the per-video panel section choice.
    String? panelType,
    // v158 — the cached panel cover URL (reused on re-upload).
    String? thumbUrl,
  }) =>
      AnimationVideo(
        id: id,
        title: title,
        prompt: prompt,
        modelId: modelId,
        styleId: styleId,
        requestedDurationSec: requestedDurationSec,
        localPath: localPath,
        fileName: fileName,
        width: width ?? this.width,
        height: height ?? this.height,
        fps: fps ?? this.fps,
        durationSec: durationSec ?? this.durationSec,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        panelType: panelType ?? this.panelType,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        createdAt: createdAt,
        metadata: metadata ?? this.metadata,
        uploadedToPanel: uploadedToPanel ?? this.uploadedToPanel,
      );

  bool get hasMetadata => metadata != null && metadata!.title.isNotEmpty;

  bool get isUploaded => uploadedToPanel != null;

  /// v154 — the settings the video was asked for (style + asked
  /// length): stored since v88 but never shown on the card, so a
  /// finished video looked like a bare truncated prompt. The card
  /// shows this line next to the real spec line.
  String get settingsLine =>
      '${animationMoodById(styleId).label} · ${requestedDurationSec}s asked';

  /// v154 — honest fps note: [fps] is the MEASURED frame rate now
  /// (see Mp4 probe), so a clip that came back under 60fps says
  /// so on the card instead of the card claiming the asked 60fps.
  /// Empty when the clip really is 60fps (or the rate is unknown).
  String get fpsNote =>
      fps > 0 && fps < 60 ? 'Gemini 60fps deyni — $fps fps' : '';

  String get uploadedAccount =>
      uploadedToPanel?['accountName']?.toString() ?? '';

  /// v154 — the length that was actually produced (the file's real
  /// duration when known, else the length that was asked for, so a
  /// card never shows no duration at all — live 2026-11-22 the
  /// `<video>` duration came back 0 and the card hid the 10s).
  double get displayDurationSec =>
      durationSec > 0 ? durationSec : requestedDurationSec.toDouble();

  /// v159 second pass — honest size note: the clip was ASKED for
  /// under 10 MB (see kAnimationSizeAsk), but Gemini's encoder
  /// decides — so a file over the target says so on the card
  /// instead of the size being silently accepted. Empty when the
  /// file is within target (or the size was never measured).
  /// The video itself stays usable: size never blocks anything
  /// (unlike the thumbnail guarantee).
  bool get isOverTargetSize => sizeBytes > kVideoTargetMaxSizeBytes;

  /// The measured file size in decimal MB ("36.3 MB" for the live
  /// 36,279,534-byte file) — decimal, so the card's number matches
  /// the byte count. Empty when the size was never measured.
  String get sizeLabel => sizeBytes > 0
      ? '${(sizeBytes / 1000000).toStringAsFixed(1)} MB'
      : '';

  String get sizeNote => isOverTargetSize
      ? 'Gemini 10 MB-er boro file diyeche — $sizeLabel (10 MB chawa hoyechilo)'
      : '';

  String get specLine {
    // v154 — duration = what was produced (else what was asked);
    // fps = the file's REAL fps, left out entirely when it was
    // never measured (fps 0) instead of claiming a hardcoded 60 —
    // live 2026-11-22 the file was 30fps while the card said 60fps.
    // v159 second pass — the size is the MEASURED file size in
    // decimal MB (36,279,534 bytes reads "36.3 MB"); the model
    // field is set at save time (_finishBytes) and re-probed on
    // load, so the card never shows a size that was only asked for.
    final dur = displayDurationSec > 0
        ? '${displayDurationSec.toStringAsFixed(0)}s · '
        : '';
    final fpsPart = fps > 0 ? ' · ${fps}fps' : '';
    final size = sizeLabel.isEmpty ? '' : ' · $sizeLabel';
    return '$dur${width}x$height$fpsPart$size';
  }

  /// v154 — the gallery card's second line: spec (duration · size ·
  /// real fps) + STYLE + model. The style was stored (styleId) but
  /// never shown, so the card read like a generic file — live
  /// 2026-11-22 the user said "মেটাডেটাও কিন্তু নেয় নি". The title
  /// above it is the prompt itself (AnimationEngine._titleFor,
  /// capped at 120 chars on a word boundary), so title + style +
  /// duration are now all on the card, taken from the job itself —
  /// nothing invented.
  String get cardLine =>
      '$specLine · ${animationMoodById(styleId).label} · '
      '${animationModelById(modelId).label}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
        'modelId': modelId,
        'styleId': styleId,
        'requestedDurationSec': requestedDurationSec,
        'localPath': localPath,
        'fileName': fileName,
        'width': width,
        'height': height,
        'fps': fps,
        'durationSec': durationSec,
        'sizeBytes': sizeBytes,
        'panelType': panelType,
        'thumbUrl': thumbUrl,
        'createdAt': createdAt.toIso8601String(),
        if (metadata != null) 'metadata': metadata!.toJson(),
        if (uploadedToPanel != null) 'uploadedToPanel': uploadedToPanel,
      };

  static AnimationVideo? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      SetMetadata? meta;
      final rawMeta = j['metadata'];
      if (rawMeta is Map) {
        meta =
            SetMetadata.fromJson(Map<String, dynamic>.from(rawMeta));
      }
      Map<String, dynamic>? uploaded;
      final rawUp = j['uploadedToPanel'];
      if (rawUp is Map) {
        uploaded = Map<String, dynamic>.from(rawUp);
      }
      return AnimationVideo(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? 'Animation').toString(),
        prompt: (j['prompt'] ?? '').toString(),
        modelId: (j['modelId'] ?? kDefaultAnimationModel).toString(),
        styleId: (j['styleId'] ?? kDefaultAnimationMoodId).toString(),
        requestedDurationSec:
            (j['requestedDurationSec'] as num?)?.toInt() ??
                kDefaultAnimationDurationSec,
        localPath: (j['localPath'] ?? '').toString(),
        fileName: (j['fileName'] ?? '').toString(),
        width: (j['width'] as num?)?.toInt() ?? 1620,
        height: (j['height'] as num?)?.toInt() ?? 2880,
        fps: (j['fps'] as num?)?.toInt() ?? 60,
        durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        panelType: normalizeVideoPanelType(j['panelType']?.toString()),
        thumbUrl: (j['thumbUrl'] ?? '').toString(),
        createdAt: DateTime.tryParse((j['createdAt'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        metadata: meta,
        uploadedToPanel: uploaded,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Phases of one animation generation, shown as the status line
/// under the Generate button.
enum AnimationPhase {
  idle,
  opening,
  selectingModel,
  openingTool,
  creating,
  downloading,
  ready,
  error,
}

/// One event from the in-page video driver, carried over the same
/// `browserRequest` channel as the picture overlay (action
/// 'video_progress' | 'video_ready' | 'video_error', payload in
/// [data]). Pure parse so the unit tests cover it without a browser.
class AnimationVideoEvent {
  final String action;
  final String jobId;
  final String phase;
  final String message;
  final String url;
  final String dataUrl;
  final double durationSec;
  final int width;
  final int height;
  final String step;
  final String buttons;

  const AnimationVideoEvent({
    required this.action,
    this.jobId = '',
    this.phase = '',
    this.message = '',
    this.url = '',
    this.dataUrl = '',
    this.durationSec = 0,
    this.width = 1620,
    this.height = 2880,
    this.step = '',
    this.buttons = '',
  });

  bool get isVideo =>
      action == 'video_progress' ||
      action == 'video_ready' ||
      action == 'video_error';

  /// Parses the `data` map of a [GeckoBrowserRequest]-style event
  /// (a plain map in tests, the request's data in the app).
  static AnimationVideoEvent? fromData(String action, Object? data) {
    if (data is! Map) return null;
    try {
      return AnimationVideoEvent(
        action: action,
        jobId: (data['jobId'] ?? '').toString(),
        phase: (data['phase'] ?? '').toString(),
        message: (data['message'] ?? '').toString(),
        url: (data['url'] ?? '').toString(),
        dataUrl: (data['dataUrl'] ?? '').toString(),
        durationSec: (data['durationSec'] as num?)?.toDouble() ?? 0,
        width: (data['width'] as num?)?.toInt() ?? 1620,
        height: (data['height'] as num?)?.toInt() ?? 2880,
        step: (data['step'] ?? '').toString(),
        buttons: (data['buttons'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
