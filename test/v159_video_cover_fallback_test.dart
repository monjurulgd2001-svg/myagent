// v159 — browser-canvas cover fallback + visible cover failure.
//
// Live 2026-11-22: a video ("Copper Pine Energy Surge") uploaded
// from v158 reached the panel as CHARGING_ANIMATION but with NO
// thumbnail — the Firebase record has no thumbUrl key at all. The
// MP4 is valid (H.264 High @ Level 5.2, 1620x2880 @ 60fps, keyframe
// at 0s; ffmpeg extracts a frame fine), but v158's cover capture
// (video_thumbnail = MediaMetadataRetriever = the phone's HARDWARE
// decoder) returned null on TECNO CAMON 30S, the same decoder that
// already failed video preview in v156. v158 swallowed that with a
// brief status note, so nothing said WHY the card has no cover.
//
// v159: (1) when the hardware capture finds no frame, a second
// seam — the browser-canvas capture through a hidden headless
// Gecko session (Gecko software-decodes the MP4) — runs before
// giving up; (2) a cover failure is no longer swallowed: the
// step (capture vs R2 upload) plus the reason is returned as
// coverError and written into the persisted error log, while the
// video still uploads without a cover.
//
// v159 SECOND PASS — (2) is REVOKED by the user ("ki hoy hok
// thumbnail jeno jay"): a total cover failure now BLOCKS the
// queue — StudioEngine throws before the Firebase record is
// pushed, so a thumbnail-less record can never reach the panel
// again, and the video stays on the device for a retry. The
// tests below that asserted "upload succeeds without a cover"
// now assert the block instead. (1) also grows a third
// timestamp per path (1000ms, 0ms, 2000ms).
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
    String thumbUrl = '',
    SetMetadata? metadata,
    String localPath = '/tmp/anim_v159.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'copper pine energy surge',
        prompt: 'copper pine energy surge',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v159.mp4',
        width: 1620,
        height: 2880,
        fps: 60,
        durationSec: 10,
        createdAt: DateTime.now(),
        metadata: metadata,
        thumbUrl: thumbUrl,
      );

  SetMetadata fakeMeta() => SetMetadata(
        title: 'Copper Pine Energy Surge',
        description: 'A copper pine energy surge.',
        tags: ['copper', 'pine', 'energy'],
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
    bool failThumbUpload = false,
  }) {
    return MockClient((req) async {
      if (req.url.host == 'worker.example.com') {
        r2Reqs.add(req);
        if (failThumbUpload &&
            req.headers['X-File-Type'] == 'image/jpeg') {
          return http.Response('worker down', 500);
        }
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

  Future<AnimationVideo> videoFile(Directory tmp) async {
    final path = '${tmp.path}/anim_v159.mp4';
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    return video(id: 'v1', localPath: path).copyWith(metadata: fakeMeta());
  }

  group('v159 browser-canvas fallback in the panel upload', () {
    test('hardware fails, browser capture works: record carries thumbUrl',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
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
        // The live v158 failure: the hardware decoder finds no
        // frame at either time (null, null).
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          return null;
        },
        browserCoverCapture: (path, {int timeMs = 1000}) async {
          browserCalls.add(timeMs);
          return cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.firebaseKey, '-Nkey1');
      // Hardware tried first (all four timestamps, no frame),
      // then the browser fallback answered at ~1s.
      expect(hwCalls, [1000, 2000, 3000, 5000]);
      expect(browserCalls, [1000]);
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
      expect(r.coverError, isNull);
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['thumbUrl'], r.thumbUrl);
      // The fallback bytes still decode to the video's full
      // native size — no downscale anywhere.
      final thumbReq = r2Reqs.firstWhere(
          (req) => req.headers['X-File-Type'] == 'image/jpeg');
      final uploaded = img.decodeJpg(thumbReq.bodyBytes)!;
      expect(uploaded.width, 1620);
      expect(uploaded.height, 2880);
    });

    test('browser fallback never runs when hardware capture works',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      var browserCalls = 0;
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => cover1620(),
        browserCoverCapture: (path, {int timeMs = 1000}) async {
          browserCalls++;
          return cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(r.coverError, isNull);
      expect(browserCalls, 0);
    });

    test('both captures fail: upload is BLOCKED, no Firebase record',
        () async {
      // v159 SECOND PASS — the thumbnail guarantee: the video
      // must NOT upload without a cover. The upload throws
      // before the Firebase record is pushed; the video stays on
      // the device for a retry.
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
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
              allOf(contains('Thumbnail banano jayni'),
                  contains('cover capture failed')))));
      // No Firebase record was ever pushed, and no cover went
      // to R2 — but all four timestamps were tried on each path.
      expect(fbReq, isNull);
      expect(hwCalls, [1000, 2000, 3000, 5000]);
      expect(browserCalls, [1000, 2000, 3000, 5000]);
      expect(
          r2Reqs
              .where((req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
    });

    test('both captures throw: upload is BLOCKED, error names both',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
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
        browserCoverCapture: (path, {int timeMs = 1000}) async =>
            throw Exception('cover tab never connected'),
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              allOf(
                contains('Thumbnail banano jayni'),
                contains('cover capture failed'),
                contains('hardware capture threw'),
                contains('no decoder'),
                contains('browser capture threw'),
                contains('cover tab never connected'),
              ))));
      expect(fbReq, isNull);
    });

    test('R2 thumb upload fails: upload is BLOCKED, no Firebase record',
        () async {
      // v159 SECOND PASS — a cover that cannot be uploaded to R2
      // is the same as no cover at all: the record is not pushed.
      // (The MP4 itself is already on R2 — an orphan file, which
      // is acceptable: the record is what matters.)
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client = mockPanelClient(
          r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r,
          failThumbUpload: true);
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => cover1620(),
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              allOf(contains('Thumbnail banano jayni'),
                  contains('cover R2 upload failed'),
                  contains('HTTP 500')))));
      expect(fbReq, isNull);
    });

    test('browser succeeds only at 2000ms: record carries thumbUrl',
        () async {
      // v159 second pass — the later timestamp: both paths fail
      // at 1000ms, the browser finds a frame at 2000ms.
      final tmp = Directory.systemTemp.createTempSync('v159_cover_');
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
          return timeMs == 2000 ? cover1620() : null;
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.firebaseKey, '-Nkey1');
      expect(hwCalls, [1000, 2000, 3000, 5000]);
      expect(browserCalls, [1000, 2000]);
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
      expect(r.coverError, isNull);
      final record =
          jsonDecode(utf8.decode(fbReq!.bodyBytes)) as Map<String, dynamic>;
      expect(record['thumbUrl'], r.thumbUrl);
    });

    test('default browser capture skips on this platform', () async {
      // The real browser capture only runs on Android (the gecko
      // bridge); in flutter_test (a desktop host) it returns null
      // without touching the channel — the graceful desktop skip.
      expect(await captureVideoCoverViaBrowser('/tmp/no_such_video.mp4'),
          isNull);
    });
  });

  group('v159 cover failure in the persisted error log', () {
    test('coverError is logged with its step and survives reload',
        () async {
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        panelUploader: (v, {targetAccount = 'spread'}) async => (
          accountName: 'zedge_1',
          firebaseKey: '-Nk',
          metadata: null,
          thumbUrl: null,
          coverError:
              'cover capture failed: hardware + browser capture '
              'returned no frame (1000ms + 0ms each)',
        ),
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      expect(await engine.uploadVideoToPanel(engine.videos.first), isTrue);
      // The video uploaded — but the reason its card has no cover
      // is in the error log, naming the step.
      expect(engine.errorLog, hasLength(1));
      expect(engine.errorLog.first, contains('Cover (anim_v159.mp4)'));
      expect(engine.errorLog.first, contains('cover capture failed'));
      // Persisted: a fresh engine loading the same prefs sees it.
      final reloaded = AnimationEngine();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.errorLog, hasLength(1));
      expect(reloaded.errorLog.first, contains('cover capture failed'));
    });

    test('no coverError, no log entry', () async {
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
      expect(engine.errorLog, isEmpty);
    });

    test('thumbnail block: upload fails, error logged, video stays',
        () async {
      // v159 SECOND PASS — the StudioEngine throws before the
      // Firebase push when no cover could be made. The engine
      // surfaces it in the status AND the persisted error log
      // (step + exception), and the video is NOT marked uploaded
      // — it stays on the device so he can retry the upload.
      SharedPreferences.setMockInitialValues({});
      final engine = AnimationEngine(
        panelUploader: (v, {targetAccount = 'spread'}) async {
          throw Exception(
              'Thumbnail banano jayni — video Panel-e pathano hoyni. '
              'cover capture failed: hardware + browser capture '
              'returned no frame (1000ms + 0ms + 2000ms each). '
              'Video device-e ache, thumbnail thik hole abar upload korte parben.');
        },
      );
      addTearDown(engine.dispose);
      engine.videos = [video(id: 'v1')];
      expect(await engine.uploadVideoToPanel(engine.videos.first),
          isFalse);
      expect(engine.videos.first.isUploaded, isFalse);
      expect(engine.status, contains('Thumbnail banano jayni'));
      expect(engine.errorLog, hasLength(1));
      expect(engine.errorLog.first, contains('Cover (anim_v159.mp4)'));
      expect(engine.errorLog.first, contains('Thumbnail banano jayni'));
      expect(engine.errorLog.first, contains('cover capture failed'));
      // Persisted: a fresh engine loading the same prefs sees it.
      final reloaded = AnimationEngine();
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.errorLog, hasLength(1));
      expect(reloaded.errorLog.first, contains('Thumbnail banano jayni'));
    });
  });
}
