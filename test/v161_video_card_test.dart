// v161 — TWO-PART video card + AUTO AI metadata on video-ready.
//
// (1) The list card is split in two (user order 2026-11-22: the old
// card "কেমন বিচ্ছিরি হয়ে গেছে"): left = ONLY the video preview
// (small 9:16 pane, tap opens the device preview — no text overlaid
// on the frame), right = the metadata, neatly arranged in the
// image-card-style block. Spec line, Panel chips and action icons
// move below the split — nothing is dropped.
// (2) A finished video fetches its own AI metadata automatically
// ("ভিডিও জেনারেশন শেষ হলে অটো মেটা ডেটা নেবে"). A metadata
// failure never blocks the video: the card shows a Banglish note +
// manual retry, and the failure is persisted on the video.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/models.dart';

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

AnimationVideo _video({
  required String id,
  SetMetadata? metadata,
  bool metadataFailed = false,
  String thumbUrl = '',
}) =>
    AnimationVideo(
      id: id,
      title: 'copper pine energy surge',
      prompt: 'copper pine energy surge',
      modelId: 'neon',
      styleId: 'cinematic',
      requestedDurationSec: 10,
      localPath: '/tmp/anim_v161.mp4',
      fileName: 'anim_v161.mp4',
      width: 1620,
      height: 2880,
      fps: 60,
      durationSec: 10,
      sizeBytes: 9200000,
      thumbUrl: thumbUrl,
      metadataFailed: metadataFailed,
      createdAt: DateTime.now(),
      metadata: metadata,
    );

