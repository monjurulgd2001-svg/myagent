// v157 — per-video panel section choice (Live Wallpaper /
// Charging Animation) on the Animation video card. Before v157
// every video was stamped contentType LIVE_WALLPAPER at the
// source (buildVideoPanelRecord hardcoded it), so the panel
// filed every animation under Live Wallpaper. Now the card
// picks the section per video (Charging Animation by default)
// and the choice flows into the queue record.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';

void main() {
  AnimationVideo video({
    required String id,
    String panelType = kDefaultVideoPanelType,
    SetMetadata? metadata,
    String localPath = '/tmp/anim_v157.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'fire magnetic charging animation',
        prompt: 'fire magnetic charging animation',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v157.mp4',
        fps: 30,
        durationSec: 6,
        createdAt: DateTime.now(),
        metadata: metadata,
        panelType: panelType,
      );

  SetMetadata fakeMeta() => SetMetadata(
        title: 'Neon Blue Phone',
        description: 'A neon blue phone charging.',
        tags: ['neon', 'phone', 'charging'],
        category: 'DESIGNS',
        generatedAtMs: 1,
      );

  group('v157 panel type on the model', () {
    test('default is Charging Animation', () {
      expect(video(id: 'v1').panelType, kVideoPanelTypeCharging);
      expect(kDefaultVideoPanelType, 'CHARGING_ANIMATION');
    });

    test('JSON round-trip keeps a Live Wallpaper choice', () {
      final back = AnimationVideo.fromJson(
          video(id: 'v1', panelType: kVideoPanelTypeLive).toJson())!;
      expect(back.panelType, 'LIVE_WALLPAPER');
      expect(AnimationVideo.fromJson(video(id: 'v1').toJson())!.panelType,
          'CHARGING_ANIMATION');
    });

    test('unknown stored values normalise to Charging Animation', () {
      expect(normalizeVideoPanelType(null), 'CHARGING_ANIMATION');
      expect(normalizeVideoPanelType('ANIMATION'), 'CHARGING_ANIMATION');
      expect(normalizeVideoPanelType('LIVE_WALLPAPER'), 'LIVE_WALLPAPER');
      expect(videoPanelTypeLabel(kVideoPanelTypeCharging),
          'Charging Animation');
      expect(videoPanelTypeLabel(kVideoPanelTypeLive), 'Live Wallpaper');
    });
  });

  group('v157 panel type in the queue record', () {
    test('buildVideoPanelRecord defaults to CHARGING_ANIMATION', () {
      final record = StudioEngine.buildVideoPanelRecord(
        video: video(id: 'v1'),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
      );
      expect(record['contentType'], 'CHARGING_ANIMATION');
    });

    test('choosing Live Wallpaper writes LIVE_WALLPAPER', () {
      final record = StudioEngine.buildVideoPanelRecord(
        video: video(id: 'v1', panelType: kVideoPanelTypeLive),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
      );
      expect(record['contentType'], 'LIVE_WALLPAPER');
      // An explicit override wins over the video's stored choice.
      final overridden = StudioEngine.buildVideoPanelRecord(
        video: video(id: 'v1', panelType: kVideoPanelTypeLive),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
        panelType: kVideoPanelTypeCharging,
      );
      expect(overridden['contentType'], 'CHARGING_ANIMATION');
      // And an unknown value normalises instead of leaking through.
      final weird = StudioEngine.buildVideoPanelRecord(
        video: video(id: 'v1'),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
        panelType: 'ANIMATION',
      );
      expect(weird['contentType'], 'CHARGING_ANIMATION');
    });

    test('resolveDistContentType maps animation to CHARGING_ANIMATION',
        () {
      final engine = StudioEngine();
      expect(
          engine.resolveDistContentType('animation'), 'CHARGING_ANIMATION');
      // The other mappings are unchanged.
      expect(engine.resolveDistContentType('set_24h'), 'WALLPAPER_24H');
      expect(engine.resolveDistContentType('set_dual'), 'WALLPAPER_DUAL');
      expect(
          engine.resolveDistContentType('set_battery'), 'WALLPAPER_BATTERY');
      expect(engine.resolveDistContentType('single'), 'WALLPAPER');
    });

    test('uploadVideoToPanel sends the video\'s chosen type', () async {
      final tmp = Directory.systemTemp.createTempSync('v157_panel_type_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/anim_v157.mp4';
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      http.Request? fbReq;
      final client = MockClient((req) async {
        if (req.url.host == 'worker.example.com') {
          if (req.headers['X-File-Type'] == 'image/jpeg') {
            return http.Response(
                '{"url": "https://r2.example.com/zedge1/wallpaper/123_x_thumb.jpg"}',
                200);
          }
          return http.Response(
              '{"url": "https://r2.example.com/zedge1/wallpaper/123_x.mp4"}',
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
      final engine = StudioEngine(
        client: client,
        // v159 second pass — the thumbnail guarantee: the upload
        // now needs a real cover capture (the default returns
        // null on this desktop host, which would block it).
        coverCapture: (path, {int timeMs = 1000}) async =>
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );
      final live = video(
          id: 'v1', panelType: kVideoPanelTypeLive, localPath: path);
      // With metadata already present, no Gemini call is made.
      final withMeta = live.copyWith(metadata: fakeMeta());
      final r = await engine.uploadVideoToPanel(withMeta);
      expect(r.accountName, 'zedge_1');
      expect(r.firebaseKey, '-Nkey1');
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['type'], 'video/mp4');
      expect(record['isVideo'], isTrue);
      expect(record['contentType'], 'LIVE_WALLPAPER');
      expect(record['status'], 'queued');
    });
  });

  group('v157 panel type on the engine', () {
    test('setVideoPanelType persists the choice', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      await engine.setVideoPanelType(
          engine.videos.first, kVideoPanelTypeLive);
      expect(engine.videos.first.panelType, 'LIVE_WALLPAPER');
      // Persisted: a fresh engine loading the same prefs sees it.
      final reloaded = AnimationEngine();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.videos.length, 1);
      expect(reloaded.videos.first.panelType, 'LIVE_WALLPAPER');
      // No-op when unchanged.
      await engine.setVideoPanelType(
          engine.videos.first, kVideoPanelTypeLive);
      expect(engine.videos.first.panelType, 'LIVE_WALLPAPER');
    });

    test('uploadAllToPanel uses each video\'s own chosen type', () async {
      SharedPreferences.setMockInitialValues({});
      final seen = <AnimationVideo>[];
      final engine = AnimationEngine(
        panelUploader: (v, {targetAccount = 'spread'}) async {
          seen.add(v);
          return (
            accountName: 'zedge_1',
            firebaseKey: '-Nk',
            metadata: null,
            thumbUrl: null,
            coverError: null,
          );
        },
      );
      addTearDown(engine.dispose);
      engine.videos = [
        video(id: 'v1'),
        video(id: 'v2', panelType: kVideoPanelTypeLive),
      ];
      final done = await engine.uploadAllToPanel();
      expect(done, 2);
      expect(seen.map((v) => v.panelType).toList(),
          ['CHARGING_ANIMATION', 'LIVE_WALLPAPER']);
    });
  });

  group('v157 panel-type chips on the video card', () {
    Future<void> pumpSection(WidgetTester tester, AnimationEngine engine,
        {void Function(AnimationVideo v)? onUpload}) async {
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
              onUploadToPanel: (v) async => onUpload?.call(v),
              onUploadAllToPanel: () async {},
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> toListView(WidgetTester tester) async {
      final fewer = find.byTooltip('Fewer columns (larger cards)');
      await tester.ensureVisible(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('grid tile shows the chosen panel section',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      await pumpSection(tester, engine);
      expect(find.text('Panel: Charging Animation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chip tap changes the choice and the upload sends it',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      AnimationVideo? uploaded;
      await pumpSection(tester, engine, onUpload: (v) => uploaded = v);
      await toListView(tester);
      // Default: Charging Animation is selected.
      expect(
          tester
              .widget<ChoiceChip>(find.byKey(
                  const ValueKey('animPanelType-charging-v1')))
              .selected,
          isTrue);
      // Pick Live Wallpaper on the card.
      final liveChip = find.byKey(const ValueKey('animPanelType-live-v1'));
      await tester.ensureVisible(liveChip);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(liveChip);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.videos.first.panelType, 'LIVE_WALLPAPER');
      // The card re-renders with the new selection (a fresh pump
      // stands in for the app's onChanged rebuild).
      await pumpSection(tester, engine, onUpload: (v) => uploaded = v);
      await toListView(tester);
      expect(
          tester
              .widget<ChoiceChip>(
                  find.byKey(const ValueKey('animPanelType-live-v1')))
              .selected,
          isTrue);
      expect(
          tester
              .widget<ChoiceChip>(find.byKey(
                  const ValueKey('animPanelType-charging-v1')))
              .selected,
          isFalse);
      // Upload sends the video with its chosen type.
      await tester.tap(find.byKey(const ValueKey('animUpload-v1')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(uploaded?.panelType, 'LIVE_WALLPAPER');
      expect(tester.takeException(), isNull);
    });
  });
}
