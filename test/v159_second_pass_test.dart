// v159 SECOND PASS — three deltas on top of the v159 build:
//
// A. THUMBNAIL GUARANTEE: a missing cover BLOCKS the queue (the
//    v158 "upload anyway without a cover" is revoked). Three
//    timestamps per path (1000ms, 0ms, 2000ms); a total failure
//    throws before the Firebase record is pushed, the error lands
//    in the status + persisted error log, and the video stays on
//    the device for a retry.
// B. VIDEO METADATA CARD mirrors the IMAGE card (_metaCard):
//    same container, title row (AI title + filled purple
//    uppercase pill + sparkle), source line, description/tags
//    behaviour and 'Aro dekho' toggle — with per-video expand
//    state.
// C. FILE SIZE: the prompt asks for an efficiently compressed
//    file under 10 MB; the card shows the measured size; an
//    over-target file gets a Banglish note — but the video itself
//    stays usable (size never blocks anything).
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
    SetMetadata? metadata,
    int sizeBytes = 0,
    String localPath = '/tmp/anim_v159b.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'copper pine energy surge',
        prompt: 'copper pine energy surge',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v159b.mp4',
        width: 1620,
        height: 2880,
        fps: 60,
        durationSec: 10,
        sizeBytes: sizeBytes,
        createdAt: DateTime.now(),
        metadata: metadata,
      );

  SetMetadata fakeMeta() => SetMetadata(
        title: 'Copper Pine Energy Surge',
        description: 'A copper pine energy surge.',
        tags: ['copper', 'pine', 'energy'],
        category: 'DESIGNS',
        generatedAtMs: 1,
      );

  void setDistConfig() {
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
  }

  MockClient mockPanelClient({
    required void Function(http.Request) onFirebase,
  }) {
    return MockClient((req) async {
      if (req.url.host == 'worker.example.com') {
        final key = req.headers['X-File-Name'] ?? 'x';
        return http.Response('{"url": "https://r2.example.com/$key"}', 200);
      }
      if (req.url.host == 'db.example.com') {
        onFirebase(req);
        return http.Response('{"name": "-Nkey1"}', 200);
      }
      return http.Response('not found', 404);
    });
  }

  group('v159 second pass A — thumbnail guarantee', () {
    test('capture succeeds: the built record contains the thumbUrl',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v159b_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      http.Request? fbReq;
      final client = mockPanelClient(onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async =>
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );
      final path = '${tmp.path}/anim_v159b.mp4';
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      final v = video(id: 'v1', localPath: path)
          .copyWith(metadata: fakeMeta());
      final r = await engine.uploadVideoToPanel(v);
      expect(r.firebaseKey, '-Nkey1');
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['thumbUrl'], r.thumbUrl);
    });
  });

  group('v159 second pass C — file size', () {
    test('prompt asks for a compressed file under 10 MB', () {
      // Default branch (spec suffix) and size branch (prompt
      // already carries 1620x2880) both carry the ask — and the
      // 1620x2880 / 60fps / seamless-loop spec survives it.
      for (final p in [
        buildAnimationPrompt('neon blue liquid energy phone'),
        buildAnimationPrompt('1620x2880 9:16 60fps creative'),
      ]) {
        expect(p, contains('under 10 MB'));
        expect(p, contains('efficiently compressed'));
        expect(p, contains('mobile-optimized H.264'));
        expect(p, contains('1620x2880'));
        expect(p, contains('60fps'));
        expect(p, contains('seamless loop'));
      }
      // …but never twice when the user already asked for it.
      final already = buildAnimationPrompt(
          'a small file under 10 MB, neon phone charging');
      expect('under 10 mb'.allMatches(already.toLowerCase()).length, 1);
    });

    test('specLine + cardLine show the measured size in MB', () {
      // The live file: 36,279,534 bytes reads "36.3 MB" (decimal,
      // so the card matches the byte count he knows).
      final big = video(id: 'v1', sizeBytes: 36279534);
      expect(big.specLine, contains('36.3 MB'));
      expect(big.cardLine, contains('36.3 MB'));
      expect(big.sizeLabel, '36.3 MB');
      // A small file shows its own size; an unmeasured file
      // shows no size at all (never an invented one).
      expect(video(id: 'v1', sizeBytes: 4742568).specLine,
          contains('4.7 MB'));
      expect(video(id: 'v1').sizeLabel, isEmpty);
      expect(video(id: 'v1').specLine, isNot(contains('MB')));
      // copyWith + JSON round-trip keep the size.
      final back = AnimationVideo.fromJson(
          video(id: 'v1', sizeBytes: 36279534)
              .copyWith(sizeBytes: 12345)
              .toJson())!;
      expect(back.sizeBytes, 12345);
    });

    test('over-target note appears only when over 10 MB', () {
      expect(video(id: 'v1', sizeBytes: 36279534).isOverTargetSize,
          isTrue);
      final note = video(id: 'v1', sizeBytes: 36279534).sizeNote;
      expect(note, contains('Gemini 10 MB-er boro file diyeche'));
      expect(note, contains('36.3 MB'));
      expect(note, contains('10 MB chawa hoyechilo'));
      expect(video(id: 'v1', sizeBytes: 10000000).isOverTargetSize,
          isFalse);
      expect(video(id: 'v1', sizeBytes: 10000000).sizeNote, isEmpty);
      expect(video(id: 'v1', sizeBytes: 4742568).sizeNote, isEmpty);
      expect(video(id: 'v1').sizeNote, isEmpty);
    });

    test('an over-target video still uploads and stays usable',
        () async {
      // Size never blocks anything (unlike the thumbnail
      // guarantee): a 36 MB video queues normally.
      final tmp = Directory.systemTemp.createTempSync('v159b_size_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      http.Request? fbReq;
      final client = mockPanelClient(onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async =>
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );
      final path = '${tmp.path}/anim_v159b.mp4';
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      final v = video(id: 'v1', localPath: path, sizeBytes: 36279534)
          .copyWith(metadata: fakeMeta());
      final r = await engine.uploadVideoToPanel(v);
      expect(r.firebaseKey, '-Nkey1');
      expect(r.thumbUrl, isNotNull);
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['status'], 'queued');
      expect(record['thumbUrl'], r.thumbUrl);
    });
  });

  group('v159 second pass B — video metadata card mirrors the image card',
      () {
    SetMetadata longMeta() => SetMetadata(
          title: 'Copper Pine Energy Surge',
          description:
              'A copper pine energy surge flows through the forest at '
              'night, lighting every needle with warm golden light while '
              'the phone charges beside the ancient tree trunk.',
          tags: ['copper', 'pine', 'energy', 'forest', 'night', 'golden'],
          category: 'DESIGNS',
        );

    SetMetadata shortMeta() => SetMetadata(
          title: 'Copper Pine Energy Surge',
          description: 'A copper pine energy surge.',
          tags: ['copper', 'pine', 'energy'],
          category: 'DESIGNS',
        );

    Future<void> pumpSection(
        WidgetTester tester, AnimationEngine engine) async {
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

    testWidgets('list card shows AI title, pill, source line, toggle',
        (tester) async {
      await pumpSection(
          tester, engineWith([video(id: 'v1', metadata: longMeta())]));
      await switchToList(tester);
      // The mirrored block: AI title, filled purple UPPERCASE
      // pill, source line, and the 'Aro dekho' toggle (long
      // description + 6 tags, so the toggle shows).
      expect(find.text('Copper Pine Energy Surge'), findsOneWidget);
      expect(find.text('DESIGNS'), findsOneWidget);
      expect(find.text('gemini-web (cookie)'), findsOneWidget);
      expect(find.text('Aro dekho'), findsOneWidget);
      // Same description + tags as the image card (tags carry
      // the image card's '#tag' chip).
      expect(find.textContaining('copper pine energy surge flows'),
          findsOneWidget);
      expect(find.text('#copper'), findsOneWidget);
      expect(find.text('#golden'), findsOneWidget);
      // The sparkle rewrites the video's metadata (same tooltip
      // as the image card).
      expect(find.byTooltip('Rewrite with AI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the toggle expands to full description + tags',
        (tester) async {
      await pumpSection(
          tester, engineWith([video(id: 'v1', metadata: longMeta())]));
      await switchToList(tester);
      final toggle = find.byKey(const ValueKey('animMetaExpandToggle-v1'));
      await tester.ensureVisible(toggle);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Kom dekho'), findsOneWidget);
      expect(find.text('Aro dekho'), findsNothing);
      // Expanded: the full description and the wrapped tags.
      expect(find.textContaining('ancient tree trunk'), findsOneWidget);
      expect(find.text('#forest'), findsOneWidget);
      // Tapping again collapses.
      final toggleAgain =
          find.byKey(const ValueKey('animMetaExpandToggle-v1'));
      await tester.ensureVisible(toggleAgain);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(toggleAgain);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Aro dekho'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanding one video does not expand the others',
        (tester) async {
      await pumpSection(
          tester,
          engineWith([
            video(id: 'v1', metadata: longMeta()),
            video(id: 'v2', metadata: longMeta()),
          ]));
      await switchToList(tester);
      expect(find.text('Aro dekho'), findsNWidgets(2));
      final toggle1 = find.byKey(const ValueKey('animMetaExpandToggle-v1'));
      await tester.ensureVisible(toggle1);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(toggle1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Kom dekho'), findsOneWidget);
      expect(find.text('Aro dekho'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggle hidden when nothing is hidden', (tester) async {
      await pumpSection(
          tester, engineWith([video(id: 'v1', metadata: shortMeta())]));
      await switchToList(tester);
      // Short description (<=120 chars) + 3 tags: the image
      // card shows no toggle, and neither does the video card.
      expect(find.text('Aro dekho'), findsNothing);
      expect(find.text('Copper Pine Energy Surge'), findsOneWidget);
      expect(find.text('DESIGNS'), findsOneWidget);
      expect(find.text('gemini-web (cookie)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sparkle opens the video metadata dialog',
        (tester) async {
      await pumpSection(
          tester, engineWith([video(id: 'v1', metadata: longMeta())]));
      await switchToList(tester);
      await tester.tap(find.byTooltip('Rewrite with AI'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('over-target size note shows on the list card',
        (tester) async {
      await pumpSection(
          tester,
          engineWith([
            video(id: 'v1', metadata: shortMeta(), sizeBytes: 36279534)
          ]));
      await switchToList(tester);
      expect(find.textContaining('36.3 MB'), findsWidgets);
      expect(find.textContaining('Gemini 10 MB-er boro file diyeche'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
