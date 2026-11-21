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

/// The Zedge spec the section appends to every animation prompt
/// (mirrors the prompt the user sent Neon himself: "1620x2880 9:16
/// 60fps creative thought, realistic no logo"). The loop phrase
/// is NOT in here — the seamless switch owns it (v88), so turning
/// the switch off really removes it.
const String kAnimationSpecSuffix =
    ', 1620x2880 vertical 9:16, 60fps, realistic, no text, '
    'no logo, no watermark';

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

/// v88 — seamless loop on by default (today's behaviour).
const bool kDefaultAnimationSeamless = true;

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
String buildAnimationPrompt(
  String raw, {
  String styleId = kDefaultAnimationMoodId,
  int durationSec = kDefaultAnimationDurationSec,
  bool seamless = kDefaultAnimationSeamless,
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
    if (!lower.contains('no text')) {
      out.write(', no text, no logo, no watermark');
    }
  } else {
    out.write(kAnimationSpecSuffix);
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
  final int fps;
  final double durationSec;
  final int sizeBytes;
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
    required this.createdAt,
    this.metadata,
    this.uploadedToPanel,
  });

  AnimationVideo copyWith({
    SetMetadata? metadata,
    Map<String, dynamic>? uploadedToPanel,
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
        width: width,
        height: height,
        fps: fps,
        durationSec: durationSec,
        sizeBytes: sizeBytes,
        createdAt: createdAt,
        metadata: metadata ?? this.metadata,
        uploadedToPanel: uploadedToPanel ?? this.uploadedToPanel,
      );

  bool get hasMetadata => metadata != null && metadata!.title.isNotEmpty;

  bool get isUploaded => uploadedToPanel != null;

  String get uploadedAccount =>
      uploadedToPanel?['accountName']?.toString() ?? '';

  String get specLine {
    final dur = durationSec > 0 ? '${durationSec.toStringAsFixed(0)}s · ' : '';
    final size = sizeBytes > 0
        ? ' · ${(sizeBytes / 1048576).toStringAsFixed(1)} MB'
        : '';
    return '$dur${width}x$height · ${fps}fps$size';
  }

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
