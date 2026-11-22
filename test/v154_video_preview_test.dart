// v154 — animation preview plays the LOCAL saved MP4; the card
// shows the job's real metadata (prompt title + style + duration);
// the card never claims a hardcoded 60fps.
//
// Live 2026-11-22: the video WAS in the app ("Animation ready ✓")
// but the preview failed with ExoPlayer "Source error", the card
// showed generic text instead of the prompt's metadata, and the
// file was 30fps while the card claimed 60fps.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/mp4_info.dart';
import 'package:gemini_hd_studio/video_playback.dart';

import 'mp4_test_helpers.dart';

GeckoBrowserRequest _videoReq(String action, Map<String, dynamic> data) =>
    GeckoBrowserRequest(action, const [], 'https://gemini.google.com/app',
        'Gemini',
        data: data);

Future<Uint8List> _hangingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    Completer<Uint8List>().future;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v154: mp4 sniff + info', () {
    test('isMp4Bytes: minimal MP4 yes, HTML / empty / short no', () {
      expect(isMp4Bytes(minimalMp4()), isTrue);
      expect(
          isMp4Bytes(Uint8List.fromList(
              '<!doctype html><html><body>sign in</body></html>'
                  .codeUnits)),
          isFalse);
      expect(isMp4Bytes(Uint8List(0)), isFalse);
      expect(isMp4Bytes(Uint8List.fromList([1, 2, 3])), isFalse);
    });

    test('readMp4Info: synthetic 30fps / 60fps / garbage', () {
      final info30 = readMp4Info(minimalMp4(fps: 30, durationSec: 6));
      expect(info30, isNotNull);
      expect(info30!.fps, 30);
      expect(info30.durationSec, 6);
      final info60 = readMp4Info(minimalMp4(fps: 60, durationSec: 10));
      expect(info60, isNotNull);
      expect(info60!.fps, 60);
      expect(info60.durationSec, 10);
      expect(readMp4Info(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(readMp4Info(Uint8List(0)), isNull);
    });

    test('readMp4Info: real ffmpeg files (30fps + 60fps)', () async {
      // Same real-file pattern as the v141 preview test: a 1s
      // h264 clip at the Zedge spec size, encoded at each rate.
      final dir = Directory.systemTemp.createTempSync('anim-v154-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<String> render(int fps) async {
        final out = '${dir.path}/v$fps.mp4';
        final r = await Process.run('ffmpeg', [
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=0x0a0a2a:s=1620x2880:d=1',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-r',
          '$fps',
          out,
        ]);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        return out;
      }

      final f30 = await render(30);
      final info30 = readMp4Info(await File(f30).readAsBytes());
      expect(info30, isNotNull);
      expect(info30!.fps, 30);
      expect(info30.durationSec, closeTo(1, 0.1));

      final f60 = await render(60);
      final info60 = readMp4Info(await File(f60).readAsBytes());
      expect(info60, isNotNull);
      expect(info60!.fps, 60);
      expect(info60.durationSec, closeTo(1, 0.1));
    });
  });

  group('v154: download validation + cookies', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v154-');
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
      http.Client? client,
      VideoCookieHeaderProvider? cookieHeaderProvider,
      Duration? watchdogQuiet,
    }) {
      final engine = AnimationEngine(
        httpClient: client,
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: watchdogQuiet ?? const Duration(minutes: 10),
        taskBackendRunner: _hangingRunner,
        cookieHeaderProvider: cookieHeaderProvider,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    Future<AnimationEngine> startedEngine({
      http.Client? client,
      VideoCookieHeaderProvider? cookieHeaderProvider,
    }) async {
      final engine = engineWith(
          client: client, cookieHeaderProvider: cookieHeaderProvider);
      await engine.load();
      await engine.start(
          rawPrompt: 'fire magnetic charging animation',
          modelId: 'neon',
          signedIn: true);
      return engine;
    }

    test('non-MP4 dataUrl fails the job, saves nothing', () async {
      final engine = await startedEngine();
      final jobId = engine.currentJobId;
      final b64 = base64Encode(
          '<!doctype html><html>sign in</html>'.codeUnits);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl': 'data:video/mp4;base64,$b64',
            'durationSec': 10,
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('MP4 na'));
      expect(engine.videos, isEmpty);
    });

    test('valid 30fps MP4 saves the REAL fps + duration', () async {
      final engine = await startedEngine();
      final jobId = engine.currentJobId;
      final mp4 = minimalMp4(fps: 30, durationSec: 6);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl': 'data:video/mp4;base64,${base64Encode(mp4)}',
            'durationSec': 10,
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
      final v = engine.videos.first;
      // The file's own 30fps / 6s win over the event's 10s and the
      // old hardcoded 60.
      expect(v.fps, 30);
      expect(v.durationSec, 6);
      expect(v.specLine, contains('30fps'));
      expect(v.specLine, isNot(contains('60fps')));
      // The status says so too, instead of a bare "Animation ready ✓".
      expect(engine.status, contains('30fps'));
      expect(engine.status, contains('60fps chawa hoyechilo'));
      expect(await File(v.localPath).length(), mp4.length);
    });

    test('URL download sends the session Cookie; HTML 200 fails',
        () async {
      http.BaseRequest? seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('<!doctype html><html>sign in</html>', 200);
      });
      final engine = await startedEngine(
        client: client,
        cookieHeaderProvider: () async => '__Secure-1PSID=abc; x=y',
      );
      final jobId = engine.currentJobId;
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'url': 'https://example.com/v.mp4',
            'durationSec': 10,
          })),
          isTrue);
      expect(seen, isNotNull);
      expect(seen!.headers['cookie'], '__Secure-1PSID=abc; x=y');
      // The HTML sign-in page is rejected, not saved as `.mp4`.
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('MP4 na'));
      expect(engine.videos, isEmpty);
    });

    test('URL download without a provider sends no Cookie', () async {
      http.BaseRequest? seen;
      final mp4 = minimalMp4(fps: 60, durationSec: 10);
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(mp4, 200);
      });
      final engine = await startedEngine(client: client);
      final jobId = engine.currentJobId;
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'url': 'https://example.com/v.mp4',
            'durationSec': 10,
          })),
          isTrue);
      expect(seen!.headers['cookie'], isNull);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos.first.fps, 60);
    });
  });

  group('v154: preview source resolution', () {
    test('missing file names the path; HTML file says MP4 na; '
        'valid MP4 is fine', () {
      final dir = Directory.systemTemp.createTempSync('anim-v154-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = '${dir.path}/nope.mp4';
      final problem = videoPreviewProblem(missing);
      expect(problem, isNotNull);
      expect(problem, contains(missing));
      expect(problem, isNot(contains('PlatformException')));

      final html = File('${dir.path}/bad.mp4')
        ..writeAsStringSync('<!doctype html><html>sign in</html>');
      expect(videoPreviewProblem(html.path), contains('MP4 na'));

      final good = File('${dir.path}/good.mp4')
        ..writeAsBytesSync(minimalMp4(fps: 30, durationSec: 6));
      expect(videoPreviewProblem(good.path), isNull);
    });
  });

  group('v154: title + fps retry + legacy re-probe', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v154-');
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
        watchdogQuiet: const Duration(minutes: 10),
        taskBackendRunner: runner ?? _hangingRunner,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('title keeps the prompt, not a 40-char fragment', () async {
      // Live 2026-11-22: the card read "High-angle vertical 9:16
      // c…" for a long polished prompt — a 40-char cut that
      // identifies nothing.
      const prompt = 'High-angle vertical 9:16 close-up of a '
          'smartphone with fire magnetic charging animation and neon '
          'glow effects all around the frame';
      expect(prompt.length, greaterThan(120));
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: prompt, modelId: 'neon', signedIn: true);
      final jobId = engine.currentJobId;
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl':
                'data:video/mp4;base64,${base64Encode(minimalMp4(fps: 60, durationSec: 10))}',
            'durationSec': 10,
          })),
          isTrue);
      final title = engine.videos.first.title;
      expect(title.length, greaterThan(40));
      // The title is a prefix of the prompt (cut on a word
      // boundary), never the old 40-char mid-word fragment.
      expect(prompt.startsWith(title.replaceAll('…', '')), isTrue);
      expect(title, isNot('${prompt.substring(0, 40)}…'));
    });

    test('start(fpsRetry: true) asks for 60fps emphatically', () async {
      String? taskText;
      final engine = engineWith(
        runner: (text, {required onPhase, required deadline}) {
          taskText = text;
          return _hangingRunner(text, onPhase: onPhase, deadline: deadline);
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true,
              fpsRetry: true),
          isTrue);
      expect(taskText, contains('NOT 30fps'));
      expect(taskText, contains('60 frames per second'));
    });

    test('load() re-probes a legacy video: stored 60fps -> real 30fps',
        () async {
      // A v153-saved record claims the asked 60fps; the file
      // itself is 30fps. Reloading must correct the record from
      // the file — no regeneration needed.
      final engine = engineWith();
      await engine.load();
      await engine.start(
          rawPrompt: 'fire magnetic charging animation',
          modelId: 'neon',
          signedIn: true);
      final jobId = engine.currentJobId;
      final mp4 = minimalMp4(fps: 30, durationSec: 6);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl': 'data:video/mp4;base64,${base64Encode(mp4)}',
            'durationSec': 10,
          })),
          isTrue);
      expect(engine.videos.first.fps, 30);
      // Rewrite the stored record the way v153 saved it: fps 60.
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('animationVideosJson')!) as List;
      final map = Map<String, dynamic>.from(stored.first as Map);
      map['fps'] = 60;
      map['durationSec'] = 10;
      await prefs.setString('animationVideosJson', jsonEncode([map]));
      final again = engineWith();
      await again.load();
      expect(again.videos, hasLength(1));
      expect(again.videos.first.fps, 30);
      expect(again.videos.first.durationSec, 6);
    });

    test('fpsNote: honest under 60fps, silent at 60 / unknown', () {
      AnimationVideo v(int fps) => AnimationVideo(
            id: 'v1',
            title: 't',
            prompt: 't',
            modelId: 'neon',
            localPath: '/tmp/a.mp4',
            fileName: 'a.mp4',
            fps: fps,
            createdAt: DateTime.now(),
          );
      expect(v(30).fpsNote, contains('30 fps'));
      expect(v(30).fpsNote, contains('60fps deyni'));
      expect(v(60).fpsNote, isEmpty);
      expect(v(0).fpsNote, isEmpty);
    });
  });

  group('v154: card metadata + real fps', () {
    AnimationVideo cardVideo({
      int fps = 0,
      double durationSec = 0,
      int requestedDurationSec = 10,
      String styleId = 'cinematic',
    }) =>
        AnimationVideo(
          id: 'v1',
          title: 'fire magnetic charging animation',
          prompt: 'fire magnetic charging animation',
          modelId: 'neon',
          styleId: styleId,
          requestedDurationSec: requestedDurationSec,
          localPath: '/tmp/anim_v1.mp4',
          fileName: 'anim_v1.mp4',
          fps: fps,
          durationSec: durationSec,
          createdAt: DateTime.now(),
        );

    test('card line shows style + requested duration + model', () {
      // The live video: prompt title, Cinematic style, 10s asked,
      // real duration unknown (0) — the card still shows the 10s.
      final line = cardVideo().cardLine;
      expect(line, contains('Cinematic'));
      expect(line, contains('10s'));
      expect(line, contains('Deeper analysis'));
      expect(line, contains('1620x2880'));
      // fps was never measured: no fps claim at all.
      expect(line, isNot(contains('fps')));
    });

    test('card line shows the REAL fps, never a hardcoded 60', () {
      expect(cardVideo(fps: 30, durationSec: 6).cardLine,
          contains('30fps'));
      expect(cardVideo(fps: 30, durationSec: 6).cardLine,
          isNot(contains('60fps')));
      expect(cardVideo(fps: 60, durationSec: 10).cardLine,
          contains('60fps'));
      expect(cardVideo(fps: 60, durationSec: 10).cardLine,
          contains('10s'));
    });

    test('specLine: real duration wins, requested is the fallback',
        () {
      expect(cardVideo(durationSec: 6).specLine, contains('6s'));
      expect(cardVideo(durationSec: 0).specLine, contains('10s'));
    });

    test('task prompt asks for 60fps in the lead AND the suffix',
        () async {
      String? taskText;
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        taskBackendRunner: (text, {required onPhase, required deadline}) {
          taskText = text;
          return _hangingRunner(text, onPhase: onPhase, deadline: deadline);
        },
      );
      addTearDown(engine.dispose);
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('anim-v154-');
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
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      expect(taskText, isNotNull);
      expect(taskText, contains('60 frames per second'));
      expect(taskText, contains('60fps'));
    });
  });
}
