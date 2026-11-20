// Data models for Gemini HD Studio (Flutter port of the v2.5.3 extension).
// Mirrors the extension's history / metadata / dist-config shapes so the
// Ready ZIP and Firebase panel records stay byte-compatible in meaning.

class GeminiAccount {
  final int authUser;
  final String email;
  final String bl;
  const GeminiAccount(
      {required this.authUser, required this.email, required this.bl});

  Map<String, dynamic> toJson() =>
      {'authUser': authUser, 'email': email, 'bl': bl};
  factory GeminiAccount.fromJson(Map<String, dynamic> j) => GeminiAccount(
        authUser: (j['authUser'] as num?)?.toInt() ?? 0,
        email: j['email']?.toString() ?? '',
        bl: j['bl']?.toString() ?? '',
      );
}

class GeminiSession {
  final int authUser;
  final String email;
  final String at; // SNlM0e token (never logged)
  final String bl;
  final String fSid;
  final String cookieHeader;
  final int fetchedAtMs;

  /// v92 — Task backend: API keys (AIza…) found in the Gemini page
  /// HTML (the signaler key is one of them; the client tries each
  /// for chooseServer) and the X-Server-Token (page key "PI9WOb").
  /// Extracted at session fetch, never hardcoded.
  final List<String> apiKeys;
  final String serverToken;
  const GeminiSession({
    required this.authUser,
    required this.email,
    required this.at,
    required this.bl,
    required this.fSid,
    required this.cookieHeader,
    required this.fetchedAtMs,
    this.apiKeys = const [],
    this.serverToken = '',
  });
  bool get isFresh =>
      DateTime.now().millisecondsSinceEpoch - fetchedAtMs < 15 * 60 * 1000;
}

class SetMetadata {
  String file;
  String title;
  List<String> tags;
  String category;
  String description;
  int generatedAtMs;
  SetMetadata({
    this.file = '',
    this.title = '',
    List<String>? tags,
    this.category = '',
    this.description = '',
    this.generatedAtMs = 0,
  }) : tags = tags ?? <String>[];

  String get keywords => tags.join(', ');

  Map<String, dynamic> toJson() => {
        'file': file,
        'title': title,
        'tags': tags,
        'keywords': keywords,
        'category': category,
        'description': description,
        'model': 'gemini-web (cookie)',
        'generatedAt': generatedAtMs,
      };

  /// The exact record shape used inside the Ready ZIP's root metadata.json.
  Map<String, dynamic> toZipJson() => {
        'file': file,
        'title': title,
        'tags': tags,
        'keywords': keywords,
        'category': category,
        'description': description,
      };

  factory SetMetadata.fromJson(Map<String, dynamic> j) => SetMetadata(
        file: j['file']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[],
        category: j['category']?.toString() ?? '',
        description: j['description']?.toString() ?? '',
        generatedAtMs: (j['generatedAt'] as num?)?.toInt() ?? 0,
      );
}

class StageDef {
  final String key;
  final String distSlot;
  final String zipName;
  final int slotIndex;
  final String role;
  final String badge;
  final String shortLabel;
  final String exactFilename;
  final bool isAnchor;
  final String promptSuffix;
  final String transitionInstruction;
  const StageDef({
    required this.key,
    required this.distSlot,
    required this.zipName,
    required this.slotIndex,
    required this.role,
    required this.badge,
    required this.shortLabel,
    required this.exactFilename,
    this.isAnchor = false,
    this.promptSuffix = '',
    this.transitionInstruction = '',
  });
}

class SetImage {
  String localPath; // absolute path of the final JPG on this device
  String exactFilename;
  String zipName;
  String distSlot;
  String role;
  String label;
  String badge;
  int slotIndex;
  String stageKey;
  String stagePrompt;
  String? hdUrl;
  bool upscaledViaCloudinary;
  int width;
  int height;
  int byteSize;
  SetImage({
    required this.localPath,
    required this.exactFilename,
    required this.zipName,
    required this.distSlot,
    required this.role,
    required this.label,
    required this.badge,
    required this.slotIndex,
    required this.stageKey,
    this.stagePrompt = '',
    this.hdUrl,
    this.upscaledViaCloudinary = false,
    this.width = 0,
    this.height = 0,
    this.byteSize = 0,
  });

  double get megapixels => (width * height) / 1000000;
  bool get zedgeCompliant =>
      width >= 1620 &&
      height >= 2880 &&
      width * height < 25000000 &&
      byteSize <= 8 * 1024 * 1024;

  Map<String, dynamic> toJson() => {
        'localPath': localPath,
        'exactFilename': exactFilename,
        'zipName': zipName,
        'distSlot': distSlot,
        'role': role,
        'label': label,
        'badge': badge,
        'slotIndex': slotIndex,
        'stageKey': stageKey,
        'stagePrompt': stagePrompt,
        'hdUrl': hdUrl,
        'upscaledViaCloudinary': upscaledViaCloudinary,
        'width': width,
        'height': height,
        'byteSize': byteSize,
      };

  factory SetImage.fromJson(Map<String, dynamic> j) => SetImage(
        localPath: j['localPath']?.toString() ?? '',
        exactFilename: j['exactFilename']?.toString() ?? '',
        zipName: j['zipName']?.toString() ?? '',
        distSlot: j['distSlot']?.toString() ?? '',
        role: j['role']?.toString() ?? '',
        label: j['label']?.toString() ?? '',
        badge: j['badge']?.toString() ?? '',
        slotIndex: (j['slotIndex'] as num?)?.toInt() ?? 0,
        stageKey: j['stageKey']?.toString() ?? '',
        stagePrompt: j['stagePrompt']?.toString() ?? '',
        hdUrl: j['hdUrl']?.toString(),
        upscaledViaCloudinary: j['upscaledViaCloudinary'] == true,
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        byteSize: (j['byteSize'] as num?)?.toInt() ?? 0,
      );
}

