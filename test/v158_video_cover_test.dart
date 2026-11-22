// v158 — cover frame ("thumbnail") for a finished animation
// video, sent to the panel as the queue record's thumbUrl so the
// panel shows a preview instead of an empty card. Before v158 the
// record carried no thumbUrl at all (the panel's previewUrl for
// video types is thumbUrl), so every Zedge Studio video showed an
// empty preview in the panel.
//
// Cover size (user order 2026-11-22: "Cover size kintu
// 1620x2880"): the frame is captured at the video's FULL native
// resolution — no downscale anywhere on the seam (the capture
// typedef takes no size parameters at all). The test below builds
// a real 1620x2880 JPEG as the fake capture result and asserts
// the bytes uploaded to R2 still decode to 1620x2880.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:gemini_hd_studio/video_cover.dart';

void main() {
  AnimationVideo video({
    required String id,
    String panelType = kDefaultVideoPanelType,
    String thumbUrl = '',
    SetMetadata? metadata,
    String localPath = '/tmp/anim_v158.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'fire magnetic charging animation',
        prompt: 'fire magnetic charging animation',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v158.mp4',
        width: 1620,
        height: 2880,
        fps: 30,
        durationSec: 6,
        createdAt: DateTime.now(),
        metadata: metadata,
        panelType: panelType,
        thumbUrl: thumbUrl,
      );

  SetMetadata fakeMeta() => SetMetadata(
        title: 'Neon Blue Phone',
        description: 'A neon blue phone charging.',
        tags: ['neon', 'phone', 'charging'],
        category: 'DESIGNS',
        generatedAtMs: 1,
      );

  /// A real 1620x2880 JPEG — the fake capture result. If any
  /// layer downscaled the cover, these bytes would decode smaller.
  Uint8List cover1620() {
    final image = img.Image(width: 1620, height: 2880);
    img.fill(image, color: img.ColorRgb8(255, 80, 0));
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

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

  group('v158 cover on the model', () {
    test('default is no cover, JSON round-trip keeps one', () {
      expect(video(id: 'v1').thumbUrl, '');
      final back = AnimationVideo.fromJson(video(
        id: 'v1',
        thumbUrl: 'https://r2.example.com/zedge1/wallpaper/1_t.jpg',
      ).toJson())!;
      expect(back.thumbUrl,
          'https://r2.example.com/zedge1/wallpaper/1_t.jpg');
      expect(AnimationVideo.fromJson(video(id: 'v1').toJson())!.thumbUrl,
          '');
    });

    test('copyWith keeps the cover unless replaced', () {
      final v = video(id: 'v1', thumbUrl: 'https://r2.example.com/a.jpg');
      expect(v.copyWith().thumbUrl, 'https://r2.example.com/a.jpg');
      expect(v.copyWith(thumbUrl: 'https://r2.example.com/b.jpg').thumbUrl,
          'https://r2.example.com/b.jpg');
    });
  });

  group('v158 cover in the queue record', () {
    test('buildVideoPanelRecord includes thumbUrl when given', () {
      final record = StudioEngine.buildVideoPanelRecord(
        video: video(id: 'v1'),
        fileUrl: 'https://r2.example.com/x.mp4',
        fileName: 'x.mp4',
        fileSize: 4,
        fileSha: 'abc',
        now: 123,
        thumbUrl: 'https://r2.example.com/zedge1/wallpaper/1_t.jpg',
      );
      expect(record['thumbUrl'],
          'https://r2.example.com/zedge1/wallpaper/1_t.jpg');
    });

    test('buildVideoPanelRecord omits thumbUrl when null or empty', () {
      for (final t in <String?>[null, '']) {
        final record = StudioEngine.buildVideoPanelRecord(
          video: video(id: 'v1'),
          fileUrl: 'https://r2.example.com/x.mp4',
          fileName: 'x.mp4',
          fileSize: 4,
          fileSha: 'abc',
          now: 123,
          thumbUrl: t,
        );
        expect(record.containsKey('thumbUrl'), isFalse);
      }
    });
  });

  group('v158 cover in the panel upload', () {
    Future<AnimationVideo> videoFile(Directory tmp) async {
      final path = '${tmp.path}/anim_v158.mp4';
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      return video(id: 'v1', localPath: path).copyWith(metadata: fakeMeta());
    }

    test('capture + upload: record carries thumbUrl, cover is 1620x2880',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final calls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          calls.add(timeMs);
          return cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.accountName, 'zedge_1');
      expect(r.firebaseKey, '-Nkey1');
      // First attempt is ~1s into the video.
      expect(calls, [1000]);
      // The record carries the uploaded cover URL.
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['thumbUrl'], r.thumbUrl);
      // The bytes uploaded to R2 for the cover still decode to
      // the video's full native size — no downscale anywhere.
      final thumbReq = r2Reqs.firstWhere(
          (req) => req.headers['X-File-Type'] == 'image/jpeg');
      final uploaded = img.decodeJpg(thumbReq.bodyBytes)!;
      expect(uploaded.width, 1620);
      expect(uploaded.height, 2880);
    });

    test('capture fails (null): upload is BLOCKED, no Firebase record',
        () async {
      // v159 SECOND PASS — the thumbnail guarantee REVOKES the
      // v158 behaviour: a missing cover now BLOCKS the queue.
      // The upload THROWS before the Firebase record is pushed,
      // so the panel can never get a thumbnail-less record again;
      // the video stays on the device for a retry.
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final hwCalls = <int>[];
      final browserCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          return null;
        },
        browserCoverCapture: (path, {int timeMs = 1000}) async {
          browserCalls.add(timeMs);
          return null;
        },
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              contains('Thumbnail banano jayni'))));
      // No Firebase record was ever pushed…
      expect(fbReq, isNull);
      // …and no cover went to R2 either. Four timestamps were
      // tried on each path before giving up.
      expect(hwCalls, [1000, 2000, 3000, 5000]);
      expect(browserCalls, [1000, 2000, 3000, 5000]);
      expect(
          r2Reqs
              .where((req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
    });

    test('capture throws: upload is BLOCKED, error names the step',
        () async {
      // v159 SECOND PASS — same guarantee: a throwing capture
      // blocks the queue instead of shipping without a cover.
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async =>
            throw Exception('no decoder'),
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              allOf(contains('Thumbnail banano jayni'),
                  contains('hardware capture threw'),
                  contains('no decoder')))));
      expect(fbReq, isNull);
    });

    test('capture fallback: 1000ms fails, 2000ms works', () async {
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async =>
            timeMs == 1000 ? null : cover1620(),
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
    });

    test('cached thumbUrl is reused, capture never runs', () async {
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      var calls = 0;
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          calls++;
          return cover1620();
        },
      );
      final v = (await videoFile(tmp)).copyWith(
          thumbUrl: 'https://r2.example.com/zedge1/wallpaper/old_t.jpg');
      final r = await engine.uploadVideoToPanel(v);
      expect(calls, 0);
      expect(r.thumbUrl, 'https://r2.example.com/zedge1/wallpaper/old_t.jpg');
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['thumbUrl'],
          'https://r2.example.com/zedge1/wallpaper/old_t.jpg');
      expect(
          r2Reqs
              .where((req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
    });

    test('default capture skips on this platform (Windows behaviour)',
        () async {
      // The real capture only runs on Android/iOS — the plugin
      // has no desktop implementation. In flutter_test (a
      // desktop host) it returns null.
      expect(await captureVideoCover('/tmp/no_such_video.mp4'), isNull);
      // v159 SECOND PASS — with no cover path at all on desktop,
      // the thumbnail guarantee now BLOCKS the upload instead of
      // shipping a thumbnail-less record (the v158 behaviour is
      // revoked). v160 added the desktop cover path (headless
      // Chrome canvas), but on this Linux test host that path
      // returns null too (Platform.isWindows is false), so the
      // default engine still blocks here — exactly what this
      // test asserts.
      final tmp = Directory.systemTemp.createTempSync('v158_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client = mockPanelClient(
          r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(client: client);
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              contains('Thumbnail banano jayni'))));
      expect(fbReq, isNull);
    });
  });

  group('v158 cover on the engine', () {
    test('uploadVideoToPanel persists the returned cover on the video',
        () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        panelUploader: (v, {targetAccount = 'spread'}) async => (
          accountName: 'zedge_1',
          firebaseKey: '-Nk',
          metadata: null,
          thumbUrl: 'https://r2.example.com/zedge1/wallpaper/1_t.jpg',
          coverError: null,
        ),
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      expect(await engine.uploadVideoToPanel(engine.videos.first), isTrue);
      expect(engine.videos.first.thumbUrl,
          'https://r2.example.com/zedge1/wallpaper/1_t.jpg');
      // Persisted: a fresh engine loading the same prefs sees it.
      final reloaded = AnimationEngine();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.videos.first.thumbUrl,
          'https://r2.example.com/zedge1/wallpaper/1_t.jpg');
    });

    test('uploadAllToPanel uses each video\'s own cover', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        panelUploader: (v, {targetAccount = 'spread'}) async => (
          accountName: 'zedge_1',
          firebaseKey: '-N${v.id}',
          metadata: null,
          thumbUrl:
              'https://r2.example.com/zedge1/wallpaper/${v.id}_t.jpg',
          coverError: null,
        ),
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1'), video(id: 'v2')];
      expect(await engine.uploadAllToPanel(), 2);
      expect(
          engine.videos.map((v) => v.thumbUrl).toList(),
          [
            'https://r2.example.com/zedge1/wallpaper/v1_t.jpg',
            'https://r2.example.com/zedge1/wallpaper/v2_t.jpg',
          ]);
    });
  });
}
