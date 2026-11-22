// v166 — manual cover-frame picker + presented-frame capture fix.
//
// Live 2026-11-23 the "Charging Holiday Tree Glow" panel tile was
// BLACK again despite the v162 luminance gate: the gate can only
// reject black frames it can measure, and the browser capture
// draws frames that were never presented (content.js onCapture +
// chromeCoverScript did play() -> immediate pause(), waited only
// for readyState >= 1 + 'seeked', then drew at once in a viewless
// session — every sampled frame was a blank canvas, and the
// brightest blank was still black). Two more holes: the upload
// reused a stored thumbUrl without ever re-running capture, so a
// stored black thumb was re-uploaded forever.
//
// v166:
//  (1) presented-frame wait — after the seek, the capture waits
//      for requestVideoFrameCallback (a frame actually presented)
//      with a timeout fallback that plays briefly, then draws.
//  (2) native retriever path (VideoCoverBridge.kt, the panel's
//      MediaMetadataRetriever recipe) — first capture path.
//  (3) manual picker — the card shows candidate frames (panel
//      percentage points) and the user taps the cover he wants;
//      the pick is persisted on the video and honored at upload.
//  (4) re-upload re-captures — a stored thumbUrl is only the
//      last resort, never silently reused when a good frame is
//      now available.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:gemini_hd_studio/video_cover.dart';

