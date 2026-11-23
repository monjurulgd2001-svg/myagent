// v163: bulk animation in the SAME prompt box (user correction
// 2026-11-22 — no separate box): several lines in the Animation
// prompt field = one animation per line, run one by one through
// the existing engine. One line = one animation, as before.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mp4_test_helpers.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:gemini_hd_studio/task_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v163: bulk prompt parsing (same box, line by line)', () {
    test('trims, skips empty lines, dedupes keeping first order', () {
      expect(
          parseBulkAnimationPrompts(
              '  neon blue phone  \n\nmolten gold tree\nneon blue phone\n'
              '  \ncrimson pine\n'),
          ['neon blue phone', 'molten gold tree', 'crimson pine']);
    });

    test('single line stays a single prompt', () {
      expect(parseBulkAnimationPrompts('  neon blue phone  '),
          ['neon blue phone']);
    });

    test('all empty / blank lines parse to nothing', () {
      expect(parseBulkAnimationPrompts('  \n\n   \n'), isEmpty);
      expect(parseBulkAnimationPrompts(''), isEmpty);
    });

    test('a duplicate with different spacing is still a duplicate', () {
      expect(
          parseBulkAnimationPrompts(
              'neon blue phone\n  neon blue phone  \ncrimson pine'),
          ['neon blue phone', 'crimson pine']);
    });
  });

  group('v163: bulk queue in the engine', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-bulk-test-');
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
      Duration? watchdogQuiet,
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: watchdogQuiet ?? const Duration(minutes: 10),
        taskBackendRunner: runner ??
            ((_, {required onPhase, required deadline}) async =>
                minimalMp4(fps: 30, durationSec: 6)),
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('3 lines -> 3 videos, in order, all done', () async {
      // v163 clarification (user 2026-11-22): "Gemini-teo jeno
      // oivabe requests jay" — each line is its OWN separate
      // request to Gemini (its own Task prompt / generation job),
      // sent one after another. The lines are NEVER combined into
      // one prompt or one request: capture every backend call and
      // assert each carries only its own line.
      final calls = <String>[];
      final engine = engineWith(
        runner: (taskText,
            {required onPhase, required deadline}) async {
          calls.add(taskText);
          return minimalMp4(fps: 30, durationSec: 6);
        },
      );
      await engine.load();
      await engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkRunning, isFalse);
      expect(engine.bulkItems.map((i) => i.status).toList(),
          List.filled(3, BulkAnimationStatus.done));
      expect(engine.bulkItems.map((i) => i.prompt).toList(),
          ['first line', 'second line', 'third line']);
      // 3 lines = 3 separate requests, in order, each carrying
      // ONLY its own line — never a combined prompt.
      expect(calls.length, 3);
      expect(calls[0], contains('first line'));
      expect(calls[0], isNot(contains('second line')));
      expect(calls[0], isNot(contains('third line')));
      expect(calls[1], contains('second line'));
      expect(calls[1], isNot(contains('first line')));
      expect(calls[1], isNot(contains('third line')));
      expect(calls[2], contains('third line'));
      expect(calls[2], isNot(contains('first line')));
      expect(calls[2], isNot(contains('second line')));
      // Videos are prepended (newest first), so the list reads
      // third -> first.
      expect(engine.videos.length, 3);
      expect(engine.videos.map((v) => v.prompt).toList(),
          ['third line', 'second line', 'first line']);
      expect(engine.status, contains('Bulk sesh'));
      expect(engine.status, contains('3 done'));
    });

    test('one failure does not stop the rest', () async {
      final engine = engineWith(
        runner: (taskText,
            {required onPhase, required deadline}) async {
          if (taskText.contains('second line')) {
            throw const TaskBackendException(
                'creating', 'daily limit sesh');
          }
          return minimalMp4(fps: 30, durationSec: 6);
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
      expect(engine.errorLog.any((l) => l.contains('second line')),
          isTrue);
      expect(engine.status, contains('2 done'));
      expect(engine.status, contains('1 failed'));
    });

    test('a copyright-risk line is skipped, the rest still run',
        () async {
      final engine = engineWith();
      await engine.load();
      await engine.startBulk(
          prompts: const [
            'neon blue phone',
            'iphone charging',
            'molten gold phone'
          ],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems.map((i) => i.status).toList(), [
        BulkAnimationStatus.done,
        BulkAnimationStatus.skipped,
        BulkAnimationStatus.done,
      ]);
      expect(engine.bulkItems[1].note, contains('iphone'));
      expect(engine.videos.length, 2);
      expect(engine.status, contains('1 skipped'));
    });

    test('all lines guarded -> nothing runs, status says so', () async {
      final engine = engineWith();
      await engine.load();
      await engine.startBulk(
          prompts: const ['iphone charging', 'nike shoe'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkRunning, isFalse);
      expect(engine.videos, isEmpty);
      expect(engine.bulkItems.every(
          (i) => i.status == BulkAnimationStatus.skipped), isTrue);
      expect(engine.status, contains('shob skip'));
    });

    test('startBulk refuses while a single job is busy', () async {
      final engine = engineWith(
        runner: (_, {required onPhase, required deadline}) =>
            Completer<Uint8List>().future,
      );
      await engine.load();
      expect(
          await engine.start(
              rawPrompt: 'neon blue phone',
              modelId: 'neon',
              signedIn: true),
          isTrue);
      await engine.startBulk(
          prompts: const ['a line', 'another line'],
          modelId: 'neon',
          signedIn: true);
      expect(engine.bulkItems, isEmpty);
      expect(engine.bulkRunning, isFalse);
      expect(engine.status, contains('cholche'));
    });

    test('startBulk refuses while a bulk run is already going',
        () async {
      final engine = engineWith(
        runner: (_, {required onPhase, required deadline}) =>
            Completer<Uint8List>().future,
      );
      await engine.load();
      final run = engine.startBulk(
          prompts: const ['first line', 'second line'],
          modelId: 'neon',
          signedIn: true);
      // The first line's job is hanging — a second startBulk must
      // not replace the queue.
      await Future.delayed(const Duration(milliseconds: 100));
      expect(engine.bulkRunning, isTrue);
      await engine.startBulk(
          prompts: const ['other line'], modelId: 'neon', signedIn: true);
      expect(engine.bulkItems.map((i) => i.prompt).toList(),
          ['first line', 'second line']);
      expect(engine.status, contains('Bulk cholche'));
      await engine.cancelBulk();
      await run;
      expect(engine.bulkRunning, isFalse);
    });

    test('cancelBulk stops the queue; unrun lines stay queued',
        () async {
      final engine = engineWith(
        runner: (_, {required onPhase, required deadline}) =>
            Completer<Uint8List>().future,
      );
      await engine.load();
      final run = engine.startBulk(
          prompts: const ['first line', 'second line', 'third line'],
          modelId: 'neon',
          signedIn: true);
      await Future.delayed(const Duration(milliseconds: 100));
      expect(engine.bulkItems.first.status, BulkAnimationStatus.running);
      await engine.cancelBulk();
      await run;
      expect(engine.bulkRunning, isFalse);
      // The cancelled line never finished; the rest never started.
      expect(engine.bulkItems[0].status, BulkAnimationStatus.failed);
      expect(engine.bulkItems[0].note, contains('Cancel'));
      expect(engine.bulkItems[1].status, BulkAnimationStatus.queued);
      expect(engine.bulkItems[2].status, BulkAnimationStatus.queued);
      expect(engine.videos, isEmpty);
      expect(engine.status, contains('thamano hoyeche'));
    });

    test('signed-out startBulk refuses up front', () async {
      final engine = engineWith();
      await engine.load();
      await engine.startBulk(
          prompts: const ['a line'], modelId: 'neon', signedIn: false);
      expect(engine.bulkItems, isEmpty);
      expect(engine.status, contains('sign in'));
    });
  });

  group('v163: the existing prompt box drives bulk (widget)', () {
    Future<void> pumpPhone(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
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

    testWidgets('multi-line box shows the line count + Generate N',
        (tester) async {
      await pumpPhone(tester);
      final field = find.byKey(const ValueKey('animPromptField'));
      expect(field, findsOneWidget);
      await tester.ensureVisible(field);
      await tester.enterText(
          field,
          'neon blue phone\n\nmolten gold tree\nneon blue phone\n'
          'crimson pine');
      await tester.pump(const Duration(milliseconds: 200));
      // Empty line + duplicate dropped: 3 lines.
      expect(find.textContaining('3 line'), findsOneWidget);
      expect(find.text('Generate 3 animations'), findsOneWidget);
      // Back to one line: the button reads as before.
      await tester.enterText(field, 'neon blue phone');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Generate animation'), findsOneWidget);
      expect(find.textContaining('3 line'), findsNothing);
      // Clear empties the box (text stays until this tap).
      await tester.tap(find.byKey(const ValueKey('animPromptClear')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
          tester
              .widget<TextField>(field)
              .controller
              ?.text,
          isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('seeded per-line list renders queued/running/done/failed',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      engine.bulkItems = [
        BulkAnimationItem(
            id: 'bulk_0',
            prompt: 'neon blue phone',
            status: BulkAnimationStatus.done),
        BulkAnimationItem(
            id: 'bulk_1',
            prompt: 'molten gold tree',
            status: BulkAnimationStatus.running),
        BulkAnimationItem(
            id: 'bulk_2',
            prompt: 'crimson pine',
            status: BulkAnimationStatus.queued),
        BulkAnimationItem(
            id: 'bulk_3',
            prompt: 'iphone charging',
            status: BulkAnimationStatus.skipped,
            note: 'Copyright risk: "iphone" — eta brand thakle strike.'),
        BulkAnimationItem(
            id: 'bulk_4',
            prompt: 'broken line',
            status: BulkAnimationStatus.failed,
            note: 'daily limit sesh'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimationSection(
              engine: engine,
              signedIn: true,
              wide: false,
              onGenerate: (_, __) async {},
              onPlay: (_) {},
              onDelete: (_) {},
              onExportZip: () {},
              onMetadata: (_) async {},
              onUploadToPanel: (_) async {},
              onUploadAllToPanel: () async {},
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('animBulkList')), findsOneWidget);
      expect(find.text('Bulk — 5 line'), findsOneWidget);
      for (final id in ['bulk_0', 'bulk_1', 'bulk_2', 'bulk_3', 'bulk_4']) {
        expect(find.byKey(ValueKey('animBulkItem-$id')), findsOneWidget);
      }
      expect(find.text('neon blue phone'), findsOneWidget);
      expect(find.text('molten gold tree'), findsOneWidget);
      expect(find.textContaining('Copyright risk'), findsOneWidget);
      expect(find.textContaining('daily limit sesh'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
