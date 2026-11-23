// v167 — all-black cover candidates fix.
//
// Live 2026-11-23 01:30 the v166 picker showed FIVE "ondhokar"
// candidates for "Icy Energy Battery" — a BRIGHT icy/frost video
// (10s, 1620x2880, 60fps, 9.2 MB), "Soft frost tones". The picker
// UI itself worked (row renders, pick works), but every candidate
// frame was black. Root cause, code-verified: the v162 luminance
// gate was never applied to the candidates path —
// captureCoverCandidates accepted the FIRST path that returned
// any frame, luma measured but never used to reject, so a path
// returning black JPEGs won and the other paths never ran. The
// "ondhokar" labels prove the bytes themselves are black (luma
// < 10 measured from decoded pixels), not a display bug.
//
// v167:
//  (1) per-path gate on the candidates run — a path whose frames
//      are ALL dark is treated as failed and the next path is
//      tried; only when no path has a passing frame is the
//      brightest set returned (v162 semantics).
//  (2) VideoCoverBridge.kt mirrors the panel's recipe exactly —
//      temp file WITH the real extension so the extractor can
//      sniff the container, duration read + points coerced,
//      0ms grab as the last resort. The old code called
//      setDataSource() on the original path directly — the one
//      difference from the proven panel capture on this device.
//  (3) both capture scripts sample the drawn canvas before
//      returning it: a blank canvas is a failure, not a frame
//      (plus a HAVE_FUTURE_DATA wait after the seek).
//  (4) diagnostics: the candidates result carries a per-path
//      diagnostic, an empty/all-dark result is written to the
//      Error log, and the picker shows the note under the row.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/video_cover.dart';

