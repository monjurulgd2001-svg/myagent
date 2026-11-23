// v151 — stale-event guard, Cancel, driver-first mode, and the
// cancel signal the engine sends to the driver side when it gives up
// (live 2026-11-22: a silent driver job sat 21080s; a late progress
// event used to leave `busy` stuck forever).
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

Future<Uint8List> _failingRunner(
  String _, {
  required void Function(String phase, String message) onPhase,
  required DateTime deadline,
}) =>
    throw const TaskBackendException('channel', 'no thread');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v151', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v151-');
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
      VideoCancelRunner? cancel,
      bool backendFirst = true,
      Duration? driverHandoverDeadline,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        driverHandoverDeadline:
            driverHandoverDeadline ?? const Duration(minutes: 3),
        taskBackendRunner: runner,
        videoDriverRunner: driver,
        videoCancelRunner: cancel,
        backendFirst: backendFirst,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('late driver progress after the job failed does not leave busy stuck',
        () async {
      final cancelled = <String>[];
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async =>
            true,
        cancel: (id) async => cancelled.add(id),
        driverHandoverDeadline: const Duration(milliseconds: 400),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      final jobId = engine.currentJobId;
      await Future.delayed(const Duration(seconds: 2));
      expect(engine.phase, AnimationPhase.error);
      expect(engine.currentJobId, isEmpty);
      // The engine told the driver side to drop the job.
      expect(cancelled, [jobId]);
      // A late progress event for the dead job must be ignored.
      expect(
          await engine.handleRequest(_videoReq('video_progress', {
            'jobId': jobId,
            'phase': 'creating',
            'message': 'late',
          })),
          isFalse);
      expect(engine.phase, AnimationPhase.error);
      expect(engine.busy, isFalse);
    });

    test('cancelJob returns to idle, tells the driver, ignores late events',
        () async {
      final cancelled = <String>[];
      final engine = engineWith(
        runner: _failingRunner,
        driver: ({required prompt, required modelId, required jobId}) async =>
            true,
        cancel: (id) async => cancelled.add(id),
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'fire magnetic charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      final jobId = engine.currentJobId;
      await Future.delayed(const Duration(milliseconds: 200));
      expect(engine.busy, isTrue);
      await engine.cancelJob();
      expect(engine.busy, isFalse);
      expect(engine.phase, AnimationPhase.idle);
      expect(engine.currentJobId, isEmpty);
      expect(cancelled, [jobId]);
      expect(engine.status, contains('Cancel'));
      // Even a finished video for a cancelled job is not saved.
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': jobId,
            'dataUrl': 'data:video/mp4;base64,${base64Encode([1, 2, 3])}',
          })),
          isFalse);
      expect(engine.videos, isEmpty);
      // Generate works again at once.
      expect(
          await engine.start(
              rawPrompt: 'blue ocean charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
    });

    test('backendFirst: false goes straight to the driver', () async {
      var backendCalls = 0;
      final driverJobs = <String>[];
      final engine = engineWith(
        runner: (String _,
            {required void Function(String, String) onPhase,
            required DateTime deadline}) async {
          backendCalls++;
          throw const TaskBackendException('channel', 'x');
        },
        driver: ({required prompt, required modelId, required jobId}) async {
          driverJobs.add(jobId);
          return true;
        },
        backendFirst: false,
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'golden phone charging animation',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(backendCalls, 0);
      expect(driverJobs, [engine.currentJobId]);
    });
  });
}
