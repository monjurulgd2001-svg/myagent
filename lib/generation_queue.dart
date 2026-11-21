// Overnight generation queue (v47, user order): sets lined up in
// advance run one by one in the background while the phone is
// idle. Each item snapshots the designer's full settings at
// enqueue time (mode, tuning, story arc, toggles, output sizes)
// so items keep their own configuration even if the designer
// changes afterwards. Items persist as JSON in SharedPreferences,
// so the queue survives the app being closed or the phone
// restarting; an item left "running" by a dead process is reset
// to "pending" on load and simply runs again.
//
// The reference image is the one thing NOT snapshotted (it can be
// megabytes); queue items always generate from their prompt.
import 'dart:convert';

class QueueItem {
  String id;
  String prompt;
  String negativePrompt;
  String workflowMode;
  List<String?> customStages;
  String storyArc;
  String variationStrength;
  String displayTarget;
  String colorBoost;
  bool aiDirectorEnabled;
  bool autoWriteMetadata;
  bool includeFoldableCompanion;
  String landscapePrompt;
  bool forceImagePrefix;
  bool upscaleEnabled;
  bool useExactZedgeNames;
  String subfolder;
  int portraitWidth;
  int portraitHeight;
  int landscapeWidth;
  int landscapeHeight;

  /// pending | running | done | failed
  String status;
  String error;
  int createdAtMs;

  QueueItem({
    required this.id,
    required this.prompt,
    this.negativePrompt = '',
    required this.workflowMode,
    this.customStages = const [],
    this.storyArc = 'auto',
    this.variationStrength = 'clear',
    this.displayTarget = 'any',
    this.colorBoost = 'off',
    this.aiDirectorEnabled = false,
    this.autoWriteMetadata = true,
    this.includeFoldableCompanion = false,
    this.landscapePrompt = '',
    this.forceImagePrefix = true,
    this.upscaleEnabled = true,
    this.useExactZedgeNames = true,
    this.subfolder = 'Gemini_HD',
    this.portraitWidth = 1620,
    this.portraitHeight = 2880,
    this.landscapeWidth = 2800,
    this.landscapeHeight = 2400,
    this.status = 'pending',
    this.error = '',
    this.createdAtMs = 0,
  });

  /// The designer's own mode labels (kept in step with main.dart).
  String get modeLabel => switch (workflowMode) {
        'dual_single' => '9:16 + Foldable',
        'single' => 'Single 9:16',
        'set_dual' => 'Dual Set (2)',
        'set_24h' => '24-Hour Set (4)',
        'set_battery' => 'Battery Set (6)',
        _ => workflowMode,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'negativePrompt': negativePrompt,
        'workflowMode': workflowMode,
        'customStages': customStages,
        'storyArc': storyArc,
        'variationStrength': variationStrength,
        'displayTarget': displayTarget,
        'colorBoost': colorBoost,
        'aiDirectorEnabled': aiDirectorEnabled,
        'autoWriteMetadata': autoWriteMetadata,
        'includeFoldableCompanion': includeFoldableCompanion,
        'landscapePrompt': landscapePrompt,
        'forceImagePrefix': forceImagePrefix,
        'upscaleEnabled': upscaleEnabled,
        'useExactZedgeNames': useExactZedgeNames,
        'subfolder': subfolder,
        'portraitWidth': portraitWidth,
        'portraitHeight': portraitHeight,
        'landscapeWidth': landscapeWidth,
        'landscapeHeight': landscapeHeight,
        'status': status,
        'error': error,
        'createdAtMs': createdAtMs,
      };

  factory QueueItem.fromJson(Map<String, dynamic> j) => QueueItem(
        id: j['id']?.toString() ?? '',
        prompt: j['prompt']?.toString() ?? '',
        negativePrompt: j['negativePrompt']?.toString() ?? '',
        workflowMode: j['workflowMode']?.toString() ?? 'single',
        customStages: (j['customStages'] as List?)
                ?.map((e) => e?.toString())
                .toList() ??
            const [],
        storyArc: j['storyArc']?.toString() ?? 'auto',
        variationStrength: j['variationStrength']?.toString() ?? 'clear',
        displayTarget: j['displayTarget']?.toString() ?? 'any',
        colorBoost: j['colorBoost']?.toString() ?? 'off',
        aiDirectorEnabled: j['aiDirectorEnabled'] == true,
        autoWriteMetadata: j['autoWriteMetadata'] != false,
        includeFoldableCompanion: j['includeFoldableCompanion'] == true,
        landscapePrompt: j['landscapePrompt']?.toString() ?? '',
        forceImagePrefix: j['forceImagePrefix'] != false,
        upscaleEnabled: j['upscaleEnabled'] != false,
        useExactZedgeNames: j['useExactZedgeNames'] != false,
        subfolder: j['subfolder']?.toString() ?? 'Gemini_HD',
        portraitWidth: (j['portraitWidth'] as num?)?.toInt() ?? 1620,
        portraitHeight: (j['portraitHeight'] as num?)?.toInt() ?? 2880,
        landscapeWidth: (j['landscapeWidth'] as num?)?.toInt() ?? 2800,
        landscapeHeight: (j['landscapeHeight'] as num?)?.toInt() ?? 2400,
        status: j['status']?.toString() ?? 'pending',
        error: j['error']?.toString() ?? '',
        createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
      );

  static String encodeList(List<QueueItem> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  /// Parse a stored queue. An item left "running" means the
  /// process died mid-generation — reset it to "pending" so the
  /// next run picks it up again.
  static List<QueueItem> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => QueueItem.fromJson(Map<String, dynamic>.from(e)))
          .map((e) => e.status == 'running'
              ? (e..status = 'pending')
              : e)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
