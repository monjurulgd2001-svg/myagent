// v164: bulk runs through ONE shared backend session (user order
// 2026-11-22 — "jate o doshta na mone kore"): the bulk opens one
// processSession channel and every line runs its Task inside it,
// instead of a fresh channel per line. Each line is still its OWN
// Task (one task = one video — Gemini's rule); the channel is what
// is shared.
import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mp4_test_helpers.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/task_backend.dart';

GeminiSession _session() => GeminiSession(
      authUser: 0,
      email: 'u0@test',
      at: 'AT-TEST',
      bl: 'boq_test_bl',
      fSid: '12345',
      cookieHeader: 'SAPISID=abc123; __Secure-1PSID=xyz;',
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      apiKeys: const ['AIzaTESTKEY'],
      serverToken: 'CAMS-TEST-TOKEN',
    );

/// v98 — a page transport that is always unreachable, so the client
/// falls back to Dart HTTP deterministically (no real MethodChannel).
class _FailingPageTransport implements BackendTransport {
  @override
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    throw const TaskBackendException('transport', 'no tab');
  }
}

/// v164 — a mock HTTP backend for a shared session: one channel
/// open, a stream that delivers [streamIds] one per poll (like the
/// real long-poll: a conversation id only exists after its task was
/// sent, so a later task's id can never arrive before the task
/// starts), setup/task posts with incrementing ofs, hNvQHb polls
/// answering a video URL per conversation, and downloads returning
/// one byte per video.
class _SharedSessionMock {
  _SharedSessionMock({
    required this.streamIds,
    this.failSetupOfs = -1,
  });

  final List<String> streamIds;
  final int failSetupOfs;

  var channelOpens = 0;
  var chooseServers = 0;
  var streamPolls = 0;
  final ofsValues = <int>[];
  final taskTexts = <String>[];
  final pollCids = <String>[];

  String _streamBody(String id) {
    final payload = base64Encode(utf8.encode('xx${id}yy'));
    final chunk = '[[3,["$payload"]]]';
    return '${chunk.length}\n$chunk\n';
  }

  String _taskTextOf(String body) {
    // The sender URL-encodes STANDARD base64 (base64.encode), so
    // splitQueryString restores the exact base64 string and it must
    // be decoded with the standard alphabet — NOT base64Url (a '+'
    // or '/' in the payload would otherwise corrupt the bytes and
    // pbDecode then fails with "bad protobuf wire type").
    final data = Uri.splitQueryString(body)['req0___data__']!;
    final raw = base64.decode(data);
    final root = pbDecode(raw);
    final f2 = root.first.value as List<int>;
    final outer = pbDecode(f2);
    final inner = pbDecode(outer[1].value as List<int>);
    return utf8.decode(inner.single.value as List<int>);
  }