SetMetadata _longMeta() => SetMetadata(
      title: 'Copper Pine Energy Surge',
      description:
          'A copper pine energy surge flows through the ancient tree trunk, '
          'golden light rising with the morning mist over the forest.',
      tags: ['copper', 'pine', 'energy', 'forest', 'golden', 'morning'],
      category: 'DESIGNS',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v161: two-part video card', () {
    Future<void> pumpSection(
      WidgetTester tester,
      AnimationEngine engine, {
      void Function(AnimationVideo video)? onPlay,
      Future<void> Function(AnimationVideo video)? onMetadata,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimationSection(
              engine: engine,
              signedIn: true,
              wide: false,
              onGenerate: (_, __) async {},
              onPlay: onPlay ?? (_) {},
              onDelete: (_) {},
              onExportZip: () {},
              onMetadata: onMetadata ?? (_) async {},
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
      // Grid is 3 columns by default; two taps on 'Fewer columns'
      // take it to 1 column (list view).
      final fewer = find.byTooltip('Fewer columns (larger cards)');
      await tester.ensureVisible(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
    }

    AnimationEngine engineWith(List<AnimationVideo> vs) {
      final engine = AnimationEngine();
      engine.videos = vs;
      return engine;
    }

    testWidgets(
        'preview pane holds only the preview, metadata on the other side',
        (tester) async {
      await pumpSection(
          tester, engineWith([_video(id: 'v1', metadata: _longMeta())]));
      await switchToList(tester);
      final pane = find.byKey(const ValueKey('animPreview-v1'));
      expect(pane, findsOneWidget);
      // The pane is a small 9:16 frame — and NOTHING textual sits
      // inside it (v159 rule: no text overlaid on the video).
      final size = tester.getSize(pane);
      expect(size.width, 84);
      expect(size.height / size.width, closeTo(16 / 9, 0.01));
      expect(
          find.descendant(of: pane, matching: find.byType(Text)),
          findsNothing);
      // The metadata side sits to the RIGHT of the pane, same row.
      final meta = find.byKey(const ValueKey('animMetaBlock-v1'));
      expect(meta, findsOneWidget);
      expect(tester.getTopLeft(pane).dx < tester.getTopLeft(meta).dx,
          isTrue);
      expect(tester.getTopLeft(pane).dy,
          closeTo(tester.getTopLeft(meta).dy, 4));
      // The image-card-style block: AI title, pill, source line,
      // description, tags, toggle.
      expect(find.text('Copper Pine Energy Surge'), findsOneWidget);
      expect(find.text('DESIGNS'), findsOneWidget);
      expect(find.text('gemini-web (cookie)'), findsOneWidget);
      expect(find.textContaining('copper pine energy surge flows'),
          findsOneWidget);
      expect(find.text('#copper'), findsOneWidget);
      expect(find.text('Aro dekho'), findsOneWidget);
      // Nothing dropped: spec line, Panel chips, all four actions.
      // (The section header also reads 'Charging Animation', so
      // the chip texts are scoped to their chip keys.)
      expect(find.textContaining('60fps'), findsWidgets);
      expect(
          find.descendant(
              of: find.byKey(
                  const ValueKey('animPanelType-charging-v1')),
              matching: find.text('Charging Animation')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('animPanelType-live-v1')),
              matching: find.text('Live Wallpaper')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('animMeta-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('animUpload-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('animDelete-v1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no metadata: prompt title + spec, no block, no note',
        (tester) async {
      await pumpSection(tester, engineWith([_video(id: 'v1')]));
      await switchToList(tester);
      expect(find.byKey(const ValueKey('animMetaBlock-v1')), findsNothing);
      expect(find.text('copper pine energy surge'), findsOneWidget);
      expect(find.textContaining('60fps'), findsWidgets);
      expect(find.text('AI Metadata hoyni — abar try koro.'), findsNothing);
      expect(find.byKey(const ValueKey('animMetaRetry-v1')), findsNothing);
      // The manual sparkle is still there (actions row).
      expect(find.byKey(const ValueKey('animMeta-v1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'metadata failed: Banglish note + manual retry; tap retries',
        (tester) async {
      var calls = 0;
      await pumpSection(
        tester,
        engineWith([_video(id: 'v1', metadataFailed: true)]),
        onMetadata: (_) async {
          calls++;
        },
      );
      await switchToList(tester);
      expect(find.text('AI Metadata hoyni — abar try koro.'),
          findsOneWidget);
      final retry = find.byKey(const ValueKey('animMetaRetry-v1'));
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('auto-fetch in flight shows "banacche…" on the card',
        (tester) async {
      final engine = engineWith([_video(id: 'v1')]);
      engine.busyVideoId = 'v1';
      engine.busyAction = 'metadata';
      await pumpSection(tester, engine);
      await switchToList(tester);
      expect(find.text('AI Metadata banacche…'), findsOneWidget);
      expect(find.byKey(const ValueKey('animMetaBlock-v1')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the preview pane opens the preview',
        (tester) async {
      var played = 0;
      await pumpSection(
        tester,
        engineWith([_video(id: 'v1', metadata: _longMeta())]),
        onPlay: (_) {
          played++;
        },
      );
      await switchToList(tester);
      await tester.tap(find.byKey(const ValueKey('animPlay-v1')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(played, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('v161: auto AI metadata on video-ready', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-v161-');
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
    }) {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        watchdogQuiet: const Duration(minutes: 10),
        taskBackendRunner: _hangingRunner,
        metadataGenerator: metadataGenerator,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    Future<AnimationEngine> startedEngine({
      VideoMetadataGenerator? metadataGenerator,
    }) async {
      final engine = engineWith(metadataGenerator: metadataGenerator);
      await engine.load();
      await engine.start(
          rawPrompt: 'copper pine energy surge',
          modelId: 'neon',
          signedIn: true);
      return engine;
    }

    Future<void> finishVideo(AnimationEngine engine, {int fps = 60}) async {
      final mp4 = minimalMp4(fps: fps, durationSec: 10);
      expect(
          await engine.handleRequest(_videoReq('video_ready', {
            'jobId': engine.currentJobId,
            'dataUrl': 'data:video/mp4;base64,${base64Encode(mp4)}',
            'durationSec': 10,
          })),
          isTrue);
    }

    test('video-ready auto-fetches metadata and attaches it', () async {
      var calls = 0;
      final engine = await startedEngine(
        metadataGenerator: (video) async {
          calls++;
          return SetMetadata(
            title: 'Copper Pine Energy Surge',
            description: 'A copper pine energy surge.',
            tags: ['copper', 'pine'],
            category: 'DESIGNS',
          );
        },
      );
      await finishVideo(engine);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
      final v = engine.videos.first;
      expect(calls, 1);
      expect(v.hasMetadata, isTrue);
      expect(v.metadata!.title, 'Copper Pine Energy Surge');
      expect(v.metadataFailed, isFalse);
      expect(engine.status, contains('AI Metadata ready'));
    });

    test('metadata failure leaves the video usable with a flag',
        () async {
      final engine = await startedEngine(
        metadataGenerator: (_) async =>
            throw Exception('Gemini metadata deyni'),
      );
      await finishVideo(engine, fps: 30);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
      final v = engine.videos.first;
      expect(v.hasMetadata, isFalse);
      expect(v.metadataFailed, isTrue);
      // The video is still saved + playable; the ready status
      // keeps the fps note instead of the metadata error.
      expect(await File(v.localPath).exists(), isTrue);
      expect(engine.status, contains('Animation ready'));
      expect(engine.status, contains('30fps'));
    });

    test('no metadata generator: video-ready is unchanged', () async {
      final engine = await startedEngine();
      await finishVideo(engine, fps: 30);
      expect(engine.phase, AnimationPhase.ready);
      expect(engine.videos, hasLength(1));
      expect(engine.videos.first.metadataFailed, isFalse);
      expect(engine.status, contains('30fps'));
    });

    test('metadataFailed round-trips through toJson/fromJson', () {
      final failed = _video(id: 'v1').copyWith(metadataFailed: true);
      expect(
          AnimationVideo.fromJson(failed.toJson())?.metadataFailed, isTrue);
      // Old saves without the field load as "not failed".
      expect(
          AnimationVideo.fromJson(_video(id: 'v2').toJson())
              ?.metadataFailed,
          isFalse);
      final oldJson = _video(id: 'v3').toJson()..remove('metadataFailed');
      expect(
          AnimationVideo.fromJson(oldJson)?.metadataFailed, isFalse);
    });
  });
}
