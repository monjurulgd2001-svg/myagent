// Studio workflows: set generation, local import, single regeneration,
// Ready ZIP packaging and Panel (R2 + Firebase) upload.
// Ports generateWallpaperSetWorkflow / generateDualWallpaperWorkflow /
// importLocalSetToStudio / downloadReadySetsZip / uploadSetToPanel
// from the extension's background.js. Instead of chrome.storage +
// chrome.downloads, sets live as real files under the app documents
// folder: <docs>/GeminiHDStudio/<subfolder>/<setFolder>/<exactFilename>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'animation_models.dart';
import 'gecko_signin.dart';
import 'gemini_api.dart';
import 'foreground_keep_alive.dart';
import 'image_service.dart';
import 'models.dart';
import 'studio_constants.dart';
import 'task_backend.dart';

class StudioEngine {
  StudioEngine({StatusSink? onStatus, http.Client? client})
      : onStatus = onStatus ?? ((_) {}),
        _client = client ?? http.Client(),
        gemini = GeminiApi(onStatus: onStatus),
        images = ImageService(onStatus: onStatus) {
    images.cloudinary = cloudinary;
  }

  final StatusSink onStatus;
  final GeminiApi gemini;
  final ImageService images;
  CloudinaryConfig cloudinary = CloudinaryConfig();
  final http.Client _client;

  void _status(String state, int step, String message) =>
      onStatus(StatusEvent(state, step, message));

  // -------------------------------------------------------------------
  // Local persistence (history + dist config + cloudinary config)
  // -------------------------------------------------------------------

  static const _kHistory = 'studioHistoryJson';
  static const _kDistConfig = 'distConfigJson';
  static const _kDistCursor = 'distSpreadCursor';
  static const _kCloudinary = 'cloudinaryConfigJson';