void main() {
  AnimationVideo video({
    required String id,
    double durationSec = 10,
    String localPath = '/tmp/anim_v167.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'icy energy battery',
        prompt: 'icy energy battery',
        modelId: 'neon',
        styleId: 'calm',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v167.mp4',
        width: 1620,
        height: 2880,
        fps: 60,
        durationSec: durationSec,
        createdAt: DateTime.now(),
        metadata: SetMetadata(
          title: 'Icy Energy Battery',
          description: 'Soft frost tones and steady motion.',
          tags: ['battery', 'snowflakes'],
          category: 'TECHNOLOGY',
          generatedAtMs: 1,
        ),
      );

  /// A small solid-gray JPEG — the fake capture result. Small on
  /// purpose (160x288): the engine measures EVERY candidate
  /// frame, and a full 1620x2880 decode per try would make the
  /// suite crawl; the meter does not care about size.
  Uint8List grayJpeg(int gray) {
    final image = img.Image(width: 160, height: 288);
    img.fill(image, color: img.ColorRgb8(gray, gray, gray));
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  const times = [800, 2800, 5000, 7200, 9200];

  group('v167 candidate gate — a dark-only path is skipped', () {
    test('all-dark retriever → plugin bright frames win', () async {
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async =>
            [for (final _ in pointsMs) grayJpeg(0)],
        pluginCapture: (path, {int timeMs = 1000}) async => grayJpeg(180),
      );
      expect(result.frames.length, 5);
      expect(result.frames.every((c) => !c.isDark), isTrue);
      expect(result.frames.every((c) => c.luma == 180), isTrue);
      expect(result.diagnostic, contains('retriever'));
      expect(result.diagnostic, contains('ondhokar'));
    });

    test('retriever returns nulls → next path tried, not black frames',
        () async {
      var pluginCalls = 0;
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async =>
            [for (final _ in pointsMs) null],
        pluginCapture: (path, {int timeMs = 1000}) async {
          pluginCalls++;
          return grayJpeg(200);
        },
      );
      expect(pluginCalls, 5);
      expect(result.frames.length, 5);
      expect(result.frames.every((c) => !c.isDark), isTrue);
      expect(result.diagnostic, contains('retriever: no frame'));
    });

    test('all paths dark → brightest set returned + diagnostic',
        () async {
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async =>
            [for (final _ in pointsMs) grayJpeg(0)],
        pluginCapture: (path, {int timeMs = 1000}) async => grayJpeg(5),
        browserCapture: (path, {int timeMs = 1000}) async => grayJpeg(8),
        chromeCapture: (path, {int timeMs = 1000}) async => null,
      );
      expect(result.frames.length, 5);
      expect(result.frames.every((c) => c.luma == 8), isTrue);
      expect(result.allDark, isTrue);
      expect(result.diagnostic, contains('retriever'));
      expect(result.diagnostic, contains('plugin'));
      expect(result.diagnostic, contains('browser'));
      expect(result.diagnostic, contains('chrome: no frame'));
    });

    test('all paths null → empty frames + diagnostic names each path',
        () async {
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async =>
            [for (final _ in pointsMs) null],
        pluginCapture: (path, {int timeMs = 1000}) async => null,
        browserCapture: (path, {int timeMs = 1000}) async => null,
        chromeCapture: (path, {int timeMs = 1000}) async => null,
      );
      expect(result.frames, isEmpty);
      expect(result.allDark, isFalse);
      expect(result.diagnostic,
          'retriever: no frame; plugin: no frame; browser: no frame; chrome: no frame');
    });

    test('mixed path is accepted with all its frames', () async {
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async => [
          grayJpeg(0),
          grayJpeg(200),
          grayJpeg(0),
          grayJpeg(0),
          grayJpeg(0),
        ],
      );
      expect(result.frames.length, 5);
      expect(result.frames[1].luma, 200);
      expect(result.frames.where((c) => c.isDark).length, 4);
      expect(result.diagnostic, contains('retriever: 4 dark'));
    });

    test('unmeasurable frame counts as passing', () async {
      final result = await captureCoverCandidates(
        '/tmp/anim_v167.mp4',
        timesMs: times,
        retrieverFrames: (path, {required List<int> pointsMs}) async =>
            [for (final _ in pointsMs) Uint8List.fromList([1, 2, 3])],
      );
      expect(result.frames.length, 5);
      expect(result.frames.every((c) => c.luma == null), isTrue);
      expect(result.allDark, isFalse);
      expect(result.diagnostic, isEmpty);
    });
  });

  group('v167 bridge mirrors the panel recipe', () {
    test('VideoCoverBridge uses a temp file with the real extension',
        () {
      final src = File(
              'android/app/src/main/kotlin/com/geminihd/studio/VideoCoverBridge.kt')
          .readAsStringSync();
      expect(src, contains('createTempFile'));
      expect(src, contains('context.cacheDir'));
      expect(src, contains('METADATA_KEY_DURATION'));
      expect(src, contains('grabFrame(mr, 0L)'));
      expect(src, contains('tmp.delete()'));
      expect(src, contains('setDataSource(tmp.absolutePath)'));
    });

    test('MainActivity registers the video_cover channel', () {
      final src = File(
              'android/app/src/main/kotlin/com/geminihd/studio/MainActivity.kt')
          .readAsStringSync();
      expect(src, contains('com.geminihd.studio/video_cover'));
      expect(src, contains('"captureCoverFrames"'));
    });
  });

  group('v167 blank canvas is a failure, not a frame', () {
    test('chromeCoverScript samples the canvas and rejects black',
        () {
      final s = chromeCoverScript(2.0);
      expect(s, contains('readyState >= 3'));
      expect(s, contains('getImageData'));
      expect(s, contains("if (blank) return '';"));
      // The draw still happens at full native size.
      expect(s, contains('c.width = v.videoWidth'));
    });

    test('content.js onCapture samples the canvas and rejects black',
        () {
      final src = File('android/app/src/main/assets/ais_cookies/content.js')
          .readAsStringSync();
      expect(src, contains('readyState >= 3'));
      expect(src, contains('blank canvas'));
      expect(src, contains('getImageData'));
    });
  });

  group('v167 diagnostics reach the Error log', () {
    test('all-dark candidates are logged with the diagnostic', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => CoverCandidatesResult(frames: [
          for (final t in times)
            CoverCandidate(timeMs: t, bytes: grayJpeg(0), luma: 0),
        ], diagnostic: 'retriever: 5-ti frame-i ondhokar'),
      );
      addTearDown(engine.dispose);
      final result = await engine.coverCandidates(video(id: 'v1'));
      expect(result.allDark, isTrue);
      expect(engine.errorLog.last, contains('Cover frame:'));
      expect(engine.errorLog.last, contains('retriever'));
    });

    test('empty candidates are logged too', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => const CoverCandidatesResult(
            frames: [],
            diagnostic: 'retriever: no frame; plugin: no frame'),
      );
      addTearDown(engine.dispose);
      final result = await engine.coverCandidates(video(id: 'v1'));
      expect(result.frames, isEmpty);
      expect(engine.errorLog.last, contains('retriever: no frame'));
    });

    test('without a fetcher → empty frames, no log entry', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      final result = await engine.coverCandidates(video(id: 'v1'));
      expect(result.frames, isEmpty);
      expect(engine.errorLog, isEmpty);
    });
  });

  group('v167 picker shows the all-dark note', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<void> pumpSection(
      WidgetTester tester,
      AnimationEngine engine,
    ) async {
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
    }

    Future<void> switchToList(WidgetTester tester) async {
      final fewer = find.byTooltip('Fewer columns (larger cards)');
      await tester.ensureVisible(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('all-dark candidates: thumbs still shown + note',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => CoverCandidatesResult(frames: [
          for (final t in times)
            CoverCandidate(timeMs: t, bytes: grayJpeg(0), luma: 0),
        ], diagnostic: 'retriever: 5-ti frame-i ondhokar'),
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      await pumpSection(tester, engine);
      await switchToList(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('coverThumb-v1-5000')),
          findsOneWidget);
      expect(find.textContaining('Sob frame-i ondhokar'), findsOneWidget);
      // The diagnostic also lands in the Error log (same text
      // twice on the screen), so this matches two widgets.
      expect(find.textContaining('retriever'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty candidates: error names the failed paths',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => const CoverCandidatesResult(
            frames: [],
            diagnostic: 'retriever: no frame; plugin: no frame'),
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      await pumpSection(tester, engine);
      await switchToList(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Cover frame pelam na'), findsOneWidget);
      // The diagnostic also lands in the Error log (same text
      // twice on the screen), so this matches two widgets.
      expect(find.textContaining('retriever: no frame'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
