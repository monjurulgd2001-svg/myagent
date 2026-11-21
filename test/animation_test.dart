// v86: Charging Animation section — Gemini (Neon default, Task
// mode) makes videos in the app's Gecko browser session; the
// finished MP4s live in the gallery below the prompt.
// v87: per-video AI metadata (title / tags / category /
// description, same shape as the image sets) + Upload to Panel
// (R2 file + Firebase queue record, same as the image sets).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:gemini_hd_studio/task_backend.dart';

GeckoBrowserRequest _videoReq(String action, Map<String, dynamic> data) =>
    GeckoBrowserRequest(action, const [], 'https://gemini.google.com/app',
        'Gemini',
        data: data);

// v106 — the engine never opens the browser anymore, so tests run
// the backend: a runner that never returns (the job stays busy,
// like a generation in progress).
Future<Uint8List> hangingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    Completer<Uint8List>().future;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Animation models + prompt builder', () {
    test('4 models, Neon default, Carbon locked', () {
      expect(kAnimationModels.length, 4);
      expect(kDefaultAnimationModel, 'neon');
      expect(animationModelById('neon').label, 'Deeper analysis');
      expect(animationModelById('neon').subtitle, '4 Neon');
      expect(animationModelById('carbon').locked, isTrue);
      expect(animationModelById('hydrogen').locked, isFalse);
      expect(animationModelById('neon').matchTexts, contains('Neon'));
      expect(animationModelById('zzz').id, 'neon');
    });

    test('buildAnimationPrompt appends the Zedge spec', () {
      expect(buildAnimationPrompt('  '), '');
      final p = buildAnimationPrompt('neon blue liquid energy phone');
      expect(p, startsWith('neon blue liquid energy phone'));
      expect(p, contains('1620x2880'));
      expect(p, contains('9:16'));
      expect(p, contains('60fps'));
      expect(p, contains('seamless loop'));
      expect(p, contains('no text'));
      expect(p, contains('no logo'));
      // v88 defaults: Cinematic style + 10s requested length.
      expect(p, contains('cinematic lighting'));
      expect(p, contains('10 seconds long'));
      // v104 — originality + motion ride on every prompt: not a
      // copy, no copyrighted element, no common generic scene, and
      // real continuous motion (a video, not a still keyframe).
      expect(p, contains('original unique concept'));
      expect(p, contains('not copied'));
      expect(p, contains('no copyrighted element'));
      expect(p, contains('avoid common generic scenes'));
      expect(p, contains('continuous motion throughout'));
      // v105 — the word ANIMATION itself is in the sent prompt, so
      // the agent makes an animation, not live-action-style video.
      expect(p, contains('animation'));
      // A prompt that already carries the size gets only the loop
      // suffix — "1620x2880" is never written twice.
      final p2 = buildAnimationPrompt('1620x2880 9:16 60fps creative');
      expect('1620x2880'.allMatches(p2).length, 1);
      expect(p2, contains('seamless loop'));
      // v104 — the originality clause still applies to a prompt
      // that already carries the size.
      expect(p2, contains('original unique concept'));
      // v88 — a prompt that already asks for a loop still gets
      // the style + length + spec, but the loop is never doubled.
      const p3 = 'a golden phone, seamless loop, no text';
      final built3 = buildAnimationPrompt(p3);
      expect('seamless loop'.allMatches(built3).length, 1);
      expect(built3, contains('1620x2880'));
      expect(built3, contains('cinematic lighting'));
    });

    test('AnimationVideo JSON round-trip + spec line', () {
      final v = AnimationVideo(
        id: '1',
        title: 'Neon blue phone',
        prompt: 'neon blue phone',
        modelId: 'neon',
        localPath: '/tmp/anim_1.mp4',
        fileName: 'anim_1.mp4',
        durationSec: 6,
        sizeBytes: 4742568,
        createdAt: DateTime.utc(2026, 11, 19),
      );
      final back = AnimationVideo.fromJson(v.toJson());
      expect(back?.title, 'Neon blue phone');
      expect(back?.durationSec, 6);
      expect(v.specLine, contains('1620x2880'));
      expect(v.specLine, contains('60fps'));
      expect(v.specLine, contains('6s'));
      expect(AnimationVideo.fromJson('nope'), isNull);
    });

    test('AnimationVideoEvent.fromData parses driver events', () {
      final ready = AnimationVideoEvent.fromData('video_ready', {
        'jobId': 'j1',
        'url': 'https://example.com/v.mp4',
        'durationSec': 6,
        'width': 1620,
        'height': 2880,
      });
      expect(ready?.isVideo, isTrue);
      expect(ready?.url, 'https://example.com/v.mp4');
      expect(ready?.durationSec, 6);
      expect(AnimationVideoEvent.fromData('video_ready', 'nope'), isNull);
    });
  });

  group('AnimationEngine', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // createTempSync: the async createTemp never completes inside
      // the testWidgets fake-async zone (hung the ready test).
      tmp = Directory.systemTemp.createTempSync('anim-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tmp.path;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    AnimationEngine engineWith({
      TaskBackendRunner? runner,
      http.Client? client,
    }) {
      // The job-timeout Timer must be cancelled at teardown, or
      // the test fails with "A Timer is still pending" (the
      // 'start runs the backend' test never finishes its job).
      final engine = AnimationEngine(
        httpClient: client,
        jobTimeout: const Duration(seconds: 5),
        taskBackendRunner: runner ?? hangingRunner,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('start guards: blank prompt, signed-out, locked model', () async {
      final engine = engineWith();
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: '  ', modelId: 'neon', signedIn: true),
          isFalse);
      expect(engine.phase, AnimationPhase.error);
      expect(
          await engine.start(
              rawPrompt: 'a phone', modelId: 'neon', signedIn: false),
          isFalse);
      expect(engine.status, contains('sign in'));
      expect(
          await engine.start(
              rawPrompt: 'a phone', modelId: 'carbon', signedIn: true),
          isFalse);
      expect(engine.status, contains('lock'));
    });

    test('start runs the backend with the built prompt (Neon)',
        () async {
      var backendText = '';
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          backendText = taskText;
          return hangingRunner(taskText,
              onPhase: onPhase, deadline: deadline);
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue liquid energy phone',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(engine.phase, AnimationPhase.opening);
      expect(backendText, contains('1620x2880'));
      expect(backendText, contains('seamless loop'));
      expect(backendText, contains('animation video'));
      expect(engine.currentJobId, isNotEmpty);
      // A second start while busy is refused.
      expect(
          await engine.start(
              rawPrompt: 'another', modelId: 'neon', signedIn: true),
          isFalse);
    });

    test('progress -> ready (https URL) saves the MP4', () async {
      final client = MockClient((req) async =>
          http.Response.bytes([0, 1, 2, 3, 4, 5], 200));
      final engine = engineWith(client: client);
      await engine.load();
      await engine.start(
          rawPrompt: 'neon blue phone', modelId: 'neon', signedIn: true);
      final jobId = engine.currentJobId;
      expect(
          await engine.handleRequest(_videoReq('video_progress', {
            'jobId': jobId,
            'phase': 'creating',
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.creating);
      // A request for another job is ignored.
      expect(
          await engine.handleRequest(_videoReq('video_progress', {
            'jobId': 'other',
            'phase': 'creating',
          })),
          isFalse);
      // Non-video requests pass through untouched.
      expect(
          await engine.handleRequest(
              const GeckoBrowserRequest('single', [], '', '')),
          isFalse);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'url': 'https://example.com/v.mp4',
            'durationSec': 6,
            'width': 1620,
            'height': 2880,
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos.length, 1);
      final v = engine.videos.first;
      expect(v.title, contains('neon blue phone'));
      expect(v.durationSec, 6);
      expect(await File(v.localPath).exists(), isTrue);
      expect(await File(v.localPath).length(), 6);
      // The video survives a reload from SharedPreferences.
      final again = engineWith();
      await again.load();
      expect(again.videos.length, 1);
      expect(again.videos.first.fileName, v.fileName);
    });

    test('ready via in-page data URL + error path + delete', () async {
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: 'molten gold phone', modelId: 'neon', signedIn: true);
      final jobId = engine.currentJobId;
      final b64 = base64Encode([9, 8, 7]);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl': 'data:video/mp4;base64,$b64',
            'durationSec': 8,
          })),
          isTrue);
      expect(engine.videos.length, 1);
      expect(await File(engine.videos.first.localPath).length(), 3);
      await engine.deleteVideo(engine.videos.first);
      expect(engine.videos, isEmpty);
      // Error: the step + message reach the status line.
      await engine.start(
          rawPrompt: 'crimson phone', modelId: 'neon', signedIn: true);
      final job2 = engine.currentJobId;
      expect(
          await engine.handleRequest(_videoReq('video_error', {
            'jobId': job2,
            'step': 'creating',
            'message': 'daily limit sesh',
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('daily limit sesh'));
    });

    test('v89: timeout names the last driver step, not a blind message',
        () async {
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: 'crimson phone', modelId: 'neon', signedIn: true);
      final jobId = engine.currentJobId;
      await engine.handleRequest(_videoReq('video_progress', {
        'jobId': jobId,
        'phase': 'creating',
      }));
      // jobTimeout is 5s in tests — wait for the timer to fire.
      await Future.delayed(const Duration(seconds: 6));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('sesh step: video banacche'));
    });

    test('v90: timeout names the Task-mode step too', () async {
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: 'crimson phone', modelId: 'neon', signedIn: true);
      final jobId = engine.currentJobId;
      await engine.handleRequest(_videoReq('video_progress', {
        'jobId': jobId,
        'phase': 'task_mode',
        'message': 'Task mode-e video banacche…',
      }));
      await Future.delayed(const Duration(seconds: 6));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('sesh step: Task mode-e cholche'));
    });

    test('v89: timeout with no driver contact says so', () async {
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: 'crimson phone', modelId: 'neon', signedIn: true);
      await Future.delayed(const Duration(seconds: 6));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('kono jogajog hoyni'));
    });

    test('buildVideosZip holds the MP4 + metadata.json', () async {
      final client = MockClient((req) async =>
          http.Response.bytes([1, 2, 3], 200));
      final engine = engineWith(client: client);
      await engine.load();
      await engine.start(
          rawPrompt: 'quantum phone', modelId: 'neon', signedIn: true);
      await engine.handleRequest(_videoReq('video_ready', {
        'jobId': engine.currentJobId,
        'url': 'https://example.com/v.mp4',
        'durationSec': 6,
      }));
      final zip = await engine.buildVideosZip();
      final archive =
          ZipDecoder().decodeBytes(await zip.readAsBytes());
      final names = [for (final f in archive.files) f.name];
      expect(names, contains('metadata.json'));
      expect(names.any((n) => n.endsWith('.mp4')), isTrue);
      final meta = jsonDecode(
          utf8.decode(archive.findFile('metadata.json')!.content as List<int>))
          as Map;
      expect((meta['videos'] as List).first['prompt'], 'quantum phone');
    });
  });

  group('v87: AI metadata + panel upload', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim87-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tmp.path;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    AnimationEngine engineWith({
      VideoMetadataGenerator? metadataGenerator,
      VideoPanelUploader? panelUploader,
    }) {
      final engine = AnimationEngine(
        metadataGenerator: metadataGenerator,
        panelUploader: panelUploader,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    SetMetadata fakeMeta() => SetMetadata(
          file: 'anim_v1.mp4',
          title: 'Neon Blue Phone',
          tags: ['neon', 'phone', 'charging'],
          category: 'DESIGNS',
          description: 'A neon blue phone charging.',
          generatedAtMs: 1,
        );

    AnimationVideo testVideo({SetMetadata? metadata}) {
      final path = '${tmp.path}/anim_v1.mp4';
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      return AnimationVideo(
        id: 'v1',
        title: 'Neon blue phone',
        prompt: 'neon blue phone',
        modelId: 'neon',
        localPath: path,
        fileName: 'anim_v1.mp4',
        durationSec: 6,
        sizeBytes: 4,
        createdAt: DateTime.utc(2026, 11, 19),
        metadata: metadata,
      );
    }

    Future<AnimationEngine> engineWithVideo(
      AnimationVideo v, {
      VideoMetadataGenerator? metadataGenerator,
      VideoPanelUploader? panelUploader,
    }) async {
      SharedPreferences.setMockInitialValues({
        'animationVideosJson': jsonEncode([v.toJson()]),
      });
      final engine = engineWith(
        metadataGenerator: metadataGenerator,
        panelUploader: panelUploader,
      );
      await engine.load();
      expect(engine.videos.length, 1);
      return engine;
    }

    test('AnimationVideo JSON round-trip keeps metadata + panel state',
        () {
      final v = testVideo(metadata: fakeMeta()).copyWith(uploadedToPanel: {
        'accountName': 'zedge_1',
        'firebaseKey': '-Nkey1',
        'uploadedAt': 123,
      });
      final back = AnimationVideo.fromJson(v.toJson())!;
      expect(back.metadata?.title, 'Neon Blue Phone');
      expect(back.metadata?.tags, ['neon', 'phone', 'charging']);
      expect(back.metadata?.category, 'DESIGNS');
      expect(back.hasMetadata, isTrue);
      expect(back.isUploaded, isTrue);
      expect(back.uploadedAccount, 'zedge_1');
      expect(back.uploadedToPanel?['firebaseKey'], '-Nkey1');
      // And a plain video round-trips with neither.
      final plain = AnimationVideo.fromJson(testVideo().toJson())!;
      expect(plain.hasMetadata, isFalse);
      expect(plain.isUploaded, isFalse);
    });

    test('generateMetadataForVideo stores + persists the metadata',
        () async {
      final engine = await engineWithVideo(testVideo(),
          metadataGenerator: (_) async => fakeMeta());
      expect(await engine.generateMetadataForVideo(engine.videos.first),
          isTrue);
      expect(engine.videos.first.metadata?.title, 'Neon Blue Phone');
      expect(engine.status, contains('Neon Blue Phone'));
      final again = engineWith();
      await again.load();
      expect(again.videos.first.metadata?.tags, hasLength(3));
    });

    test('generateMetadataForVideo reports a generator failure',
        () async {
      final engine = await engineWithVideo(testVideo(),
          metadataGenerator: (_) async => throw Exception('no session'));
      expect(await engine.generateMetadataForVideo(engine.videos.first),
          isFalse);
      expect(engine.status, contains('Metadata hoyni'));
      expect(engine.videos.first.hasMetadata, isFalse);
    });

    test('uploadVideoToPanel marks the video queued + keeps metadata',
        () async {
      final engine = await engineWithVideo(testVideo(metadata: fakeMeta()),
          panelUploader: (v, {targetAccount = 'spread'}) async => (
                accountName: 'zedge_1',
                firebaseKey: '-Nkey1',
                metadata: v.metadata,
              ));
      expect(
          await engine.uploadVideoToPanel(engine.videos.first,
              targetAccount: 'zedge_1'),
          isTrue);
      final v = engine.videos.first;
      expect(v.isUploaded, isTrue);
      expect(v.uploadedAccount, 'zedge_1');
      expect(v.uploadedToPanel?['firebaseKey'], '-Nkey1');
      expect(v.metadata?.title, 'Neon Blue Phone');
      expect(engine.status, contains('zedge_1'));
      final again = engineWith();
      await again.load();
      expect(again.videos.first.isUploaded, isTrue);
    });

    test('uploadAllToPanel uploads every video', () async {
      final v1 = testVideo();
      final v2 = AnimationVideo(
        id: 'v2',
        title: 'Molten gold phone',
        prompt: 'molten gold phone',
        modelId: 'neon',
        localPath: '${tmp.path}/anim_v2.mp4',
        fileName: 'anim_v2.mp4',
        durationSec: 6,
        sizeBytes: 4,
        createdAt: DateTime.utc(2026, 11, 19),
      );
      File(v2.localPath).writeAsBytesSync([5, 6]);
      SharedPreferences.setMockInitialValues({
        'animationVideosJson': jsonEncode([v1.toJson(), v2.toJson()]),
      });
      final engine = engineWith(
          panelUploader: (v, {targetAccount = 'spread'}) async => (
                accountName: 'zedge_1',
                firebaseKey: '-N${v.id}',
                metadata: v.metadata,
              ));
      await engine.load();
      expect(await engine.uploadAllToPanel(), 2);
      expect(engine.videos.every((v) => v.isUploaded), isTrue);
      expect(engine.status, contains('Shob video'));
    });

    test('buildVideosZip carries the AI metadata per video', () async {
      final engine = await engineWithVideo(testVideo(metadata: fakeMeta()));
      final zip = await engine.buildVideosZip();
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final meta = jsonDecode(
          utf8.decode(archive.findFile('metadata.json')!.content as List<int>))
          as Map;
      final entry = (meta['videos'] as List).first as Map;
      expect(entry['metadata']['title'], 'Neon Blue Phone');
      expect(entry['metadata']['tags'], ['neon', 'phone', 'charging']);
    });

    test('buildVideoPanelRecord is the video queue contract', () {
      final v = testVideo(metadata: fakeMeta());
      final record = StudioEngine.buildVideoPanelRecord(
        video: v,
        fileUrl: 'https://r2.example.com/zedge1/wallpaper/1_x.mp4',
        fileName: 'neon-blue-phone.mp4',
        fileSize: 4000000,
        fileSha: 'abc',
        meta: v.metadata,
        now: 123,
      );
      expect(record['type'], 'video/mp4');
      expect(record['isVideo'], isTrue);
      expect(record['isImage'], isFalse);
      expect(record['contentType'], 'LIVE_WALLPAPER');
      expect(record['width'], 1620);
      expect(record['height'], 2880);
      expect(record['durationSec'], 6);
      expect(record['fps'], 60);
      expect(record['status'], 'queued');
      expect(record['title'], 'Neon Blue Phone');
      expect(record['tagsList'], ['neon', 'phone', 'charging']);
      expect(record['category'], 'DESIGNS');
      expect(record['policyCheck'], 'passed');
      // Without metadata there is no title/tags block at all.
      final bare = StudioEngine.buildVideoPanelRecord(
        video: testVideo(),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
      );
      expect(bare.containsKey('title'), isFalse);
      expect(bare['isVideo'], isTrue);
    });

    test('StudioEngine.uploadVideoToPanel posts MP4 to R2 + record',
        () async {
      http.Request? r2Req;
      http.Request? fbReq;
      final client = MockClient((req) async {
        if (req.url.host == 'worker.example.com') {
          r2Req = req;
          return http.Response(
              '{"url": "https://r2.example.com/zedge1/wallpaper/123_neon-blue-phone.mp4"}',
              200);
        }
        if (req.url.host == 'db.example.com') {
          fbReq = req;
          return http.Response('{"name": "-Nkey1"}', 200);
        }
        return http.Response('not found', 404);
      });
      SharedPreferences.setMockInitialValues({
        'distConfigJson': jsonEncode({
          'r2WorkerUrl': 'https://worker.example.com',
          'queuePath': 'wallpaperQueue',
          'accounts': [
            {
              'name': 'zedge_1',
              'dbUrl': 'https://db.example.com',
              'secret': ''
            }
          ],
          'defaultTarget': 'spread',
        }),
      });
      final engine = StudioEngine(client: client);
      final v = testVideo(metadata: fakeMeta());
      final r = await engine.uploadVideoToPanel(v);
      expect(r.accountName, 'zedge_1');
      expect(r.firebaseKey, '-Nkey1');
      expect(r.metadata?.title, 'Neon Blue Phone');
      expect(r2Req?.headers['X-File-Type'], 'video/mp4');
      expect(r2Req?.headers['X-File-Name'], contains('wallpaper/'));
      expect(r2Req?.headers['X-File-Name'], endsWith('.mp4'));
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['type'], 'video/mp4');
      expect(record['isVideo'], isTrue);
      expect(record['contentType'], 'LIVE_WALLPAPER');
      expect(record['title'], 'Neon Blue Phone');
      expect(record['tagsList'], ['neon', 'phone', 'charging']);
      expect(record['status'], 'queued');
      expect(record['prompt'], 'neon blue phone');
    });

    test('StudioEngine.uploadVideoToPanel throws when unconfigured',
        () async {
      SharedPreferences.setMockInitialValues({'distConfigJson': '{}'});
      final engine = StudioEngine(client: MockClient((_) async =>
          http.Response('{}', 200)));
      expect(
          () async => engine.uploadVideoToPanel(testVideo()),
          throwsA(isA<Exception>()));
    });
  });

  group('v88: duration + style/mood + seamless + polish + copyright guard',
      () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim88-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tmp.path;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    AnimationEngine engineWith({
      TaskBackendRunner? runner,
      VideoPromptPolisher? promptPolisher,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        promptPolisher: promptPolisher,
        // v106 — backend-only: the default runner never returns, so
        // a started job stays busy like a generation in progress.
        taskBackendRunner: runner ?? hangingRunner,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('styles: 7 moods, Cinematic default, unknown falls back', () {
      expect(kAnimationMoods.length, 7);
      expect(animationMoodById('cinematic').label, 'Cinematic');
      expect(animationMoodById('neon').suffix, contains('neon glow'));
      expect(animationMoodById('none').suffix, isEmpty);
      expect(animationMoodById('zzz').id, 'cinematic');
      expect(kDefaultAnimationMoodId, 'cinematic');
      expect(kAnimationDurations, [6, 8, 10]);
      expect(kDefaultAnimationDurationSec, 10);
      expect(kDefaultAnimationSeamless, isTrue);
    });

    test('buildAnimationPrompt honours style / duration / seamless', () {
      // No style, no length, no loop.
      final plain = buildAnimationPrompt(
        'golden phone',
        styleId: 'none',
        durationSec: 0,
        seamless: false,
      );
      expect(plain, isNot(contains('cinematic')));
      expect(plain, isNot(contains('seconds long')));
      expect(plain, isNot(contains('seamless loop')));
      expect(plain, contains('1620x2880'));
      // Neon style + 6s + loop off.
      final neon = buildAnimationPrompt(
        'golden phone',
        styleId: 'neon',
        durationSec: 6,
        seamless: false,
      );
      expect(neon, contains('vibrant neon glow'));
      expect(neon, contains('6 seconds long'));
      expect(neon, isNot(contains('seamless loop')));
      // Seamless on adds the loop once.
      final looped = buildAnimationPrompt(
        'golden phone',
        styleId: 'none',
        durationSec: 0,
        seamless: true,
      );
      expect('seamless loop'.allMatches(looped).length, 1);
      // Unknown style id falls back to Cinematic.
      final fallback = buildAnimationPrompt('golden phone', styleId: 'zzz');
      expect(fallback, contains('cinematic lighting'));
    });

    test('copyright guard flags brands, characters, people', () {
      expect(checkAnimationPromptSafety('neon blue phone'), isEmpty);
      expect(checkAnimationPromptSafety('a phone charging'), isEmpty);
      expect(checkAnimationPromptSafety('an iPhone on a table'),
          contains('iphone'));
      expect(checkAnimationPromptSafety('DISNEY castle at night'),
          contains('disney'));
      expect(checkAnimationPromptSafety('Batman standing on a roof'),
          contains('batman'));
      expect(
          checkAnimationPromptSafety('in the style of Pixar, a lamp'),
          containsAll(['in the style of', 'pixar']));
      expect(checkAnimationPromptSafety('Taylor Swift singing'),
          contains('taylor swift'));
      expect(checkAnimationPromptSafety('a Nike shoe floating'),
          contains('nike'));
    });

    test('buildVideoPolishInstruction bans copyright + asks motion',
        () {
      final instruction =
          GeminiApi.buildVideoPolishInstruction('a phone charging');
      expect(instruction, contains('a phone charging'));
      expect(instruction, contains('copyrighted'));
      expect(instruction, contains('MOTION'));
      expect(instruction, contains('9:16'));
      expect(instruction, contains('40-80 words'));
      expect(instruction, contains('seamlessly'));
    });

    test('start blocks a copyright-risk prompt before opening Gemini',
        () async {
      final engine = engineWith();
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'an iPhone charging on a desk',
              modelId: 'neon',
              signedIn: true),
          isFalse);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Copyright risk'));
      expect(engine.status, contains('iphone'));
    });

    test('start builds the prompt from style + duration + seamless',
        () async {
      var backendText = '';
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          backendText = taskText;
          return hangingRunner(taskText,
              onPhase: onPhase, deadline: deadline);
        },
      );
      await engine.load();
      await engine.setStyleId('golden');
      await engine.setDurationSec(6);
      await engine.setSeamless(false);
      expect(
          await engine.start(
              rawPrompt: 'a phone charging',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(backendText, contains('warm golden luxury'));
      expect(backendText, contains('6 seconds long'));
      expect(backendText, isNot(contains('seamless loop')));
      // Defaults (Cinematic / 10s / loop on) when nothing is picked —
      // reset the mock prefs first, or this engine reads the
      // golden/6s choices the first engine just persisted.
      SharedPreferences.setMockInitialValues({});
      var backendText2 = '';
      final engine2 = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          backendText2 = taskText;
          return hangingRunner(taskText,
              onPhase: onPhase, deadline: deadline);
        },
      );
      await engine2.load();
      await engine2.start(
          rawPrompt: 'a phone charging', modelId: 'neon', signedIn: true);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(backendText2, contains('cinematic lighting'));
      expect(backendText2, contains('10 seconds long'));
      expect(backendText2, contains('seamless loop'));
    });

    test('style / duration / seamless persist across reload', () async {
      final engine = engineWith();
      await engine.load();
      await engine.setStyleId('dark');
      await engine.setDurationSec(8);
      await engine.setSeamless(false);
      final again = engineWith();
      await again.load();
      expect(again.selectedStyleId, 'dark');
      expect(again.selectedDurationSec, 8);
      expect(again.seamlessMode, isFalse);
      // An unknown saved duration falls back to 10.
      await engine.setDurationSec(99);
      expect(engine.selectedDurationSec, 10);
    });

    test('polishPrompt returns the polished text; null without a polisher',
        () async {
      final withPolisher = engineWith(
        promptPolisher: (p) async => 'POLISHED: $p',
      );
      await withPolisher.load();
      expect(await withPolisher.polishPrompt('a phone'),
          'POLISHED: a phone');
      expect(withPolisher.status, contains('polished'));
      final without = engineWith();
      await without.load();
      expect(await without.polishPrompt('a phone'), isNull);
      final failing = engineWith(
        promptPolisher: (_) async => throw Exception('Gemini busy'),
      );
      await failing.load();
      expect(await failing.polishPrompt('a phone'), isNull);
      expect(failing.status, contains('Polish hoyni'));
    });

    test('finished video keeps style + requested duration (ZIP metadata)',
        () async {
      final engine = engineWith();
      await engine.load();
      await engine.setStyleId('neon');
      await engine.setDurationSec(8);
      await engine.start(
          rawPrompt: 'a phone charging', modelId: 'neon', signedIn: true);
      final b64 = base64Encode([9, 8, 7, 6]);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': engine.currentJobId,
            'dataUrl': 'data:video/mp4;base64,$b64',
            'durationSec': 6,
          })),
          isTrue);
      // The video lands with the style + duration that were asked for.
      expect(engine.videos.length, 1);
      expect(engine.videos.first.styleId, 'neon');
      expect(engine.videos.first.requestedDurationSec, 8);
      expect(engine.videos.first.durationSec, 6);
      final zip = await engine.buildVideosZip();
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final metaFile =
          archive.files.firstWhere((f) => f.name == 'metadata.json');
      final meta =
          jsonDecode(utf8.decode(metaFile.content as List<int>));
      final entry = (meta['videos'] as List).first as Map;
      expect(entry['style'], 'Neon Glow');
      expect(entry['requestedDurationSec'], 8);
    });
  });

  group('Animation section UI', () {
    Future<void> pumpPhone(WidgetTester tester,
        [Map<String, Object> prefs = const {}]) async {
      SharedPreferences.setMockInitialValues(prefs);
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const GeminiHdStudioApp());
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Animation')));
      await tester.pump(const Duration(milliseconds: 200));
    }

    /// One seeded video in SharedPreferences, with or without AI
    /// metadata + a panel queue entry (the file itself need not
    /// exist — the card never reads it).
    Map<String, Object> prefsWithVideo({bool withMeta = false}) {
      final video = <String, Object>{
        'id': 'v1',
        'title': 'Neon blue phone',
        'prompt': 'neon blue phone',
        'modelId': 'neon',
        'localPath': '/tmp/anim_v1.mp4',
        'fileName': 'anim_v1.mp4',
        'width': 1620,
        'height': 2880,
        'fps': 60,
        'durationSec': 6,
        'sizeBytes': 4,
        'createdAt': '2026-11-19T00:00:00.000Z',
        if (withMeta)
          'metadata': {
            'file': 'anim_v1.mp4',
            'title': 'Neon Blue Phone',
            'tags': ['neon', 'phone', 'charging'],
            'category': 'DESIGNS',
            'description': 'A neon blue phone charging.',
          },
        if (withMeta)
          'uploadedToPanel': {
            'accountName': 'zedge_1',
            'firebaseKey': '-Nkey1',
            'uploadedAt': 123,
          },
      };
      return {'animationVideosJson': jsonEncode([video])};
    }

    testWidgets(
        'v86 phone: model picker (Neon default), Task switch, prompt, empty gallery',
        (tester) async {
      await pumpPhone(tester);
      expect(find.byKey(const ValueKey('animPromptField')), findsOneWidget);
      expect(find.text('Deeper analysis — 4 Neon'), findsOneWidget);
      expect(find.text('Charging Animation'), findsOneWidget);
      final taskSwitch = tester.widget<Switch>(
          find.byKey(const ValueKey('animTaskSwitch')));
      expect(taskSwitch.value, isTrue);
      // Not signed in under the test prefs: Generate stays off and
      // the sign-in hint shows.
      final genBtn = tester.widget<FilledButton>(
          find.byKey(const ValueKey('animGenerateButton')));
      expect(genBtn.onPressed, isNull);
      expect(find.textContaining('Age Login tab theke'), findsOneWidget);
      expect(find.text('No animations yet'), findsOneWidget);
      expect(find.text('Create your first animation'), findsOneWidget);
      expect(find.text('Animations'), findsOneWidget);
      expect(find.text('0 videos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('v86 phone: Carbon is locked in the model menu',
        (tester) async {
      await pumpPhone(tester);
      await tester.tap(find.byKey(const ValueKey('animModelPicker')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Code & complex work — 4 Carbon'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      // Tapping the locked item leaves Neon selected (the menu
      // stays open — the picker's own display still says Neon,
      // and the menu shows it as an item too, so scope the check
      // to the picker button).
      await tester.tap(find.text('Code & complex work — 4 Carbon'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('animModelPicker')),
              matching: find.text('Deeper analysis — 4 Neon')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('v86 phone: Task switch toggles off', (tester) async {
      await pumpPhone(tester);
      // v88: the prompt card grew (Polish + Style + Duration +
      // Seamless rows), so the Task switch sits below the fold —
      // scroll it into view before tapping.
      await tester.ensureVisible(find.byKey(const ValueKey('animTaskSwitch')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('animTaskSwitch')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
          tester
              .widget<Switch>(find.byKey(const ValueKey('animTaskSwitch')))
              .value,
          isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'v87 phone: video card has metadata + upload buttons, dialog shows metadata',
        (tester) async {
      await pumpPhone(tester, prefsWithVideo(withMeta: true));
      expect(find.text('Neon blue phone'), findsOneWidget);
      expect(find.text('1 videos'), findsOneWidget);
      expect(find.text('Queued on zedge_1'), findsOneWidget);
      expect(find.byKey(const ValueKey('animMeta-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('animUpload-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('animUploadAll')), findsOneWidget);
      // The card sits below the prompt card on the phone scroll
      // view — scroll it into view before tapping (otherwise the
      // tap misses and the dialog never opens).
      await tester.ensureVisible(find.byKey(const ValueKey('animMeta-v1')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('animMeta-v1')));
      await tester.pump();
      expect(find.text('Neon Blue Phone'), findsOneWidget);
      expect(find.text('DESIGNS'), findsOneWidget);
      expect(find.text('A neon blue phone charging.'), findsOneWidget);
      expect(find.text('neon'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.text('Neon Blue Phone'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('v87 phone: upload without panel config reports it',
        (tester) async {
      await pumpPhone(tester, prefsWithVideo());
      await tester.ensureVisible(find.byKey(const ValueKey('animUpload-v1')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('animUpload-v1')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
          find.descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining('not configured')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'v88 phone: style picker (Cinematic), duration 10s, seamless on, polish button',
        (tester) async {
      await pumpPhone(tester);
      expect(find.byKey(const ValueKey('animStylePicker')), findsOneWidget);
      expect(find.text('Cinematic'), findsOneWidget);
      expect(
          tester
              .widget<ChoiceChip>(
                  find.byKey(const ValueKey('animDuration-10')))
              .selected,
          isTrue);
      expect(
          tester
              .widget<ChoiceChip>(
                  find.byKey(const ValueKey('animDuration-6')))
              .selected,
          isFalse);
      final seamless = tester.widget<Switch>(
          find.byKey(const ValueKey('animSeamlessSwitch')));
      expect(seamless.value, isTrue);
      expect(find.byKey(const ValueKey('animPolishButton')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('v88 phone: a brand in the prompt shows the copyright warning',
        (tester) async {
      await pumpPhone(tester);
      await tester.enterText(
          find.byKey(const ValueKey('animPromptField')),
          'an iPhone charging on a desk');
      await tester.pump();
      expect(find.byKey(const ValueKey('animSafetyWarning')), findsOneWidget);
      expect(find.textContaining('Copyright risk'), findsOneWidget);
      expect(find.textContaining('iphone'), findsOneWidget);
      // Generate stays off while the risky term is in the prompt.
      final genBtn = tester.widget<FilledButton>(
          find.byKey(const ValueKey('animGenerateButton')));
      expect(genBtn.onPressed, isNull);
      // Rewording clears the warning.
      await tester.enterText(
          find.byKey(const ValueKey('animPromptField')),
          'a phone charging on a desk');
      await tester.pump();
      expect(find.byKey(const ValueKey('animSafetyWarning')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('v86 desktop: rail has 4 destinations, Animation tab',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const GeminiHdStudioApp());
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations.length, 4);
      await tester.tap(find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Animation')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Charging Animation'), findsOneWidget);
      expect(find.text('No animations yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('v92: Task backend only (v106: no browser fallback)', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim92-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tmp.path;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    AnimationEngine engineWith({
      TaskBackendRunner? runner,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        taskBackendRunner: runner,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('backend success: MP4 saved, browser never opens', () async {
      var runnerCalls = 0;
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          runnerCalls++;
          expect(taskText, contains('1620x2880'));
          onPhase('creating', 'Backend-e video banacche…');
          return Uint8List.fromList([1, 2, 3, 4, 5]);
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(runnerCalls, 1);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos.length, 1);
      expect(await File(engine.videos.first.localPath).length(), 5);
      expect(engine.videos.first.width, 1620);
      expect(engine.videos.first.height, 2880);
    });

    test('v106: backend failure ends the job, browser never opens',
        () async {
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          throw const TaskBackendException(
              'channel', 'Conversation id asheni.');
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(engine.phase, AnimationPhase.error);
      // v94 — the failure detail rides along in the error line.
      expect(engine.status,
          contains('Backend hoyni (channel — Conversation id asheni.)'));
      expect(engine.status, contains('browser khulbe na'));
    });

    test('v101: backend gets the video-first Task text', () async {
      var backendText = '';
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          backendText = taskText;
          throw const TaskBackendException(
              'chooseServer', 'HTTP 403 (key chara)');
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
      // Live 2026-11-20 the agent answered with a keyframe image
      // instead of a video — the backend text must demand the video
      // first, in the same words (v106: the driver no longer gets
      // the text at all, so only the backend is asserted).
      expect(backendText, contains('Create a video now'));
      expect(backendText, contains('not an image'));
      expect(backendText, contains('1620x2880'));
      // v105 — the lead says ANIMATION video, not just video.
      expect(backendText, contains('animation video'));
      expect(backendText, contains('animated MP4'));
      // v104 — the lead now demands originality too (not a copy, no
      // copyrighted element, no common generic scene).
      expect(backendText, contains('original and unique'));
      expect(backendText, contains('not a copy'));
      // v106 — the failed backend ends the job; no browser job.
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('browser khulbe na'));
    });

    test('v103: Task mode is mandatory in the driver (no Chat path)',
        () async {
      // The JS driver cannot run in flutter tests; guard the v103
      // markers so a Chat fallback cannot creep back in. User order
      // 2026-11-20: "must task mode lagbe" — a Task prompt typed
      // into a Chat composer gets a plain-chat image answer, not a
      // video, so no Task toggle must fail the job, never fall back.
      final js = await File(
              'android/app/src/main/assets/ais_cookies/content.js')
          .readAsString();
      expect(js, contains('__notask__'));
      expect(js, contains('Task mode chara animation hobe na'));
      expect(js, isNot(contains("findBtn(['Create video'")));
      // The v103 comment names MODEL_MATCH; the code itself must not
      // define or use it anymore.
      expect(js, isNot(contains('const MODEL_MATCH')));
      expect(js, isNot(contains('MODEL_MATCH[model]')));
    });

    test('v102: driver verifies the typed text (no silent empty send)',
        () async {
      // The JS driver cannot run in flutter tests; guard the v102
      // markers so a future edit cannot silently drop them. Live
      // 2026-11-20 the page showed Neon selected with an EMPTY
      // composer while the driver waited 7 min for a video nobody
      // had asked for — the text never landed and nothing noticed.
      final js = await File(
              'android/app/src/main/assets/ais_cookies/content.js')
          .readAsString();
      expect(js, contains('__notyped__'));
      expect(js, contains('aria-disabled'));
      expect(js, contains('editor.isConnected'));
      expect(js, contains('selectAll'));
    });

    test('v100: driver failure keeps the backend step in the error',
        () async {
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          // Fail a beat after start, so the job id is still readable
          // when the test captures it (v106 clears it on failure).
          await Future.delayed(const Duration(milliseconds: 100));
          throw const TaskBackendException(
              'chooseServer', 'HTTP 403 (key chara)');
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      final jobId = engine.currentJobId;
      await Future.delayed(const Duration(milliseconds: 300));
      // v106 — the backend failure already ended the job.
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Backend hoyni (chooseServer'));
      // Live 2026-11-20 (v99): the driver gave up mid-generation
      // and its error overwrote the backend step — a (dormant)
      // driver error must still name both, or the backend failure
      // stays invisible.
      expect(
          await engine.handleRequest(_videoReq('video_error', {
            'jobId': jobId,
            'step': 'creating',
            'message': 'Video toiri hoyni — limit sesh hote pare, '
                'ba Gemini error diyeche.',
            'buttons': 'Main menu | Stop response | New Chat',
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Backend hoyni (chooseServer'));
      expect(engine.status, contains('(creating)'));
      expect(engine.status, contains('Stop response'));
    });

    test('v106: taskMode off refuses the job, browser never opens',
        () async {
      var runnerCalls = 0;
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          runnerCalls++;
          return Uint8List(0);
        },
      );
      await engine.load();
      // load() restores the persisted Task switch (default on) —
      // turn it off AFTER the load, like the user toggling it.
      engine.taskMode = false;
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isFalse);
      expect(runnerCalls, 0);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Task mode ON koro'));
    });

    test('v106: no backend runner refuses the job', () async {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
      );
      addTearDown(engine.dispose);
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging',
              modelId: 'neon',
              signedIn: true),
          isFalse);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Backend ready na'));
    });
  });
}
