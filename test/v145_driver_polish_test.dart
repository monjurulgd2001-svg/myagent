// v145 — backend failure falls back to the browser driver
// (v146: HEADLESS — browser show na kore, backend-e chole), the
// error log keeps the full stream diagnostics, and the wand
// retries when Gemini hands the input back unchanged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/task_backend.dart';

GeckoBrowserRequest _videoReq(String action, Map<String, dynamic> data) =>
    GeckoBrowserRequest(action, const [], 'https://gemini.google.com/app',
        'Gemini',
        data: data);

const _channelDetail =
    'Conversation id asheni — channel khuleche kintu Gemini kono task '
    'thread banayni. (stream: 12 poll, sesh HTTP 200, 12345 byte.)';

Future<Uint8List> _failingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    throw const TaskBackendException('channel', _channelDetail);

Future<Uint8List> _hangingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    Completer<Uint8List>().future;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v145: driver fallback', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v145-');
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
      VideoDriverRunner? driver,
      Duration? watchdogQuiet,
      VideoPromptPolisher? polisher,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: watchdogQuiet ?? const Duration(minutes: 10),
        taskBackendRunner: runner,
        videoDriverRunner: driver,
        promptPolisher: polisher,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('backend channel failure hands the same prompt to the driver',
        () async {
      final driverCalls = <({String prompt, String modelId, String jobId})>[];
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          driverCalls.add((prompt: prompt, modelId: modelId, jobId: jobId));
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
      // The job is NOT dead: the driver owns it now.
      expect(driverCalls, hasLength(1));
      expect(driverCalls.single.prompt,
          contains('fire magnetic charging animation'));
      expect(driverCalls.single.prompt, contains('1620x2880'));
      expect(driverCalls.single.modelId, 'neon');
      expect(driverCalls.single.jobId, engine.currentJobId);
      expect(engine.currentJobId, isNotEmpty);
      expect(engine.phase, isNot(AnimationPhase.error));
      // The driver finishing the video finishes the job.
      final b64 = base64Encode([9, 8, 7]);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': engine.currentJobId,
            'dataUrl': 'data:video/mp4;base64,$b64',
            'durationSec': 10,
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
    });

    test('backend success never calls the driver', () async {
      var driverCalls = 0;
      final engine = engineWith(
        runner: (taskText,
                {required onPhase, required deadline}) async =>
            Uint8List.fromList([1, 2, 3]),
        driver: ({required prompt, required modelId, required jobId}) async {
          driverCalls++;
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue phone', modelId: 'neon', signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(driverCalls, 0);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
    });

    test('no backend at all goes straight to the driver', () async {
      final driverCalls = <String>[];
      final engine = engineWith(
        driver: ({required prompt, required modelId, required jobId}) async {
          driverCalls.add(prompt);
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue phone', modelId: 'neon', signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(driverCalls, hasLength(1));
      expect(driverCalls.single, contains('neon blue phone'));
      expect(engine.phase, isNot(AnimationPhase.error));
    });

    test('driver error after backend failure ends the job naming both',
        () async {
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {},
      );
      await engine.load();
      await engine.start(
          rawPrompt: 'fire magnetic charging animation',
          modelId: 'neon',
          signedIn: true);
      await Future.delayed(const Duration(milliseconds: 300));
      final jobId = engine.currentJobId;
      expect(jobId, isNotEmpty);
      expect(
          await engine.handleRequest(_videoReq('video_error', {
            'jobId': jobId,
            'step': 'typing',
            'message': 'Prompt box-e lekha bosheni',
          })),
          isTrue);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('Backend hoyni'));
      expect(engine.status, contains('Prompt box-e lekha bosheni'));
    });

    test('watchdog hands a quiet backend to the driver', () async {
      var driverCalls = 0;
      final engine = engineWith(
        runner: _hangingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          driverCalls++;
        },
        watchdogQuiet: const Duration(milliseconds: 300),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue liquid energy phone',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(driverCalls, 1);
      expect(engine.errorLog.any((l) => l.contains('driver')), isTrue);
    });

    test('error log keeps the full stream diagnostics', () async {
      final engine = engineWith(runner: _failingRunner);
      await engine.load();
      await engine.start(
          rawPrompt: 'fire magnetic charging animation',
          modelId: 'neon',
          signedIn: true);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.errorLog, hasLength(1));
      // The old 80-char cut ended the line in "banayni…." with the
      // diagnostics after it lost; v145 keeps all of it.
      expect(engine.errorLog.single, contains('12 poll'));
      expect(engine.errorLog.single, contains('sesh HTTP 200'));
      expect(engine.errorLog.single, contains('12345 byte'));
    });
  });

  group('v145: wand repeat fix', () {
    test('polish retries when Gemini returns the input unchanged',
        () async {
      final calls = <String>[];
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        promptPolisher: (prompt) async {
          calls.add(prompt);
          if (prompt.contains('completely different')) {
            return 'A glowing magnetic charger levitates above a neon '
                'wireless pad, energy arcs swirling in a seamless loop.';
          }
          return prompt.split('\n').first;
        },
      );
      addTearDown(engine.dispose);
      final polished = await engine.polishPrompt(
          'fire magnetic charging animation');
      expect(calls, hasLength(2));
      expect(calls[1], contains('completely different'));
      expect(polished, isNot('fire magnetic charging animation'));
      expect(polished, contains('magnetic charger'));
    });

    test('polish does not retry when the first answer already differs',
        () async {
      var calls = 0;
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        promptPolisher: (prompt) async {
          calls++;
          return 'A fresh neon charging scene, totally different words.';
        },
      );
      addTearDown(engine.dispose);
      final polished =
          await engine.polishPrompt('fire magnetic charging animation');
      expect(calls, 1);
      expect(polished, contains('fresh neon charging scene'));
    });

    test('polish instructions demand a fresh version every time', () {
      final image = GeminiApi.buildPolishInstruction('a fox in forest');
      expect(image, contains('FRESH version'));
      expect(image, contains('Never return the input unchanged'));
      final video =
          GeminiApi.buildVideoPolishInstruction('fire magnetic charging');
      expect(video, contains('FRESH version'));
      expect(video, contains('Never return the input unchanged'));
      expect(video, contains('40-80 words'));
    });
  });
}