  http.Client get client => MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('chooseServer')) {
          chooseServers++;
          return http.Response('["GS-TEST",3,null,"1","2"]', 200);
        }
        if (url.contains('processSession') && req.method == 'GET') {
          streamPolls++;
          final id = streamIds[streamPolls - 1 < streamIds.length
              ? streamPolls - 1
              : streamIds.length - 1];
          return http.Response(_streamBody(id), 200);
        }
        if (url.contains('processSession')) {
          final body = req.body;
          if (body.startsWith('count=0')) {
            channelOpens++;
            return http.Response(
                '51\n[[0,["c","SID-TEST","",8,15,30000]]]\n', 200);
          }
          final ofs =
              int.parse(RegExp(r'ofs=(\d+)').firstMatch(body)!.group(1)!);
          ofsValues.add(ofs);
          // A setup message does not decode as a task message, so
          // the decode itself tells setup and task posts apart.
          // (Parity cannot: a failed setup desyncs ofs from the
          // even=setup / odd=task pattern.)
          String? taskText;
          try {
            taskText = _taskTextOf(body);
          } on Object {
            taskText = null;
          }
          if (taskText == null) {
            if (ofs == failSetupOfs) {
              return http.Response('setup failed', 500);
            }
            return http.Response('8\n[1,1,7]\n', 200);
          }
          taskTexts.add(taskText);
          return http.Response('8\n[1,3,7]\n', 200);
        }
        if (url.contains('batchexecute')) {
          final cid =
              RegExp(r'c_[0-9a-f]{16}').firstMatch(req.body)!.group(0)!;
          pollCids.add(cid);
          final videoUrl =
              'https://contribution.usercontent.google.com/download?c=VID${cid[2]}';
          return http.Response(
              ''')]}' [["wrb.fr","hNvQHb",[[["$videoUrl","video/mp4"]]]]]''',
              200);
        }
        if (url.contains('usercontent')) {
          final digit =
              int.parse(req.url.queryParameters['c']!.substring(3));
          return http.Response.bytes([digit], 200);
        }
        return http.Response('not found', 404);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v164: one shared backend session (client)', () {
    const c1 = 'c_1111111111111111';
    const c2 = 'c_2222222222222222';
    const c3 = 'c_3333333333333333';

    TaskBackendClient clientFor(_SharedSessionMock mock) =>
        TaskBackendClient(
          client: mock.client,
          session: _session(),
          pollInterval: const Duration(milliseconds: 10),
          submitTimeout: const Duration(seconds: 30),
          pageTransport: _FailingPageTransport(),
        );

    test('3 tasks on one session open exactly ONE channel', () async {
      final mock = _SharedSessionMock(
          streamIds: const [c1, c2, c3]);
      final backend = clientFor(mock);
      final session = TaskBackendSession(backend);
      addTearDown(() async {
        await session.close();
      });
      await session.open(
          deadline: DateTime.now().add(const Duration(seconds: 60)));
      expect(session.isOpen, isTrue);
      final results = <List<int>>[];
      for (final line in ['first line', 'second line', 'third line']) {
        results.add(await session.runTask(
          'Create a video now — $line',
          onPhase: (_, __) {},
          deadline: DateTime.now().add(const Duration(seconds: 60)),
        ));
      }
      // One channel open for all three tasks — not one per line.
      expect(mock.channelOpens, 1);
      // v101 — chooseServer fires every key candidate at once
      // (here: the one document key + the no-key attempt), so two
      // calls for one channel open.
      expect(mock.chooseServers, 2);
      // Setup+task pairs ride the same channel with incrementing
      // offsets: setup ofs=0, task ofs=1, setup ofs=2, task ofs=3,
      // setup ofs=4, task ofs=5.
      expect(mock.ofsValues, [0, 1, 2, 3, 4, 5]);
      // Each task got its OWN conversation, in order, and its own
      // video — and each task message carried only its own line.
      expect(mock.pollCids, [c1, c2, c3]);
      expect(mock.taskTexts.length, 3);
      expect(mock.taskTexts[0], contains('first line'));
      expect(mock.taskTexts[0], isNot(contains('second line')));
      expect(mock.taskTexts[1], contains('second line'));
      expect(mock.taskTexts[2], contains('third line'));
      expect(results, [
        [1],
        [2],
        [3],
      ]);
      await session.close();
      expect(session.isOpen, isFalse);
    });

    test('a task waits for the NEXT conversation id (slow stream)',
        () async {
      // The stream delivers one id per poll (~5s apart once an id
      // has been seen): each task must wait for the id that arrives
      // AFTER it started, never an old one.
      final mock =
          _SharedSessionMock(streamIds: const [c1, c2, c3]);
      final backend = clientFor(mock);
      final session = TaskBackendSession(backend);
      addTearDown(() async {
        await session.close();
      });
      await session.open(
          deadline: DateTime.now().add(const Duration(seconds: 60)));
      final results = <List<int>>[];
      for (final line in ['first line', 'second line', 'third line']) {
        results.add(await session.runTask(
          'Create a video now — $line',
          onPhase: (_, __) {},
          deadline: DateTime.now().add(const Duration(seconds: 60)),
        ));
      }
      expect(mock.channelOpens, 1);
      expect(mock.pollCids, [c1, c2, c3]);
      expect(results, [
        [1],
        [2],
        [3],
      ]);
    });

    test('a failed task keeps the session alive for the next line',
        () async {
      final mock = _SharedSessionMock(
          streamIds: const [c1, c2, c3], failSetupOfs: 2);
      final backend = clientFor(mock);
      final session = TaskBackendSession(backend);
      addTearDown(() async {
        await session.close();
      });
      await session.open(
          deadline: DateTime.now().add(const Duration(seconds: 60)));
      final first = await session.runTask(
        'Create a video now — first line',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 60)),
      );
      expect(first, [1]);
      // The second line's setup fails (step 'setup', not
      // session-dead): the session must stay open.
      try {
        await session.runTask(
          'Create a video now — second line',
          onPhase: (_, __) {},
          deadline: DateTime.now().add(const Duration(seconds: 60)),
        );
        fail('should throw');
      } on TaskBackendException catch (e) {
        expect(e.step, 'setup');
        expect(e.sessionDead, isFalse);
      }
      expect(session.isOpen, isTrue);
      expect(mock.channelOpens, 1);
      // The third line runs on the SAME session, same channel.
      final third = await session.runTask(
        'Create a video now — third line',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 60)),
      );
      expect(third, [2]);
      expect(mock.channelOpens, 1);
      expect(mock.pollCids, [c1, c2]);
    });

    test('run() still opens one channel per single job', () async {
      final mock = _SharedSessionMock(
          streamIds: const [c1]);
      final backend = clientFor(mock);
      final bytes = await backend.run(
        'phone charging with golden energy',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(bytes, [1]);
      expect(mock.channelOpens, 1);
      expect(mock.ofsValues, [0, 1]);
    });
  });

  group('v164: bulk uses the shared session (engine)', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-bulk164-test-');
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
      TaskBackendSessionOpener? opener,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: const Duration(minutes: 10),
        taskBackendRunner: runner ??
            ((_, {required onPhase, required deadline}) async =>
                minimalMp4(fps: 30, durationSec: 6)),
        taskBackendSessionOpener: opener,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('bulk of 3 lines opens exactly ONE session; the per-line '
        'runner is never called', () async {
      final plainCalls = <String>[];
      var openCount = 0;
      final created = <_FakeSharedSession>[];
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          plainCalls.add(taskText);
          return minimalMp4(fps: 30, durationSec: 6);
        },
        opener: ({required DateTime deadline}) async {
          openCount++;
          final s = _FakeSharedSession();
          created.add(s);
          return s;
        },
      );
      await engine.load();
      await engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems.map((i) => i.status).toList(),
          List.filled(3, BulkAnimationStatus.done));
      expect(engine.videos.length, 3);
      // One session for the whole bulk — and the per-line runner
      // (the v163 path) never ran.
      expect(openCount, 1);
      expect(created.length, 1);
      expect(created.single.runTasks.length, 3);
      expect(created.single.closed, isTrue);
      expect(plainCalls, isEmpty);
      expect(engine.status, contains('3 done'));
    });

    test('a failed line keeps the shared session alive', () async {
      var openCount = 0;
      final created = <_FakeSharedSession>[];
      final engine = engineWith(
        opener: ({required DateTime deadline}) async {
          openCount++;
          final s = _FakeSharedSession(failOn: {'second line'});
          created.add(s);
          return s;
        },
      );
      await engine.load();
      await engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems.map((i) => i.status).toList(), [
        BulkAnimationStatus.done,
        BulkAnimationStatus.failed,
        BulkAnimationStatus.done,
      ]);
      expect(engine.bulkItems[1].note, contains('daily limit sesh'));
      expect(engine.videos.length, 2);
      // No re-open: the same session served all three lines.
      expect(openCount, 1);
      expect(created.length, 1);
      expect(created.single.runTasks.length, 3);
      expect(created.single.closed, isTrue);
    });

    test('a dead session re-opens once and the line is retried',
        () async {
      var openCount = 0;
      final created = <_FakeSharedSession>[];
      final engine = engineWith(
        opener: ({required DateTime deadline}) async {
          openCount++;
          // The first session dies on the second line; the
          // replacement is healthy.
          final s = _FakeSharedSession(
              dieOn: openCount == 1 ? {'second line'} : {});
          created.add(s);
          return s;
        },
      );
      await engine.load();
      await engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems.map((i) => i.status).toList(),
          List.filled(3, BulkAnimationStatus.done));
      expect(engine.videos.length, 3);
      expect(openCount, 2);
      expect(created.length, 2);
      // The dead session was closed; the line was retried on the
      // fresh one, then the third line ran there too.
      expect(created[0].closed, isTrue);
      expect(created[0].runTasks.length, 2);
      expect(created[1].runTasks.length, 2);
      expect(created[1].runTasks[0], contains('second line'));
      expect(created[1].runTasks[1], contains('third line'));
      expect(created[1].closed, isTrue);
    });

    test('cancel mid-bulk closes the session', () async {
      var openCount = 0;
      final created = <_HangingSharedSession>[];
      final engine = engineWith(
        opener: ({required DateTime deadline}) async {
          openCount++;
          final s = _HangingSharedSession();
          created.add(s);
          return s;
        },
      );
      await engine.load();
      final run = engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(engine.bulkItems.first.status, BulkAnimationStatus.running);
      expect(openCount, 1);
      await engine.cancelBulk();
      await run;
      expect(engine.bulkRunning, isFalse);
      expect(created.single.closed, isTrue);
      expect(engine.bulkItems[0].status, BulkAnimationStatus.failed);
      expect(engine.bulkItems[1].status, BulkAnimationStatus.queued);
      expect(engine.bulkItems[2].status, BulkAnimationStatus.queued);
      expect(engine.status, contains('thamano hoyeche'));
    });

    test('a single start() never opens a session', () async {
      var openCount = 0;
      final engine = engineWith(
        opener: ({required DateTime deadline}) async {
          openCount++;
          return _FakeSharedSession();
        },
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue phone',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      // The job runs in the background on the per-line runner.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.videos.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(engine.videos.length, 1);
      expect(openCount, 0);
    });

    test('session open failure falls back to the per-line runner',
        () async {
      final plainCalls = <String>[];
      final engine = engineWith(
        runner: (taskText, {required onPhase, required deadline}) async {
          plainCalls.add(taskText);
          return minimalMp4(fps: 30, durationSec: 6);
        },
        opener: ({required DateTime deadline}) async {
          throw const TaskBackendException(
              'channel', 'Channel khola jayni: HTTP 403.');
        },
      );
      await engine.load();
      await engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems.map((i) => i.status).toList(),
          List.filled(3, BulkAnimationStatus.done));
      expect(engine.videos.length, 3);
      expect(plainCalls.length, 3);
      expect(engine.errorLog.any((l) => l.contains('session kholeni')),
          isTrue);
    });
  });
}