  Future<Directory> _setsRoot(String subfolder) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'GeminiHDStudio',
        subfolder.isEmpty ? 'Gemini_HD' : subfolder));
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<SetEntry>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => SetEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<SetEntry> history) async {
    final trimmed = history.take(20).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kHistory, jsonEncode(trimmed.map((e) => e.toJson()).toList()));
  }

  Future<DistConfig> loadDistConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDistConfig);
    if (raw == null || raw.isEmpty) return DistConfig();
    try {
      return DistConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return DistConfig();
    }
  }

  Future<void> saveDistConfig(DistConfig cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDistConfig, jsonEncode(cfg.toJson()));
  }

  /// Cloudinary config is BACKEND-ONLY (user order 2026-11-09): the
  /// credentials live embedded in the app code (CloudinaryConfig's
  /// defaults) and are not shown or editable in any settings UI.
  /// Any value an older build saved from the old settings screen is
  /// cleared, so the embedded config is the single source.
  Future<CloudinaryConfig> loadCloudinaryConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCloudinary);
    cloudinary = CloudinaryConfig();
    images.cloudinary = cloudinary;
    return cloudinary;
  }

  Future<File> _saveSetImage(String subfolder, String setFolder,
      String filename, Uint8List bytes) async {
    final root = await _setsRoot(subfolder);
    final dir = Directory(p.join(root.path, setFolder));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // -------------------------------------------------------------------
  // Set generation (extension: generateWallpaperSetWorkflow + dual/single)
  // -------------------------------------------------------------------

  Future<SetEntry> generateSet({
    required String prompt,
    String negativePrompt = '',
    required String
        workflowMode, // set_dual | set_24h | set_battery | single | dual_single
    List<String?> customStages = const [],
    String storyArc = 'auto',
    String variationStrength = 'clear',
    String displayTarget = 'any',
    String colorBoost = 'off',
    bool aiDirectorEnabled = false,
    bool autoWriteMetadata = true,
    bool includeFoldableCompanion = false,
    String landscapePrompt = kFoldableAdaptationPrompt,
    Uint8List? referenceBytes,
    String referenceFilename = 'reference_image.jpg',
    String referenceMime = 'image/jpeg',
    bool forceImagePrefix = true,
    bool upscaleEnabled = true,
    bool useExactZedgeNames = true,
    String subfolder = 'Gemini_HD',
    int portraitWidth = kPortraitWidth,
    int portraitHeight = kPortraitHeight,
    int landscapeWidth = kLandscapeWidth,
    int landscapeHeight = kLandscapeHeight,
  }) async {
    await ForegroundKeepAlive.acquire('Generating your set in the background');
    try {
      return await _generateSetImpl(
        prompt: prompt,
        negativePrompt: negativePrompt,
        workflowMode: workflowMode,
        customStages: customStages,
        storyArc: storyArc,
        variationStrength: variationStrength,
        displayTarget: displayTarget,
        colorBoost: colorBoost,
        aiDirectorEnabled: aiDirectorEnabled,
        autoWriteMetadata: autoWriteMetadata,
        includeFoldableCompanion: includeFoldableCompanion,
        landscapePrompt: landscapePrompt,
        referenceBytes: referenceBytes,
        referenceFilename: referenceFilename,
        referenceMime: referenceMime,
        forceImagePrefix: forceImagePrefix,
        upscaleEnabled: upscaleEnabled,
        useExactZedgeNames: useExactZedgeNames,
        subfolder: subfolder,
        portraitWidth: portraitWidth,
        portraitHeight: portraitHeight,
        landscapeWidth: landscapeWidth,
        landscapeHeight: landscapeHeight,
      );
    } finally {
      await ForegroundKeepAlive.release();
    }
  }

  /// v145 — wand repeat fix, shared by both polishes: when Gemini
  /// hands the input back unchanged, ask once more with an
  /// explicit "completely different version" ask instead of
  /// returning the same text the user already had.
  static bool _samePolishText(String a, String b) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final na = norm(a);
    return na.isNotEmpty && na == norm(b);
  }

  Future<String> _polishViaGemini(
    String prompt,
    String Function(String) buildInstruction,
    GeminiSession session,
  ) async {
    var raw = await gemini.askGeminiText(
      buildInstruction(prompt),
      session: session,
      attempts: 2,
    );
    var cleaned = GeminiApi.cleanGeneratedPrompt(raw).trim();
    if (cleaned.length > 1200) cleaned = cleaned.substring(0, 1200).trim();
    if (cleaned.isNotEmpty && _samePolishText(cleaned, prompt)) {
      try {
        raw = await gemini.askGeminiText(
          '${buildInstruction(prompt)}\n\nIMPORTANT: write a completely '
          'different, fresh version — different wording, composition, '
          'viewpoint, palette, lighting and details. Never return the '
          'input unchanged.',
          session: session,
          attempts: 2,
        );
        final retry = GeminiApi.cleanGeneratedPrompt(raw).trim();
        if (retry.isNotEmpty) {
          cleaned = retry.length > 1200
              ? retry.substring(0, 1200).trim()
              : retry;
        }
      } catch (_) {
        // Retry failed — keep the first answer, don't fail polish.
      }
    }
    return cleaned;
  }

  /// v48: polish a rough designer prompt into a production-ready
  /// one via a Gemini text call on the current session (account
  /// failover comes free from askGeminiText / getSession).
  Future<String> polishPrompt(String prompt) async {
    final session = await gemini.getSession();
    _status('generating', 1, 'Polishing prompt with Gemini...');
    final cleaned = await _polishViaGemini(
        prompt, GeminiApi.buildPolishInstruction, session);
    if (cleaned.isEmpty) {
      throw Exception(
          'Gemini returned an empty polish. Your prompt was kept.');
    }
    _status('done', 1, 'Prompt polished.');
    return cleaned;
  }

  /// v88: polish a rough animation idea into a production-ready
  /// video prompt via a Gemini text call on the current session —
  /// the video twin of polishPrompt (same session failover).
  /// v92 — Task-mode video BACKEND (no browser): runs the task
  /// through the processSession channel + hNvQHb poll (see
  /// task_backend.dart) on the same Gemini session the image
  /// pipeline uses. Throws [TaskBackendException] naming the failed
  /// step; the AnimationEngine falls back to the browser driver.
  Future<Uint8List> runTaskVideoBackend(
    String taskText, {
    required void Function(String phase, String message) onPhase,
    required DateTime deadline,
    http.Client? httpClient,
  }) async {
    final session = await gemini.getSession();
    // v125 — keep GeckoView's cookie store synced with the active
    // account's cookies before PageBackendTransport opens the headless
    // Gemini tab, so Charging Animation works with pasted cookies too.
    if (GeckoSignIn.supported && session.cookieHeader.isNotEmpty) {
      await GeckoSignIn.syncCookies(session.cookieHeader);
    }
    // v97 — the signaler key is one of the page HTML's own keys
    // (v94's bundle-keys idea was wrong, and fetching the 6 MB
    // bundle stalled 180s on a slow network). The client tries
    // session.apiKeys directly.
    final owned = httpClient == null;
    final client = TaskBackendClient(
      client: httpClient ?? http.Client(),
      session: session,
    );
    try {
      return await client.run(taskText, onPhase: onPhase, deadline: deadline);
    } finally {
      if (owned) client.close();
    }
  }

  Future<String> polishVideoPrompt(String prompt) async {
    final session = await gemini.getSession();
    _status('generating', 1, 'Polishing video prompt with Gemini...');
    final cleaned = await _polishViaGemini(
        prompt, GeminiApi.buildVideoPolishInstruction, session);
    if (cleaned.isEmpty) {
      throw Exception(
          'Gemini returned an empty polish. Your prompt was kept.');
    }
    _status('done', 1, 'Video prompt polished.');
    return cleaned;
  }

  /// v82: Auto Cinematic Scene — expands the user's short idea into
  /// one rich cinematic scene description for 24h/battery sets.
  /// Throws on an empty reply; the caller falls back to the raw
  /// prompt, so a failed expansion never blocks a set.
  Future<String> expandScenePrompt(
      String prompt, String workflowMode, GeminiSession session) async {
    final raw = await gemini.askGeminiText(
      GeminiApi.buildSceneExpansionInstruction(prompt, workflowMode),
      session: session,
      attempts: 2,
    );
    var cleaned = GeminiApi.cleanGeneratedPrompt(raw).trim();
    if (cleaned.length > 900) cleaned = cleaned.substring(0, 900).trim();
    if (cleaned.isEmpty) {
      throw Exception('Gemini returned an empty scene expansion.');
    }
    return cleaned;
  }

  /// v47 auto-retry: ONE automatic second attempt (after a short
  /// pause) for a failed stage, so a transient hiccup - a slow-net
  /// drop, a Gemini text reply instead of an image - does not kill
  /// the whole set. A second failure propagates as before.
  Future<T> _retryStage<T>(String label, Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      _status('generating', 2,
          'Auto-retry: $label failed once - trying again in 6s...');
      await Future.delayed(const Duration(seconds: 6));
      return await fn();
    }
  }

  Future<SetEntry> _generateSetImpl({
    required String prompt,
    String negativePrompt = '',
    required String
        workflowMode, // set_dual | set_24h | set_battery | single | dual_single
    List<String?> customStages = const [],
    String storyArc = 'auto',
    String variationStrength = 'clear',
    String displayTarget = 'any',
    String colorBoost = 'off',
    bool aiDirectorEnabled = false,
    bool autoWriteMetadata = true,
    bool includeFoldableCompanion = false,
    String landscapePrompt = kFoldableAdaptationPrompt,
    Uint8List? referenceBytes,
    String referenceFilename = 'reference_image.jpg',
    String referenceMime = 'image/jpeg',
    bool forceImagePrefix = true,
    bool upscaleEnabled = true,
    bool useExactZedgeNames = true,
    String subfolder = 'Gemini_HD',
    int portraitWidth = kPortraitWidth,
    int portraitHeight = kPortraitHeight,
    int landscapeWidth = kLandscapeWidth,
    int landscapeHeight = kLandscapeHeight,
  }) async {
    if (workflowMode == 'single' || workflowMode == 'dual_single') {
      return _generateSingleOrDualSingle(
        prompt: prompt,
        negativePrompt: negativePrompt,
        withFoldable: workflowMode == 'dual_single',
        landscapePrompt: landscapePrompt,
        displayTarget: displayTarget,
        colorBoost: colorBoost,
        autoWriteMetadata: autoWriteMetadata,
        forceImagePrefix: forceImagePrefix,
        upscaleEnabled: upscaleEnabled,
        subfolder: subfolder,
        portraitWidth: portraitWidth,
        portraitHeight: portraitHeight,
        landscapeWidth: landscapeWidth,
        landscapeHeight: landscapeHeight,
      );
    }

    final session = await gemini.getSession();
    final dims = normalizeZedgeDimensions(portraitWidth, portraitHeight);
    final targetWidth = dims.width;
    final targetHeight = dims.height;
    final template = stagesForMode(workflowMode);

    List<String>? arcPrompts;
    if (workflowMode == 'set_24h') {
      final resolved = storyArc == 'auto' ? suggest24hArc(prompt) : storyArc;
      arcPrompts = kStoryArcs24h[resolved] ?? kStoryArcs24h['light'];
    } else if (workflowMode == 'set_battery') {
      final resolved =
          storyArc == 'auto' ? suggestBatteryArc(prompt) : storyArc;
      arcPrompts = kStoryArcsBattery[resolved] ?? kStoryArcsBattery['energy'];
    }

    DirectorPlan? directorPlan;
    if (aiDirectorEnabled) {
      try {
        _status('generating', 1,
            'AI Set Director: Planning set story arc, anchor & stage lighting directions...');
        directorPlan = await gemini.directSetWithGemini(
          workflowMode: workflowMode,
          variantLabels: template.map((s) => s.shortLabel).toList(),
          prompt: prompt,
          session: session,
        );
      } catch (_) {
        directorPlan = null;
      }
    }

    final styleSuffix = buildStyleSuffix(displayTarget, colorBoost);
    final chainStrength =
        kVariationStrengths[variationStrength] ?? kVariationStrengths['clear']!;

    // Resolve each stage's instruction: custom > director > arc > default.
    final stageInstructions = <String>[];
    for (var idx = 0; idx < template.length; idx++) {
      final st = template[idx];
      final custom =
          idx < customStages.length ? (customStages[idx]?.trim() ?? '') : '';
      final directed =
          directorPlan != null && idx < directorPlan.stageDirections.length
              ? directorPlan.stageDirections[idx]
              : '';
      final arcDefault =
          arcPrompts != null && idx < arcPrompts.length ? arcPrompts[idx] : '';
      stageInstructions.add(custom.isNotEmpty
          ? custom
          : directed.isNotEmpty
              ? directed
              : arcDefault.isNotEmpty
                  ? arcDefault
                  : (st.transitionInstruction.isNotEmpty
                      ? st.transitionInstruction
                      : st.promptSuffix));
    }

    // Zedge rules (v81, from the user's 24h + battery rules PDFs):
    // the main subject stays centered in every stage so the artwork
    // scales across screen sizes. Appended to the anchor and to
    // every 24h/battery chain prompt below.
    final centeredClause = (workflowMode == 'set_24h' ||
            workflowMode == 'set_battery')
        ? kCenteredSubjectClause
        : '';
    // v82: Auto Cinematic Scene finish — the "better than the
    // rules" look, appended to the anchor and to every 24h/battery
    // chain prompt below.
    final cinematicClause = (workflowMode == 'set_24h' ||
            workflowMode == 'set_battery')
        ? kCinematicSceneSuffix
        : '';

    // v82: Auto Cinematic Scene — any prompt, even two words,
    // is expanded into one rich cinematic scene before the anchor
    // is made, so every stage starts from a beautiful scene. If
    // the expansion fails, the raw prompt is used and the set
    // still generates; a failed expansion never blocks a set.
    var scenePrompt = prompt.trim();
    if (workflowMode == 'set_24h' || workflowMode == 'set_battery') {
      try {
        _status('generating', 1,
            'Auto Cinematic Scene: turning your idea into a rich scene...');
        scenePrompt = await expandScenePrompt(prompt, workflowMode, session);
      } catch (_) {
        scenePrompt = prompt.trim();
      }
    }

    final totalStages = template.length;
    final safeSlug = slugify(prompt.isNotEmpty ? prompt : referenceFilename);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final baseSubfolder = subfolder.replaceAll(RegExp(r'^/+|/+$'), '');
    final setFolderName = '${safeSlug}_${workflowMode}_$timestamp';

    final anchorStage =
        template.firstWhere((s) => s.isAnchor, orElse: () => template.first);
    late Uint8List anchorBytes;
    late String anchorFilename;
    String? anchorHdUrl;
    final seenBaseUrls = <String>[];
    final resultsBySlot = <int, SetImage>{};

    Future<SetImage> savePrepared({
      required Uint8List sourceBytes,
      required StageDef stage,
      required String stagePromptText,
      required int stepNum,
      String? hdUrl,
      required String role,
    }) async {
      final prepared = await images.prepareImage(
        sourceBytes: sourceBytes,
        uploadFilename: '${safeSlug}_${stage.key}_HD.jpg',
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        label: stage.shortLabel,
        stepNum: stepNum,
        hdUrl: hdUrl,
        upscaleEnabled: upscaleEnabled,
      );
      final fileNameOnDisk =
          useExactZedgeNames ? stage.exactFilename : stage.zipName;
      final file = await _saveSetImage(
          baseSubfolder, setFolderName, fileNameOnDisk, prepared.bytes);
      return SetImage(
        localPath: file.path,
        exactFilename: stage.exactFilename,
        zipName: stage.zipName,
        distSlot: stage.distSlot,
        role: role,
        label: stage.shortLabel,
        badge: stage.badge,
        slotIndex: stage.slotIndex,
        stageKey: stage.key,
        stagePrompt: stagePromptText,
        hdUrl: prepared.hdUrl ?? hdUrl,
        upscaledViaCloudinary: prepared.upscaledViaCloudinary,
        width: prepared.width,
        height: prepared.height,
        byteSize: prepared.bytes.length,
      );
    }

    // STEP A: anchor — from the reference file, or generated fresh.
    if (referenceBytes != null) {
      anchorBytes = referenceBytes;
      anchorFilename = referenceFilename;
    } else {
      final directorAnchorExtra =
          directorPlan != null && directorPlan.anchorDirection.isNotEmpty
              ? ', ${directorPlan.anchorDirection}'
              : '';
      final anchorInstruction =
          stageInstructions[template.indexOf(anchorStage)];
      final negGuard = buildNegativeGuard(negativePrompt);
      final combinedAnchorPrompt =
          '$scenePrompt$directorAnchorExtra, $anchorInstruction$centeredClause$cinematicClause$styleSuffix$negGuard$kProFinishSuffix';
      final fullAnchorPrompt =
          buildImagePrompt(combinedAnchorPrompt, '9:16', forceImagePrefix);
      _status('generating', 1,
          '[1/$totalStages] Generating Anchor (${anchorStage.shortLabel}) via Gemini 9:16 RPC...');
      await _retryStage('Anchor', () async {
        final parsedAnchor = await gemini.callStreamGenerate(
            prompt: fullAnchorPrompt, session: session);
        if (parsedAnchor.urls.isEmpty) {
          throw Exception(parsedAnchor.assistantText.isNotEmpty
              ? 'Gemini replied with text instead of an image: "${parsedAnchor.assistantText.length > 180 ? parsedAnchor.assistantText.substring(0, 180) : parsedAnchor.assistantText}"'
              : 'No 9:16 anchor image URL was returned by Gemini StreamGenerate.');
        }
        seenBaseUrls.addAll(parsedAnchor.urls);
        final fetched =
            await gemini.fetchHdBlob(parsedAnchor.urls.first, session);
        anchorBytes = fetched.bytes;
        anchorFilename = '${safeSlug}_anchor.${fetched.ext}';
        anchorHdUrl = fetched.finalHdUrl;
        final anchorSaved = await savePrepared(
          sourceBytes: anchorBytes,
          stage: anchorStage,
          stagePromptText: combinedAnchorPrompt,
          stepNum: 1,
          hdUrl: anchorHdUrl,
          role: anchorStage.role,
        );
        resultsBySlot[anchorStage.slotIndex] = anchorSaved;
      });
    }

    // STEP B: upload the anchor once for img2img.
    final anchorMime = referenceBytes != null
        ? referenceMime
        : (anchorFilename.endsWith('.png')
            ? 'image/png'
            : anchorFilename.endsWith('.webp')
                ? 'image/webp'
                : 'image/jpeg');
    final uploadedAnchor = await _retryStage('Anchor upload',
        () => gemini.uploadImageForImg2Img(
              anchorBytes,
              anchorFilename,
              session,
              mimeType: anchorMime,
            ));

    // If the anchor came from a reference file, still produce its stage
    // output now (resize/upscale of the reference itself).
    if (referenceBytes != null &&
        !resultsBySlot.containsKey(anchorStage.slotIndex)) {
      final saved = await savePrepared(
        sourceBytes: anchorBytes,
        stage: anchorStage,
        stagePromptText: prompt,
        stepNum: 1,
        role: anchorStage.role,
      );
      resultsBySlot[anchorStage.slotIndex] = saved;
    }

    // STEP C: remaining stages via img2img from the anchor.
    var completedCount = resultsBySlot.length;
    for (var idx = 0; idx < template.length; idx++) {
      final stage = template[idx];
      if (resultsBySlot.containsKey(stage.slotIndex)) continue;
      completedCount++;
      final progressStep =
          ((completedCount / totalStages) * 4).ceil().clamp(2, 4);
      final hueAnchor = workflowMode == 'set_battery'
          ? ', keep the exact same glow and light hue as the reference image - the hue never changes, only the charge level changes'
          : '';
      // Charging is a unique version with a power motif, not just 100%
      // brightness (battery rules PDF).
      final chargeExtra =
          stage.key == 'charging' ? kChargingMotifClause : '';
      final negGuard = buildNegativeGuard(negativePrompt);
      final img2imgPrompt =
          '$scenePrompt, ${stageInstructions[idx]}, $chainStrength$centeredClause$cinematicClause$chargeExtra$styleSuffix$hueAnchor$negGuard$kProFinishSuffix (aspect ratio 9:16)';
      _status('img2img_generating', progressStep,
          '[$completedCount/$totalStages] Generating ${stage.shortLabel} via Gemini Image-to-Image RPC...');
      await _retryStage(stage.shortLabel, () async {
        var parsed = await gemini.callStreamGenerate(
          prompt: img2imgPrompt,
          session: session,
          attachment: uploadedAnchor,
          aspectRatioHint: '9:16',
          excludeUrls: seenBaseUrls,
        );
        if (parsed.urls.isEmpty) {
          parsed = await gemini.callStreamGenerate(
            prompt:
                'Generate an edited 9:16 vertical wallpaper version of this exact image: $img2imgPrompt',
            session: session,
            attachment: uploadedAnchor,
            aspectRatioHint: '9:16',
            excludeUrls: seenBaseUrls,
          );
        }
        if (parsed.urls.isEmpty) {
          throw Exception(parsed.assistantText.isNotEmpty
              ? 'Gemini replied with text on ${stage.shortLabel}: "${parsed.assistantText.length > 160 ? parsed.assistantText.substring(0, 160) : parsed.assistantText}"'
              : 'No image URL returned by Gemini for ${stage.shortLabel}.');
        }
        seenBaseUrls.addAll(parsed.urls);
        final fetched = await gemini.fetchHdBlob(parsed.urls.first, session);
        final saved = await savePrepared(
          sourceBytes: fetched.bytes,
          stage: stage,
          stagePromptText: img2imgPrompt,
          stepNum: progressStep,
          hdUrl: fetched.finalHdUrl,
          role: stage.role,
        );
        resultsBySlot[stage.slotIndex] = saved;
      });
    }

    final ordered = template
        .map((s) => resultsBySlot[s.slotIndex])
        .whereType<SetImage>()
        .toList();

    // Optional foldable companion.
    if (includeFoldableCompanion) {
      try {
        final negGuard = buildNegativeGuard(negativePrompt);
        final isSquare = (landscapeWidth - landscapeHeight).abs() <= 32;
        final ratioHint = isSquare ? '1:1' : '4:3';
        final foldPrompt =
            '${landscapePrompt.trim()}, foldable frame ${landscapeWidth}x$landscapeHeight$styleSuffix$negGuard$kProFinishSuffix';
        _status('img2img_generating', 4,
            '[+Foldable] Generating Foldable Companion (${landscapeWidth}x$landscapeHeight JPG) from Anchor...');
        final parsedFold = await gemini.callStreamGenerate(
          prompt: foldPrompt,
          session: session,
          attachment: uploadedAnchor,
          aspectRatioHint: ratioHint,
          excludeUrls: seenBaseUrls,
        );
        if (parsedFold.urls.isNotEmpty) {
          final fetchedFold =
              await gemini.fetchHdBlob(parsedFold.urls.first, session);
          final prepared = await images.prepareImage(
            sourceBytes: fetchedFold.bytes,
            uploadFilename: '${safeSlug}_foldable_HD.${fetchedFold.ext}',
            targetWidth: landscapeWidth,
            targetHeight: landscapeHeight,
            label: 'Foldable ($landscapeWidth x $landscapeHeight)',
            stepNum: 4,
            hdUrl: fetchedFold.finalHdUrl,
            upscaleEnabled: upscaleEnabled,
          );
          final foldExact = useExactZedgeNames
              ? 'WP_Foldable_${landscapeWidth}x$landscapeHeight.jpg'
              : 'wallpaper-landscape.jpg';
          final file = await _saveSetImage(
              baseSubfolder, setFolderName, foldExact, prepared.bytes);
          ordered.add(SetImage(
            localPath: file.path,
            exactFilename: foldExact,
            zipName: 'wallpaper-landscape.jpg',
            distSlot: 'wallpaper-landscape',
            role: 'landscape',
            label: 'Foldable (${landscapeWidth}x$landscapeHeight)',
            badge: 'Foldable (${landscapeWidth}x$landscapeHeight)',
            slotIndex: ordered.length + 1,
            stageKey: 'wallpaper-landscape',
            stagePrompt: foldPrompt,
            hdUrl: prepared.hdUrl ?? fetchedFold.finalHdUrl,
            upscaledViaCloudinary: prepared.upscaledViaCloudinary,
            width: prepared.width,
            height: prepared.height,
            byteSize: prepared.bytes.length,
          ));
        }
      } catch (_) {}
    }

    // STEP D: AI metadata.
    SetMetadata? generatedMeta;
    if (autoWriteMetadata && ordered.isNotEmpty) {
      try {
        _status('generating', 4,
            'Writing AI listing metadata (Title, Tags, Category, Description) via Gemini...');
        generatedMeta = await gemini.generateSetMetadata(
          workflowMode: workflowMode,
          prompt: prompt.isNotEmpty ? prompt : referenceFilename,
          file: 'set-01/${ordered.first.zipName}',
          session: session,
        );
      } catch (_) {
        generatedMeta = null;
      }
    }

    final entry = SetEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      prompt: prompt.isNotEmpty ? prompt : '[Reference Set] $referenceFilename',
      workflowMode: workflowMode,
      setTypeLabel: setTypeLabelFor(workflowMode),
      setFolderName: setFolderName,
      anchorHdUrl: anchorHdUrl,
      directorPlan: directorPlan,
      metadata: generatedMeta,
      createdAtIso: DateTime.now().toIso8601String(),
      images: ordered,
    );
    final history = await loadHistory();
    await saveHistory([entry, ...history]);
    _status('completed', 4,
        'Ready in Studio Showcase: ${entry.setTypeLabel}${generatedMeta != null ? ' + AI Metadata ("${generatedMeta.title}")' : ''}!');
    return entry;
  }

  /// Extension modes "dual" (9:16 + foldable) and "portrait_only",
  /// here named single / dual_single.
  Future<SetEntry> _generateSingleOrDualSingle({
    required String prompt,
    required bool withFoldable,
    required String negativePrompt,
    required String landscapePrompt,
    required String displayTarget,
    required String colorBoost,
    required bool autoWriteMetadata,
    required bool forceImagePrefix,
    required bool upscaleEnabled,
    required String subfolder,
    required int portraitWidth,
    required int portraitHeight,
    required int landscapeWidth,
    required int landscapeHeight,
  }) async {
    final session = await gemini.getSession();
    final safeSlug =
        slugify(prompt.isNotEmpty ? prompt : 'gemini_wallpaper', maxLen: 36);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final baseSubfolder = subfolder.replaceAll(RegExp(r'^/+|/+$'), '');
    final setFolderName =
        '${safeSlug}_${withFoldable ? 'dual' : 'single'}_$timestamp';
    final styleSuffix = buildStyleSuffix(displayTarget, colorBoost);
    final negGuard = buildNegativeGuard(negativePrompt);
    final outputs = <SetImage>[];

    final styledBase = '${prompt.trim()}$styleSuffix$negGuard$kProFinishSuffix';
    final portraitPrompt =
        buildImagePrompt(styledBase, '9:16', forceImagePrefix);
    _status('generating', 1,
        'Step 1/4: Generating 9:16 Portrait image via Gemini RPC...');
    late StreamGenerateResult parsedPortrait;
    late HdFetchResult fetchedPortrait;
    await _retryStage('9:16 Portrait', () async {
      parsedPortrait = await gemini.callStreamGenerate(
          prompt: portraitPrompt, session: session);
      if (parsedPortrait.urls.isEmpty) {
        throw Exception(parsedPortrait.assistantText.isNotEmpty
            ? 'Gemini replied with text instead of an image: "${parsedPortrait.assistantText.length > 180 ? parsedPortrait.assistantText.substring(0, 180) : parsedPortrait.assistantText}"'
            : 'No 9:16 image URL was returned by Gemini StreamGenerate.');
      }
      _status('downloading', 2,
          'Step 2/4: Fetching Gemini 9:16 (full size) & running Cloudinary AI Upscale...');
      fetchedPortrait =
          await gemini.fetchHdBlob(parsedPortrait.urls.first, session);
      final preparedPortrait = await images.prepareImage(
        sourceBytes: fetchedPortrait.bytes,
        uploadFilename: '${safeSlug}_${timestamp}_1_HD.${fetchedPortrait.ext}',
        targetWidth: portraitWidth,
        targetHeight: portraitHeight,
        label: '9:16 Portrait ($portraitWidth x $portraitHeight)',
        stepNum: 2,
        hdUrl: fetchedPortrait.finalHdUrl,
        upscaleEnabled: upscaleEnabled,
      );
      final portraitFile = await _saveSetImage(
          baseSubfolder, setFolderName, 'wallpaper.jpg', preparedPortrait.bytes);
      outputs.add(SetImage(
        localPath: portraitFile.path,
        exactFilename: 'wallpaper.jpg',
        zipName: 'wallpaper.jpg',
        distSlot: 'wallpaper',
        role: 'portrait',
        label: '9:16 Portrait ($portraitWidth x $portraitHeight)',
        badge: '9:16 Portrait',
        slotIndex: 1,
        stageKey: 'wallpaper',
        stagePrompt: portraitPrompt,
        hdUrl: preparedPortrait.hdUrl ?? fetchedPortrait.finalHdUrl,
        upscaledViaCloudinary: preparedPortrait.upscaledViaCloudinary,
        width: preparedPortrait.width,
        height: preparedPortrait.height,
        byteSize: preparedPortrait.bytes.length,
      ));
    });

    if (withFoldable) {
      await _retryStage('Foldable version', () async {
        final uploaded = await gemini.uploadImageForImg2Img(
          fetchedPortrait.bytes,
          '${safeSlug}_${timestamp}_1_HD.${fetchedPortrait.ext}',
          session,
          mimeType: fetchedPortrait.mimeType,
          stepNum: 3,
        );
        final baseFold = landscapePrompt.trim().isEmpty
            ? kFoldableAdaptationPrompt
            : landscapePrompt.trim();
        final img2imgPrompt = '$baseFold$styleSuffix$negGuard';
        _status('img2img_generating', 3,
            'Step 3/4: Running Gemini Image-to-Image RPC for the foldable version...');
        var parsedLand = await gemini.callStreamGenerate(
          prompt: img2imgPrompt,
          session: session,
          attachment: uploaded,
          aspectRatioHint: '4:3',
          excludeUrls: parsedPortrait.urls,
        );
        if (parsedLand.urls.isEmpty) {
          final directPrompt =
              'Generate a wide landscape version of this artwork: $img2imgPrompt (aspect ratio 4:3)';
          parsedLand = await gemini.callStreamGenerate(
              prompt: buildImagePrompt(directPrompt, '4:3', false),
              session: session);
        }
        if (parsedLand.urls.isEmpty) {
          throw Exception(parsedLand.assistantText.isNotEmpty
              ? 'Gemini Image-to-Image replied with text: "${parsedLand.assistantText.length > 160 ? parsedLand.assistantText.substring(0, 160) : parsedLand.assistantText}"'
              : 'No Landscape image URL returned by Gemini Image-to-Image RPC.');
        }
        final fetchedLand =
            await gemini.fetchHdBlob(parsedLand.urls.first, session);
        final preparedLand = await images.prepareImage(
          sourceBytes: fetchedLand.bytes,
          uploadFilename: '${safeSlug}_${timestamp}_2_HD.${fetchedLand.ext}',
          targetWidth: landscapeWidth,
          targetHeight: landscapeHeight,
          label: 'Foldable $landscapeWidth x $landscapeHeight',
          stepNum: 3,
          hdUrl: fetchedLand.finalHdUrl,
          upscaleEnabled: upscaleEnabled,
        );
        final landFile = await _saveSetImage(baseSubfolder, setFolderName,
            'wallpaper-landscape.jpg', preparedLand.bytes);
        outputs.add(SetImage(
          localPath: landFile.path,
          exactFilename: 'wallpaper-landscape.jpg',
          zipName: 'wallpaper-landscape.jpg',
          distSlot: 'wallpaper-landscape',
          role: 'landscape',
          label: 'Foldable ($landscapeWidth x $landscapeHeight)',
          badge: 'Foldable',
          slotIndex: 2,
          stageKey: 'wallpaper-landscape',
          stagePrompt: img2imgPrompt,
          hdUrl: preparedLand.hdUrl ?? fetchedLand.finalHdUrl,
          upscaledViaCloudinary: preparedLand.upscaledViaCloudinary,
          width: preparedLand.width,
          height: preparedLand.height,
          byteSize: preparedLand.bytes.length,
        ));
      });
    }

    SetMetadata? generatedMeta;
    if (autoWriteMetadata) {
      try {
        _status('generating', 4,
            'Writing AI listing metadata (Title, Tags, Category, Description) via Gemini...');
        generatedMeta = await gemini.generateSetMetadata(
          workflowMode: 'single',
          prompt: prompt,
          file: 'set-01/wallpaper.jpg',
          session: session,
        );
      } catch (_) {
        generatedMeta = null;
      }
    }

    final entry = SetEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      prompt: prompt,
      workflowMode: withFoldable ? 'dual_single' : 'single',
      setTypeLabel: withFoldable
          ? '9:16 + Foldable (2 JPGs)'
          : 'Single Wallpaper (1 JPG)',
      setFolderName: setFolderName,
      anchorHdUrl: fetchedPortrait.finalHdUrl,
      metadata: generatedMeta,
      createdAtIso: DateTime.now().toIso8601String(),
      images: outputs,
    );
    final history = await loadHistory();
    await saveHistory([entry, ...history]);
    _status('completed', 4,
        'Ready in Studio Showcase: ${entry.setTypeLabel}${generatedMeta != null ? ' + Metadata ("${generatedMeta.title}")' : ''}!');
    return entry;
  }

  /// Extension: importLocalSetToStudio.
  Future<SetEntry> importLocalSet({
    required List<({Uint8List bytes, String filename})> files,
    required String workflowMode,
    String prompt = '',
    bool upscaleEnabled = false,
    bool autoWriteMetadata = true,
    String subfolder = 'Gemini_HD',
    int portraitWidth = kPortraitWidth,
    int portraitHeight = kPortraitHeight,
  }) async {
    if (files.isEmpty) {
      throw Exception(
          'Please select at least 1 image file to import into the Studio Panel.');
    }
    final template = stagesForMode(workflowMode);
    if (files.length < template.length) {
      _status('importing', 1,
          'Note: ${files.length} file(s) for a ${template.length}-stage set — extra stages will be skipped.');
    }
    final dims = normalizeZedgeDimensions(portraitWidth, portraitHeight);
    final baseSubfolder = subfolder.replaceAll(RegExp(r'^/+|/+$'), '');
    final safeSlug = slugify(prompt.isNotEmpty ? prompt : 'imported_set');
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final setFolderName = '${safeSlug}_import_$timestamp';
    final outputs = <SetImage>[];

    final count =
        files.length <= template.length ? files.length : template.length;
    for (var i = 0; i < count; i++) {
      final stage = template[i];
      _status('importing', 2,
          'Importing [${i + 1}/$count] ${files[i].filename} as ${stage.shortLabel}...');
      final prepared = await images.prepareImage(
        sourceBytes: files[i].bytes,
        uploadFilename: files[i].filename,
        targetWidth: dims.width,
        targetHeight: dims.height,
        label: stage.shortLabel,
        stepNum: 2,
        upscaleEnabled: upscaleEnabled,
      );
      final file = await _saveSetImage(
          baseSubfolder, setFolderName, stage.exactFilename, prepared.bytes);
      outputs.add(SetImage(
        localPath: file.path,
        exactFilename: stage.exactFilename,
        zipName: stage.zipName,
        distSlot: stage.distSlot,
        role: stage.role,
        label: stage.shortLabel,
        badge: stage.badge,
        slotIndex: stage.slotIndex,
        stageKey: stage.key,
        stagePrompt: prompt,
        hdUrl: prepared.hdUrl,
        upscaledViaCloudinary: prepared.upscaledViaCloudinary,
        width: prepared.width,
        height: prepared.height,
        byteSize: prepared.bytes.length,
      ));
    }

    SetMetadata? generatedMeta;
    if (autoWriteMetadata && prompt.trim().isNotEmpty) {
      try {
        _status('generating', 4, 'Writing AI listing metadata via Gemini...');
        final session = await gemini.getSession();
        generatedMeta = await gemini.generateSetMetadata(
          workflowMode: workflowMode,
          prompt: prompt,
          file: 'set-01/${outputs.first.zipName}',
          session: session,
        );
      } catch (_) {
        generatedMeta = null;
      }
    }

    final entry = SetEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      prompt: prompt.isNotEmpty ? prompt : '[Imported Set]',
      workflowMode: workflowMode,
      setTypeLabel: setTypeLabelFor(workflowMode),
      setFolderName: setFolderName,
      metadata: generatedMeta,
      createdAtIso: DateTime.now().toIso8601String(),
      images: outputs,
    );
    final history = await loadHistory();
    await saveHistory([entry, ...history]);
    _status('completed', 4,
        'Imported ${outputs.length} image(s) into Studio Showcase${generatedMeta != null ? ' + AI Metadata ("${generatedMeta.title}")' : ''}!');
    return entry;
  }

  /// Extension: generateOrUpdateHistoryMetadata.
  Future<SetMetadata> generateMetadataForEntry(SetEntry entry) async {
    final session = await gemini.getSession();
    final firstZip =
        'set-01/${entry.images.isNotEmpty ? entry.images.first.zipName : 'wallpaper.jpg'}';
    final meta = await gemini.generateSetMetadata(
      workflowMode: entry.workflowMode,
      prompt: entry.prompt,
      file: firstZip,
      session: session,
    );
    entry.metadata = meta;
    final history = await loadHistory();
    final idx = history.indexWhere((h) => h.id == entry.id);
    if (idx >= 0) history[idx] = entry;
    await saveHistory(history);
    _status('completed', 4,
        'AI Metadata generated: "${meta.title}" [${meta.category}] (${meta.tags.length} tags)!');
    return meta;
  }

  /// v79: the local anchor file for a set — the first image on
  /// disk. Null when the set has no images or the file is gone.
  static Future<Uint8List?> readLocalAnchorBytes(SetEntry entry) async {
    if (entry.images.isEmpty) return null;
    final local = File(entry.images.first.localPath);
    if (!await local.exists()) return null;
    return local.readAsBytes();
  }

  /// Extension: regenerateSingleSetStage.
  Future<SetEntry> regenerateStage(SetEntry entry, SetImage oldImg) async {
    await ForegroundKeepAlive.acquire('Regenerating in the background');
    try {
      return await _regenerateStageImpl(entry, oldImg);
    } finally {
      await ForegroundKeepAlive.release();
    }
  }

  Future<SetEntry> _regenerateStageImpl(SetEntry entry, SetImage oldImg) async {
    final session = await gemini.getSession();
    final template = stagesForMode(entry.workflowMode);
    final stage = template.firstWhere(
      (s) => s.key == oldImg.stageKey,
      orElse: () => template.first,
    );
    Uint8List anchorBytes;
    // v79: the anchor image already lives on disk — it IS the set's
    // first image (resultsBySlot order, generateSet STEP A). The old
    // code re-downloaded it from the stored anchorHdUrl every time,
    // but Gemini's signed CDN URLs expire: regenerating an older
    // set 403d on EVERY candidate form (his 2026-11-14 screenshot —
    // as-issued, =d-I, =s2048-rj, =s1024-rj, bare, =s0, plus all
    // no-cookie retries). Prefer the local file; the stored URL is
    // only a fallback for sets whose files are gone.
    final localAnchorBytes = await readLocalAnchorBytes(entry);
    if (localAnchorBytes != null) {
      anchorBytes = localAnchorBytes;
    } else if (entry.anchorHdUrl != null && entry.anchorHdUrl!.isNotEmpty) {
      final fetched = await gemini.fetchHdBlob(entry.anchorHdUrl!, session);
      anchorBytes = fetched.bytes;
    } else {
      throw Exception(
          'Regenerate kora jabe na — set-er prothom chhobi-ta phone-e khuje pawa jay ni (file muche geche ba sorano hoyeche).');
    }
    final uploaded =
        await gemini.uploadImageForImg2Img(anchorBytes, 'anchor.jpg', session);
    final promptText = oldImg.stagePrompt.isNotEmpty
        ? oldImg.stagePrompt
        : '${entry.prompt}, ${stage.transitionInstruction.isNotEmpty ? stage.transitionInstruction : stage.promptSuffix}';
    var parsed = await gemini.callStreamGenerate(
      prompt: promptText,
      session: session,
      attachment: uploaded,
      aspectRatioHint: '9:16',
    );
    if (parsed.urls.isEmpty) {
      parsed = await gemini.callStreamGenerate(
        prompt:
            'Generate an edited 9:16 vertical wallpaper version of this exact image: $promptText',
        session: session,
        attachment: uploaded,
        aspectRatioHint: '9:16',
      );
    }
    if (parsed.urls.isEmpty) {
      throw Exception(
          'Gemini did not return an image while regenerating ${oldImg.label}.');
    }
    final fetched = await gemini.fetchHdBlob(parsed.urls.first, session);
    final prepared = await images.prepareImage(
      sourceBytes: fetched.bytes,
      uploadFilename: 'regenerated_${stage.key}.jpg',
      targetWidth: oldImg.width == 0 ? kPortraitWidth : oldImg.width,
      targetHeight: oldImg.height == 0 ? kPortraitHeight : oldImg.height,
      label: oldImg.label,
      stepNum: 3,
      hdUrl: fetched.finalHdUrl,
      upscaleEnabled: true,
    );
    final file = File(oldImg.localPath);
    await file.writeAsBytes(prepared.bytes, flush: true);
    oldImg
      ..hdUrl = prepared.hdUrl ?? fetched.finalHdUrl
      ..upscaledViaCloudinary = prepared.upscaledViaCloudinary
      ..width = prepared.width
      ..height = prepared.height
      ..byteSize = prepared.bytes.length;
    final history = await loadHistory();
    final idx = history.indexWhere((h) => h.id == entry.id);
    if (idx >= 0) history[idx] = entry;
    await saveHistory(history);
    _status('completed', 4,
        'Regenerated ${oldImg.label} (${prepared.width}x${prepared.height} JPG) in Studio Showcase!');
    return entry;
  }

  // -------------------------------------------------------------------
  // Ready ZIP (extension: downloadReadySetsZip / downloadStandaloneMetadataJson)
  // -------------------------------------------------------------------

  List<Map<String, dynamic>> metadataArrayFor(List<SetEntry> entries,
      {bool useHubSetFolders = true}) {
    final out = <Map<String, dynamic>>[];
    for (var sIdx = 0; sIdx < entries.length; sIdx++) {
      final entry = entries[sIdx];
      final setNum = (sIdx + 1).toString().padLeft(2, '0');
      final first = entry.images.isNotEmpty ? entry.images.first : null;
      final firstName = first == null
          ? 'image.jpg'
          : (useHubSetFolders ? first.zipName : first.exactFilename);
      final firstPath = (useHubSetFolders || entries.length > 1)
          ? 'set-$setNum/$firstName'
          : firstName;
      final m = entry.metadata;
      out.add({
        'file': m?.file.isNotEmpty == true ? m!.file : firstPath,
        'title': m?.title ?? '',
        'tags': m?.tags ?? <String>[],
        'keywords': (m?.tags ?? <String>[]).join(', '),
        'category': m?.category ?? '',
        'description': m?.description ?? '',
      });
    }
    return out;
  }

  Future<File> buildReadyZip(
    List<SetEntry> entries, {
    bool useHubSetFolders = true,
    String? zipFilename,
  }) async {
    if (entries.isEmpty) {
      throw Exception('No sets available to package into Ready ZIP.');
    }
    final archive = Archive();
    for (var sIdx = 0; sIdx < entries.length; sIdx++) {
      final entry = entries[sIdx];
      final setNum = (sIdx + 1).toString().padLeft(2, '0');
      final setFolder = 'set-$setNum';
      for (var i = 0; i < entry.images.length; i++) {
        final img = entry.images[i];
        _status('downloading', 4,
            'Packing Ready ZIP [Set ${sIdx + 1}/${entries.length} - File ${i + 1}/${entry.images.length}]: ${img.exactFilename}...');
        final f = File(img.localPath);
        if (!await f.exists()) {
          throw Exception('Image file missing on device: ${img.exactFilename}');
        }
        final bytes = await f.readAsBytes();
        final entryPath = useHubSetFolders
            ? '$setFolder/${img.zipName}'
            : (entries.length > 1
                ? '$setFolder/${img.exactFilename}'
                : img.exactFilename);
        archive.addFile(ArchiveFile(entryPath, bytes.length, bytes));
      }
      final promptLines = <String>[
        'Set #$setNum (${entry.setTypeLabel})',
        'Core Prompt: ${entry.prompt}',
        '',
      ];
      for (var idx = 0; idx < entry.images.length; idx++) {
        final img = entry.images[idx];
        promptLines.add('[${idx + 1}] ${img.exactFilename}:');
        promptLines
            .add(img.stagePrompt.isNotEmpty ? img.stagePrompt : entry.prompt);
        promptLines.add('');
      }
      final promptBytes = utf8.encode(promptLines.join('\n'));
      archive.addFile(ArchiveFile('prompts/set-$setNum-wallpaper.txt',
          promptBytes.length, promptBytes));
    }
    final metadataJson = const JsonEncoder.withIndent('  ')
        .convert(metadataArrayFor(entries, useHubSetFolders: useHubSetFolders));
    final metaBytes = utf8.encode(metadataJson);
    archive.addFile(ArchiveFile('metadata.json', metaBytes.length, metaBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) throw Exception('ZIP encoding failed.');
    final docs = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(docs.path, 'GeminiHDStudio', 'Exports'));
    await outDir.create(recursive: true);
    final name = zipFilename ??
        (entries.length == 1
            ? 'ready-${entries.first.setFolderName}.zip'
            : 'ai-studio-sets-${DateTime.now().millisecondsSinceEpoch}.zip');
    final outFile =
        File(p.join(outDir.path, name.replaceAll(RegExp(r'^/+'), '')));
    await outFile.writeAsBytes(zipBytes, flush: true);
    _status('completed', 4,
        'Ready ZIP saved: ${outFile.path} (${entries.length} set(s) + metadata.json)');
    return outFile;
  }

  Future<File> buildStandaloneMetadataJson(List<SetEntry> entries) async {
    final metadataJson =
        const JsonEncoder.withIndent('  ').convert(metadataArrayFor(entries));
    final docs = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(docs.path, 'GeminiHDStudio', 'Exports'));
    await outDir.create(recursive: true);
    final outFile = File(p.join(outDir.path, 'metadata.json'));
    await outFile.writeAsString(metadataJson, flush: true);
    _status('completed', 4,
        'Downloaded metadata.json (${entries.length} set record(s))!');
    return outFile;
  }

  // -------------------------------------------------------------------
  // Panel upload (extension: distribute / uploadSetToPanel)
  // -------------------------------------------------------------------

  String _normalizeUrl(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  String r2FolderForAccountName(String name) {
    var f = name.replaceAll(RegExp(r'^zedge_?', caseSensitive: false), 'zedge');
    f = f.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return f.isEmpty ? 'studio' : f;
  }

  String resolveDistSlot(String workflowMode, SetImage img, int index) {
    if (img.distSlot.isNotEmpty) return img.distSlot;
    final label = (img.label + img.stageKey + img.exactFilename).toLowerCase();
    if (workflowMode == 'set_battery') {
      const slots = ['critical', 'low', 'mid', 'high', 'full', 'charging'];
      for (final s in slots) {
        if (label.contains(s)) return s;
      }
      return index < slots.length ? slots[index] : 'frame${index + 1}';
    }
    if (workflowMode == 'set_24h') {
      for (final s in ['morning', 'afternoon', 'evening', 'night']) {
        if (label.contains(s)) return s;
      }
      const order = ['morning', 'afternoon', 'evening', 'night'];
      return index < order.length ? order[index] : 'frame${index + 1}';
    }
    if (workflowMode == 'set_dual') {
      if (label.contains('lock')) return 'lock';
      if (label.contains('home')) return 'home';
      return index == 0 ? 'lock' : 'home';
    }
    if (label.contains('landscape')) return 'wallpaper-landscape';
    return index == 0 ? 'wallpaper' : 'frame${index + 1}';
  }

  String resolveDistContentType(String workflowMode) {
    switch (workflowMode) {
      case 'set_24h':
        return 'WALLPAPER_24H';
      case 'set_dual':
        return 'WALLPAPER_DUAL';
      case 'set_battery':
        return 'WALLPAPER_BATTERY';
      case 'animation':
        return 'LIVE_WALLPAPER';
      default:
        return 'WALLPAPER';
    }
  }

  Future<String> _uploadFileToR2Worker({
    required Uint8List bytes,
    required String fileName,
    required String workerUrl,
    required String folder,
    String fileType = 'image/jpeg',
  }) async {
    final cleaned = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final cleanFolder = folder.replaceAll(RegExp(r'^/+|/+$'), '');
    final key =
        '$cleanFolder/wallpaper/${DateTime.now().millisecondsSinceEpoch}_$cleaned';
    final resp = await _client.post(
      Uri.parse(_normalizeUrl(workerUrl)),
      headers: {'X-File-Name': key, 'X-File-Type': fileType},
      body: bytes,
    );
    if (resp.statusCode != 200) {
      throw Exception(
          'R2 upload failed (HTTP ${resp.statusCode}): ${resp.body.length > 180 ? resp.body.substring(0, 180) : resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = data['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw Exception('R2 worker response missing the url field.');
    }
    final folderSeg = '/$cleanFolder/wallpaper/';
    if (!url.contains(folderSeg)) {
      throw Exception(
          'R2 returned a URL outside $cleanFolder/wallpaper ($url).');
    }
    return url;
  }

  Future<String> _pushRecordToFirebase({
    required String dbUrl,
    required String queuePath,
    required Map<String, dynamic> record,
    required String secret,
  }) async {
    final authQuery = secret.trim().isNotEmpty
        ? '?auth=${Uri.encodeComponent(secret.trim())}'
        : '';
    final url =
        '${_normalizeUrl(dbUrl)}/${queuePath.trim().isEmpty ? 'wallpaperQueue' : queuePath.trim()}.json$authQuery';
    final resp = await _client.post(Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(record));
    if (resp.statusCode != 200) {
      throw Exception(
          'Database push failed (HTTP ${resp.statusCode}): ${resp.body.length > 180 ? resp.body.substring(0, 180) : resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final key = data['name']?.toString() ?? '';
    if (key.isEmpty) throw Exception('Database push returned no Firebase key.');
    return key;
  }

  Future<String> testPanelDatabase(
      {required String dbUrl, required String secret}) async {
    final authParam = secret.trim().isNotEmpty
        ? '&auth=${Uri.encodeComponent(secret.trim())}'
        : '';
    final url = '${_normalizeUrl(dbUrl)}/.json?shallow=true$authParam';
    final resp = await _client.get(Uri.parse(url));
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw Exception(
          'Database refused access (HTTP ${resp.statusCode}). Check URL and secret.');
    }
    if (resp.statusCode != 200) {
      throw Exception('Database test failed (HTTP ${resp.statusCode}).');
    }
    return 'Database reachable (read-only shallow test passed).';
  }

  /// v87 — shared by the image-set and animation-video panel
  /// uploads: picks the target account ('spread' rotates through
  /// the accounts, a named target is used as-is). Callers check
  /// that at least one account is configured first.
  Future<DistAccount> _pickDistAccount(
      DistConfig distConfig, String targetAccount) async {
    if (distConfig.accounts.isEmpty) {
      throw Exception(
          "Panel Distribution is not configured yet. Open 'Panel Upload Settings' to add your R2 Worker URL and Firebase Database account(s).");
    }
    final prefs = await SharedPreferences.getInstance();
    var spreadCursor = prefs.getInt(_kDistCursor) ?? 0;
    DistAccount? account;
    final effectiveTarget =
        targetAccount.isEmpty ? distConfig.defaultTarget : targetAccount;
    if (effectiveTarget != 'spread') {
      for (final a in distConfig.accounts) {
        if (a.name == effectiveTarget) account = a;
      }
    }
    account ??= distConfig.accounts[spreadCursor % distConfig.accounts.length];
    if (effectiveTarget == 'spread') {
      await prefs.setInt(_kDistCursor, spreadCursor + 1);
    }
    return account;
  }

  /// v87 — URL-safe slug from an AI title (or the prompt's first
  /// phrase when there is no title yet), max 32 chars.
  static String slugFromTitleOrPrompt(String? title, String prompt) {
    var baseSlug = (title?.isNotEmpty == true
            ? title!
            : prompt.split(RegExp(r'[,.]')).first)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (baseSlug.length > 32) baseSlug = baseSlug.substring(0, 32);
    if (baseSlug.isEmpty) baseSlug = 'set';
    return baseSlug;
  }

  Future<({String accountName, String firebaseKey})> uploadSetToPanel(
    SetEntry entry, {
    String targetAccount = 'spread',
  }) async {
    final distConfig = await loadDistConfig();
    if (distConfig.r2WorkerUrl.isEmpty || distConfig.accounts.isEmpty) {
      throw Exception(
          "Panel Distribution is not configured yet. Open 'Panel Upload Settings' to add your R2 Worker URL and Firebase Database account(s).");
    }
    if (entry.images.isEmpty) {
      throw Exception('Set has no images to upload.');
    }

    final acc = await _pickDistAccount(distConfig, targetAccount);

    if (entry.metadata == null || entry.metadata!.title.isEmpty) {
      try {
        _status('generating', 3,
            'Generating AI Metadata before uploading to ${acc.name}...');
        await generateMetadataForEntry(entry);
      } catch (_) {}
    }

    final r2Folder = r2FolderForAccountName(acc.name);
    final meta = entry.metadata;
    final baseSlug = slugFromTitleOrPrompt(meta?.title, entry.prompt);

    final filesMap = <String, dynamic>{};
    var totalSize = 0;
    var firstUrl = '';
    var firstName = '';
    var firstSize = 0;
    var firstW = kPortraitWidth;
    var firstH = kPortraitHeight;

    for (var i = 0; i < entry.images.length; i++) {
      final img = entry.images[i];
      final slot = resolveDistSlot(entry.workflowMode, img, i);
      final fileName = '${baseSlug}_$slot.jpg';
      _status('downloading', 3,
          'Uploading to Panel (${acc.name}) [${i + 1}/${entry.images.length}]: $fileName -> R2 ($r2Folder)...');
      final f = File(img.localPath);
      if (!await f.exists()) {
        throw Exception('Image file missing on device: ${img.exactFilename}');
      }
      final bytes = await f.readAsBytes();
      final fileSha = sha256.convert(bytes).toString();
      final r2Url = await _uploadFileToR2Worker(
        bytes: bytes,
        fileName: fileName,
        workerUrl: distConfig.r2WorkerUrl,
        folder: r2Folder,
      );
      filesMap[slot] = {
        'fileUrl': r2Url,
        'name': fileName,
        'size': bytes.length,
        'type': 'image/jpeg',
        'width': img.width,
        'height': img.height,
        'sha256': fileSha,
      };
      totalSize += bytes.length;
      if (i == 0) {
        firstUrl = r2Url;
        firstName = fileName;
        firstSize = bytes.length;
        firstW = img.width;
        firstH = img.height;
      }
    }

    _status('downloading', 4,
        'Pushing set record + metadata to ${acc.name} Firebase Queue (${distConfig.queuePath})...');
    final now = DateTime.now().millisecondsSinceEpoch;
    final isSingle = entry.images.length == 1;
    final record = <String, dynamic>{
      'name': firstName,
      'type': 'image/jpeg',
      'size': isSingle ? firstSize : totalSize,
      'width': firstW,
      'height': firstH,
      'isMp3': false,
      'isImage': true,
      'contentType': resolveDistContentType(entry.workflowMode),
      'fileUrl': firstUrl,
      'status': 'queued',
      'prompt': entry.prompt,
      'imageModel': 'gemini-hd-studio',
      'source': 'ai-image-studio-flutter',
      'createdAt': now,
    };
    if (!isSingle) {
      record['files'] = filesMap;
      record['setName'] =
          meta?.title.isNotEmpty == true ? meta!.title : baseSlug;
    }
    if (meta != null &&
        (meta.title.isNotEmpty ||
            meta.tags.isNotEmpty ||
            meta.category.isNotEmpty ||
            meta.description.isNotEmpty)) {
      record['title'] = meta.title;
      record['tags'] = meta.tags.join(', ');
      record['tagsList'] = meta.tags;
      record['category'] = meta.category.isEmpty ? 'DESIGNS' : meta.category;
      record['description'] = meta.description;
      record['metadataGeneratedAt'] = now;
      record['policyCheck'] = 'passed';
      record['policyCheckedAt'] = now;
    }

    final dbSecret = acc.secret;
    final firebaseKey = await _pushRecordToFirebase(
      dbUrl: acc.dbUrl,
      queuePath: distConfig.queuePath,
      record: record,
      secret: dbSecret,
    );
    entry.uploadedToPanel = {
      'accountName': acc.name,
      'firebaseKey': firebaseKey,
      'uploadedAt': now,
    };
    final history = await loadHistory();
    final idx = history.indexWhere((h) => h.id == entry.id);
    if (idx >= 0) history[idx] = entry;
    await saveHistory(history);
    _status('completed', 4,
        'Uploaded set "${meta?.title.isNotEmpty == true ? meta!.title : baseSlug}" to ${acc.name} Panel! Queue Key: $firebaseKey');
    return (accountName: acc.name, firebaseKey: firebaseKey);
  }

  // v87 — Animation video metadata + panel upload.
  // ---------------------------------------------------------------
  // Mirrors the image-set flow (generateSetMetadata /
  // uploadSetToPanel) so one video gets the same listing metadata
  // and the same R2 + Firebase queue record. The MP4 goes to the
  // same proven R2 folder as the wallpapers (the worker path is
  // unchanged); the queue record carries isVideo + type video/mp4
  // + contentType LIVE_WALLPAPER so the panel can tell it apart
  // from a JPG set. Whether the panel UI lists video entries is
  // the panel's side — the record is what the app can send.

  /// AI listing metadata for one finished video, from the user's
  /// own Gemini session (same session the image metadata uses).
  Future<SetMetadata> generateVideoMetadata(AnimationVideo video) async {
    final session = await gemini.getSession();
    return gemini.generateVideoMetadata(
      prompt: video.prompt,
      file: video.fileName,
      session: session,
    );
  }

  /// The Firebase queue record for one video — pure, so the unit
  /// tests cover the panel contract without network.
  static Map<String, dynamic> buildVideoPanelRecord({
    required AnimationVideo video,
    required String fileUrl,
    required String fileName,
    required int fileSize,
    required String fileSha,
    SetMetadata? meta,
    required int now,
  }) {
    final record = <String, dynamic>{
      'name': fileName,
      'type': 'video/mp4',
      'size': fileSize,
      'width': video.width,
      'height': video.height,
      'durationSec': video.durationSec,
      'fps': video.fps,
      'isMp3': false,
      'isImage': false,
      'isVideo': true,
      'contentType': 'LIVE_WALLPAPER',
      'fileUrl': fileUrl,
      'status': 'queued',
      'prompt': video.prompt,
      'imageModel': 'gemini-hd-studio',
      'videoModel': 'gemini-neon',
      'source': 'ai-image-studio-flutter',
      'sha256': fileSha,
      'createdAt': now,
    };
    if (meta != null &&
        (meta.title.isNotEmpty ||
            meta.tags.isNotEmpty ||
            meta.category.isNotEmpty ||
            meta.description.isNotEmpty)) {
      record['title'] = meta.title;
      record['tags'] = meta.tags.join(', ');
      record['tagsList'] = meta.tags;
      record['category'] = meta.category.isEmpty ? 'DESIGNS' : meta.category;
      record['description'] = meta.description;
      record['metadataGeneratedAt'] = now;
      record['policyCheck'] = 'passed';
      record['policyCheckedAt'] = now;
    }
    return record;
  }

  /// Uploads one finished animation video to the panel (R2 file +
  /// Firebase queue record). Returns the account + queue key and
  /// the metadata that was used (generated on the fly when the
  /// video had none yet — the caller stores it on the video).
  Future<
      ({
        String accountName,
        String firebaseKey,
        SetMetadata? metadata,
      })> uploadVideoToPanel(
    AnimationVideo video, {
    String targetAccount = 'spread',
  }) async {
    final distConfig = await loadDistConfig();
    if (distConfig.r2WorkerUrl.isEmpty || distConfig.accounts.isEmpty) {
      throw Exception(
          "Panel Distribution is not configured yet. Open 'Panel Upload Settings' to add your R2 Worker URL and Firebase Database account(s).");
    }
    final file = File(video.localPath);
    if (!await file.exists()) {
      throw Exception('Video file missing on device: ${video.fileName}');
    }
    final acc = await _pickDistAccount(distConfig, targetAccount);

    var meta = video.metadata;
    if (meta == null || meta.title.isEmpty) {
      try {
        _status('generating', 3,
            'Generating AI Metadata before uploading to ${acc.name}...');
        meta = await generateVideoMetadata(video);
      } catch (_) {}
    }

    final r2Folder = r2FolderForAccountName(acc.name);
    final baseSlug = slugFromTitleOrPrompt(meta?.title, video.prompt);
    final fileName = '$baseSlug.mp4';
    _status('uploading', 3,
        'Uploading to Panel (${acc.name}): $fileName -> R2 ($r2Folder)...');
    final bytes = await file.readAsBytes();
    final fileSha = sha256.convert(bytes).toString();
    final r2Url = await _uploadFileToR2Worker(
      bytes: bytes,
      fileName: fileName,
      workerUrl: distConfig.r2WorkerUrl,
      folder: r2Folder,
      fileType: 'video/mp4',
    );

    _status('downloading', 4,
        'Pushing video record + metadata to ${acc.name} Firebase Queue (${distConfig.queuePath})...');
    final now = DateTime.now().millisecondsSinceEpoch;
    final record = buildVideoPanelRecord(
      video: video,
      fileUrl: r2Url,
      fileName: fileName,
      fileSize: bytes.length,
      fileSha: fileSha,
      meta: meta,
      now: now,
    );
    final dbSecret = acc.secret;
    final firebaseKey = await _pushRecordToFirebase(
      dbUrl: acc.dbUrl,
      queuePath: distConfig.queuePath,
      record: record,
      secret: dbSecret,
    );
    _status('completed', 4,
        'Uploaded video "${meta?.title.isNotEmpty == true ? meta!.title : baseSlug}" to ${acc.name} Panel! Queue Key: $firebaseKey');
    return (
      accountName: acc.name,
      firebaseKey: firebaseKey,
      metadata: meta,
    );
  }
}
