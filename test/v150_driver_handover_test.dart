// v150 — driver handover deadline: a driver that never reports a
// phase fails the job at 3 min with step driver_handover (live
// 2026-11-22 01:48→07:39 the job sat silent 21080s); the stale
// backend phase is reset on takeover so the timeout never again
// says "video banacche" for a job the driver never touched; a
// queued driver (Kotlin posted=false) is logged as waiting for port.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/task_backend.dart';

GeckoBrowserRequest _videoReq(String action, Map<String, dynamic> data) =>
    GeckoBrowserRequest(action, const [], 'https://gemini.google.com/app',
        'Gemini',
        data: data);

const _channelDetail =
    'Conversation id asheni — channel khuleche kintu Gemini kono task '
    'thread banayni. (stream: 8 poll, sesh HTTP 200, 54 byte.)';

Future<Uint8List> _failingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    throw const TaskBackendException('channel', _channelDetail);

/// Backend that reports 'creating' (Task thread toiri hocche…),
/// then fails — the live 2026-11-22 shape: the phase must NOT
/// survive into the driver-owned job.
Future<Uint8List> _creatingThenFailingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) async {
  onPhase('creating', 'Task thread toiri hocche…');
  throw const TaskBackendException('channel', _channelDetail);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v150: driver handover deadline', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v150-');
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
      Duration? driverHandoverDeadline,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: watchdogQuiet ?? const Duration(minutes: 10),
        driverHandoverDeadline:
            driverHandoverDeadline ?? const Duration(minutes: 3),
        taskBackendRunner: runner,
        videoDriverRunner: driver,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('handover deadline fails a silent driver with step driver_handover',
        () async {
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          return true;
        },
        driverHandoverDeadline: const Duration(milliseconds: 500),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('driver_handover'));
      expect(engine.status, contains('page theke kono khobor asheni'));
      // The stale backend phase must never be quoted for this job.
      expect(engine.status, isNot(contains('video banacche')));
      // The handover itself was logged (time + jobId).
      expect(
          engine.errorLog.any((l) => l.contains('Driver-e job dilam')),
          isTrue);
      expect(
          engine.errorLog.any((l) => l.contains('driver_handover')),
          isTrue);
    });

    test('stale backend phase is reset — timeout names the driver, '
        'never video banacche', () async {
      final engine = engineWith(
        runner: _creatingThenFailingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          return true;
        },
        // Short quiet window, long handover deadline: the general
        // quiet check fires first and must use the timeout message —
        // which, for a driver-owned job with no phase, names the
        // driver instead of the backend's old 'creating' step.
        watchdogQuiet: const Duration(milliseconds: 200),
        driverHandoverDeadline: const Duration(minutes: 10),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status,
          contains('driver-e job dilam kintu page theke kono khobor asheni'));
      expect(engine.status, isNot(contains('video banacche')));
    });

    test('driver progress within the deadline prevents the failure',
        () async {
      late final AnimationEngine engine;
      engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          Future.delayed(const Duration(milliseconds: 100), () {
            unawaited(engine.handleRequest(_videoReq('video_progress', {
              'jobId': engine.currentJobId,
              'phase': 'opening',
              'message': 'Gemini khulche',
            })));
          });
          return true;
        },
        driverHandoverDeadline: const Duration(milliseconds: 500),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(engine.phase, isNot(AnimationPhase.error));
      expect(engine.currentJobId, isNotEmpty);
      expect(
          engine.errorLog.any((l) => l.contains('driver_handover')),
          isFalse);
      // The job still finishes normally when the driver delivers.
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

    test('queued driver is logged as waiting for port', () async {
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async {
          // Kotlin posted=false: the headless port was not connected
          // yet, so the job was queued on the native side.
          return false;
        },
        driverHandoverDeadline: const Duration(milliseconds: 500),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(
          engine.errorLog.any((l) => l.contains('waiting for port')),
          isTrue);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.status, contains('driver_handover'));
    });
  });
}