/// v164 — a fake shared session for engine tests: records every
/// task, fails [failOn] lines with a per-task error (session stays
/// alive) and [dieOn] lines with a session-dead error.
class _FakeSharedSession implements SharedBackendSession {
  _FakeSharedSession({this.failOn = const {}, this.dieOn = const {}});

  final Set<String> failOn;
  final Set<String> dieOn;
  final runTasks = <String>[];
  var closed = false;
  @override
  var isOpen = true;

  @override
  Future<Uint8List> runTask(String taskText,
      {required void Function(String phase, String message) onPhase,
      required DateTime deadline}) async {
    runTasks.add(taskText);
    for (final needle in dieOn) {
      if (taskText.contains(needle)) {
        isOpen = false;
        throw const TaskBackendException('transport', 'page gone',
            sessionDead: true);
      }
    }
    for (final needle in failOn) {
      if (taskText.contains(needle)) {
        throw const TaskBackendException('creating', 'daily limit sesh');
      }
    }
    return minimalMp4(fps: 30, durationSec: 6);
  }

  @override
  Future<void> close() async {
    closed = true;
    isOpen = false;
  }
}

/// v164 — a shared session whose task never finishes, so a test can
/// cancel mid-bulk and prove the session is closed.
class _HangingSharedSession implements SharedBackendSession {
  var closed = false;
  @override
  var isOpen = true;

  @override
  Future<Uint8List> runTask(String taskText,
      {required void Function(String phase, String message) onPhase,
      required DateTime deadline}) =>
      Completer<Uint8List>().future;

  @override
  Future<void> close() async {
    closed = true;
    isOpen = false;
  }
}