class DirectorPlan {
  final String arc;
  final String anchorDirection;
  final List<String> palette;
  final List<String> stageDirections; // aligned with stage order
  const DirectorPlan({
    required this.arc,
    required this.anchorDirection,
    required this.palette,
    required this.stageDirections,
  });
  Map<String, dynamic> toJson() => {
        'arc': arc,
        'anchor': anchorDirection,
        'palette': palette,
        'stages': stageDirections,
      };
  factory DirectorPlan.fromJson(Map<String, dynamic> j) => DirectorPlan(
        arc: j['arc']?.toString() ?? '',
        anchorDirection: j['anchor']?.toString() ?? '',
        palette: (j['palette'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[],
        stageDirections:
            (j['stages'] as List?)?.map((e) => e.toString()).toList() ??
                <String>[],
      );
}

class SetEntry {
  String id;
  String prompt;
  String
      workflowMode; // set_dual | set_24h | set_battery | single | img2img_file
  String setTypeLabel;
  String setFolderName;
  String? anchorHdUrl;
  DirectorPlan? directorPlan;
  SetMetadata? metadata;
  String createdAtIso;
  List<SetImage> images;
  Map<String, dynamic>? uploadedToPanel;
  SetEntry({
    required this.id,
    required this.prompt,
    required this.workflowMode,
    required this.setTypeLabel,
    required this.setFolderName,
    this.anchorHdUrl,
    this.directorPlan,
    this.metadata,
    required this.createdAtIso,
    required this.images,
    this.uploadedToPanel,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'workflowMode': workflowMode,
        'setTypeLabel': setTypeLabel,
        'setFolderName': setFolderName,
        'anchorHdUrl': anchorHdUrl,
        'directorPlan': directorPlan?.toJson(),
        'metadata': metadata?.toJson(),
        'createdAt': createdAtIso,
        'images': images.map((e) => e.toJson()).toList(),
        'uploadedToPanel': uploadedToPanel,
      };

  factory SetEntry.fromJson(Map<String, dynamic> j) => SetEntry(
        id: j['id']?.toString() ?? '',
        prompt: j['prompt']?.toString() ?? '',
        workflowMode: j['workflowMode']?.toString() ?? '',
        setTypeLabel: j['setTypeLabel']?.toString() ?? '',
        setFolderName: j['setFolderName']?.toString() ?? '',
        anchorHdUrl: j['anchorHdUrl']?.toString(),
        directorPlan: j['directorPlan'] is Map
            ? DirectorPlan.fromJson(
                Map<String, dynamic>.from(j['directorPlan'] as Map))
            : null,
        metadata: j['metadata'] is Map
            ? SetMetadata.fromJson(
                Map<String, dynamic>.from(j['metadata'] as Map))
            : null,
        createdAtIso: j['createdAt']?.toString() ?? '',
        images: (j['images'] as List?)
                ?.whereType<Map>()
                .map((e) => SetImage.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            <SetImage>[],
        uploadedToPanel: j['uploadedToPanel'] is Map
            ? Map<String, dynamic>.from(j['uploadedToPanel'] as Map)
            : null,
      );
}

class DistAccount {
  String name;
  String dbUrl;
  String secret;
  DistAccount({this.name = '', this.dbUrl = '', this.secret = ''});
  Map<String, dynamic> toJson() =>
      {'name': name, 'dbUrl': dbUrl, 'secret': secret};
  factory DistAccount.fromJson(Map<String, dynamic> j) => DistAccount(
        name: j['name']?.toString() ?? '',
        dbUrl: j['dbUrl']?.toString() ?? '',
        secret: j['secret']?.toString() ?? '',
      );
}

class DistConfig {
  String r2WorkerUrl;
  String queuePath;
  List<DistAccount> accounts;
  String defaultTarget;
  DistConfig({
    this.r2WorkerUrl = '',
    this.queuePath = 'wallpaperQueue',
    List<DistAccount>? accounts,
    this.defaultTarget = 'spread',
  }) : accounts = accounts ?? <DistAccount>[];

  Map<String, dynamic> toJson() => {
        'r2WorkerUrl': r2WorkerUrl,
        'queuePath': queuePath,
        'accounts': accounts.map((e) => e.toJson()).toList(),
        'defaultTarget': defaultTarget,
        'spreadPool': accounts.map((e) => e.name).toList(),
      };
  factory DistConfig.fromJson(Map<String, dynamic> j) => DistConfig(
        r2WorkerUrl: j['r2WorkerUrl']?.toString() ?? '',
        queuePath: j['queuePath']?.toString() ?? 'wallpaperQueue',
        accounts: (j['accounts'] as List?)
                ?.whereType<Map>()
                .map((e) => DistAccount.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            <DistAccount>[],
        defaultTarget: j['defaultTarget']?.toString() ?? 'spread',
      );
}

class StatusEvent {
  final String state;
  final int step;
  final String message;
  const StatusEvent(this.state, this.step, this.message);
}

/// Progress callback shared by the API, image and engine layers
/// (the extension's broadcastStatus equivalent).
typedef StatusSink = void Function(StatusEvent e);