void main() {
  AnimationVideo video({
    required String id,
    double durationSec = 10,
    String localPath = '/tmp/anim_v166.mp4',
    String thumbUrl = '',
    int pickedCoverTimeMs = -1,
  }) =>
      AnimationVideo(
        id: id,
        title: 'crimson facet tree',
        prompt: 'crimson facet tree',
        modelId: 'neon',
        styleId: 'dark-moody',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v166.mp4',
        width: 1620,
        height: 2880,
        fps: 60,
        durationSec: durationSec,
        thumbUrl: thumbUrl,
        pickedCoverTimeMs: pickedCoverTimeMs,
        createdAt: DateTime.now(),
        metadata: SetMetadata(
          title: 'Crimson Facet Tree',
          description: 'A sculpted geometric tree of dark slate.',
          tags: ['obsidian', 'crimson', 'geometric'],
          category: 'HOLIDAYS',
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

  /// Gray level of the first pixel of an uploaded thumb.
  double thumbGray(http.Request thumbReq) {
    final decoded = img.decodeJpg(thumbReq.bodyBytes)!;
    return decoded.getPixel(0, 0).r.toDouble();
  }

  http.Request thumbReqOf(List<http.Request> r2Reqs) => r2Reqs.firstWhere(
      (req) => req.headers['X-File-Type'] == 'image/jpeg');

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
    required List<http.Request> r2Reqs,
    required void Function(http.Request) onFirebase,
  }) {
    return MockClient((req) async {
      if (req.url.host == 'worker.example.com') {
        r2Reqs.add(req);
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

  Future<AnimationVideo> videoFile(Directory tmp,
      {double durationSec = 10,
      String thumbUrl = '',
      int pickedCoverTimeMs = -1}) async {
    final path = '${tmp.path}/anim_v166.mp4';
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    return video(
        id: 'v1',
        localPath: path,
        durationSec: durationSec,
        thumbUrl: thumbUrl,
        pickedCoverTimeMs: pickedCoverTimeMs);
  }

  group('v166 presented-frame wait in the capture scripts', () {
    test('chromeCoverScript waits for a presented frame before drawing',
        () {
      final s = chromeCoverScript(2.0);
      expect(s, contains('requestVideoFrameCallback'));
      // The draw happens after the presented-frame wait.
      expect(s.indexOf('requestVideoFrameCallback'),
          lessThan(s.indexOf('drawImage')));
      // Never hangs: the wait has a timeout fallback.
      expect(s, contains('setTimeout(res, 3000)'));
      // The decoder is really primed (play, then a pause) and the
      // fallback plays briefly when no frame was presented.
      expect(s, contains('setTimeout(r, 400)'));
      expect(s, contains('setTimeout(r, 300)'));
      // Full native size is unchanged.
      expect(s, contains('c.width = v.videoWidth'));
      expect(s, contains('c.height = v.videoHeight'));
    });

    test('content.js onCapture waits for a presented frame before drawing',
        () {
      final src = File('android/app/src/main/assets/ais_cookies/content.js')
          .readAsStringSync();
      expect(src, contains('requestVideoFrameCallback'));
      // The draw happens after the presented-frame wait.
      final waitAt = src.indexOf('requestVideoFrameCallback');
      final drawAt = src.indexOf('ctx.drawImage(v, 0, 0, w, h)');
      expect(waitAt, greaterThan(0));
      expect(drawAt, greaterThan(waitAt));
      // The old play() -> immediate pause() is gone.
      expect(src, contains('setTimeout(r, 400)'));
      expect(src, contains('setTimeout(r, 300)'));
    });
  });

  group('v166 candidate timestamps', () {
    test('10s video: panel percentage points', () {
      expect(coverCandidateTimesMs(10),
          [800, 2800, 5000, 7200, 9200]);
    });

    test('6s video: points scale with duration', () {
      expect(coverCandidateTimesMs(6), [480, 1680, 3000, 4320, 5520]);
    });

    test('unknown duration: fixed spread across a typical clip', () {
      expect(coverCandidateTimesMs(0), [1000, 3000, 5000, 7000, 9000]);
    });
  });

  group('v166 retriever path + picked frame in the panel upload', () {
    test('retriever runs first and the gate still applies to it',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final retrieverCalls = <int>[];
      final hwCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        retrieverCoverCapture: (path, {int timeMs = 1000}) async {
          retrieverCalls.add(timeMs);
          if (timeMs == 1000) return grayJpeg(0);
          if (timeMs == 2000) return grayJpeg(200);
          return null;
        },
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          return grayJpeg(250);
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      // Black at 1s rejected, bright at 2s chosen — on the
      // retriever, before the hardware path ever ran.
      expect(retrieverCalls, [1000, 2000]);
      expect(hwCalls, isEmpty);
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(200, 3));
    });

    test('upload uses the picked frame, at the picked timestamp',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final retrieverCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        retrieverCoverCapture: (path, {int timeMs = 1000}) async {
          retrieverCalls.add(timeMs);
          if (timeMs == 5000) return grayJpeg(190);
          return null;
        },
        coverCapture: (path, {int timeMs = 1000}) async => grayJpeg(250),
      );
      final r = await engine.uploadVideoToPanel(
          await videoFile(tmp, pickedCoverTimeMs: 5000));
      expect(r.thumbUrl, isNotNull);
      // The picked timestamp was tried first — the hardware
      // fallback never ran.
      expect(retrieverCalls, [5000]);
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(190, 3));
    });

    test('re-upload re-captures: a fresh frame beats a stored thumbUrl',
        () async {
      // The hatch-2 bug, replayed: a stored black thumb was
      // re-uploaded forever without capture ever running.
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        retrieverCoverCapture: (path, {int timeMs = 1000}) async => null,
        coverCapture: (path, {int timeMs = 1000}) async => grayJpeg(180),
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp,
          thumbUrl: 'https://r2.example.com/old_thumb.jpg'));
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, isNot('https://r2.example.com/old_thumb.jpg'));
      expect(r.thumbUrl, contains('_thumb.jpg'));
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(180, 3));
      expect(fbReq, isNotNull);
      final record = jsonDecode(fbReq!.body) as Map<String, dynamic>;
      expect(record['thumbUrl'], r.thumbUrl);
    });

    test('stored thumbUrl is the last resort when fresh capture finds '
        'nothing', () async {
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        retrieverCoverCapture: (path, {int timeMs = 1000}) async => null,
        coverCapture: (path, {int timeMs = 1000}) async => null,
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
        chromeCoverCapture: (path, {int timeMs = 1000}) async => null,
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp,
          thumbUrl: 'https://r2.example.com/old_thumb.jpg'));
      expect(r.firebaseKey, '-Nkey1');
      expect(r.thumbUrl, 'https://r2.example.com/old_thumb.jpg');
      // No fresh thumb was uploaded.
      expect(
          r2Reqs.where(
              (req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
      final record = jsonDecode(fbReq!.body) as Map<String, dynamic>;
      expect(record['thumbUrl'], 'https://r2.example.com/old_thumb.jpg');
    });

    test('guarantee still blocks when no frame bytes and no stored thumb',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        retrieverCoverCapture: (path, {int timeMs = 1000}) async => null,
        coverCapture: (path, {int timeMs = 1000}) async => null,
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
        chromeCoverCapture: (path, {int timeMs = 1000}) async => null,
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              contains('Thumbnail banano jayni'))));
      expect(fbReq, isNull);
    });
  });

  group('v166 cover candidates + pick persistence', () {
    test('candidates come back at the panel percentage points', () async {
      final tmp = Directory.systemTemp.createTempSync('v166_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final seenTimes = <int>[];
      final engine = StudioEngine(
        candidatesCapture: (path, {required List<int> timesMs}) async {
          seenTimes.addAll(timesMs);
          return [
            for (final t in timesMs)
              CoverCandidate(timeMs: t, bytes: grayJpeg(150), luma: 150),
          ];
        },
      );
      final cands =
          await engine.captureCoverCandidatesFor(await videoFile(tmp));
      expect(seenTimes, [800, 2800, 5000, 7200, 9200]);
      expect(cands.map((c) => c.timeMs).toList(),
          [800, 2800, 5000, 7200, 9200]);
      expect(cands.every((c) => c.luma == 150), isTrue);
      expect(cands.every((c) => !c.isDark), isTrue);
    });

    test('a dark candidate is marked dark', () {
      final dark = CoverCandidate(timeMs: 800, bytes: grayJpeg(0), luma: 0);
      expect(dark.isDark, isTrue);
      final bright =
          CoverCandidate(timeMs: 5000, bytes: grayJpeg(200), luma: 200);
      expect(bright.isDark, isFalse);
    });

    test('pickedCoverTimeMs survives a toJson/fromJson round trip', () {
      final v = video(id: 'v1', pickedCoverTimeMs: 5000);
      final back = AnimationVideo.fromJson(v.toJson())!;
      expect(back.pickedCoverTimeMs, 5000);
      expect(video(id: 'v1').pickedCoverTimeMs, -1);
    });

    test('AnimationEngine.pickCoverFrame persists the pick', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      final v = video(id: 'v1');
      engine.videos = [v];
      await engine.pickCoverFrame(v, 5000);
      expect(engine.videos.first.pickedCoverTimeMs, 5000);
      expect(engine.status, contains('5.0s'));
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('animationVideosJson')!) as List;
      expect(stored.first['pickedCoverTimeMs'], 5000);
      await engine.pickCoverFrame(engine.videos.first, -1);
      expect(engine.videos.first.pickedCoverTimeMs, -1);
      expect(engine.status, contains('Auto'));
    });

    test('AnimationEngine.coverCandidates is [] without a fetcher',
        () async {
      final engine = AnimationEngine();
      addTearDown(engine.dispose);
      expect(await engine.coverCandidates(video(id: 'v1')), isEmpty);
    });
  });

  group('v166 cover picker on the video card', () {
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

    testWidgets('Cover icon opens the picker; tapping a frame picks it',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => [
          for (final t in [800, 2800, 5000, 7200, 9200])
            CoverCandidate(timeMs: t, bytes: grayJpeg(150), luma: 150),
        ],
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      await pumpSection(tester, engine);
      await switchToList(tester);
      expect(find.byKey(const ValueKey('animCover-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('coverPicker-v1')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('animCover-v1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('coverPicker-v1')), findsOneWidget);
      expect(find.text('Cover frame beche nao'), findsOneWidget);
      expect(find.byKey(const ValueKey('coverThumb-v1-5000')),
          findsOneWidget);
      expect(find.text('5.0s'), findsOneWidget);
      await tester.ensureVisible(
          find.byKey(const ValueKey('coverThumb-v1-5000')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('coverThumb-v1-5000')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.videos.first.pickedCoverTimeMs, 5000);
      expect(find.text('Cover frame: 5.0s beche neoa'), findsOneWidget);
      expect(find.byKey(const ValueKey('coverAuto-v1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picker shows the loading state, then the empty note',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        coverCandidatesFetcher: (v) async => <CoverCandidate>[],
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
      expect(tester.takeException(), isNull);
    });
  });
}
