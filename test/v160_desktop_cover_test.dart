// v160 — desktop cover capture through headless Chrome (CDP).
//
// v159's thumbnail guarantee ("ki hoy hok thumbnail jeno jay")
// blocked every desktop upload: on Windows the hardware capture
// (video_thumbnail plugin, Android/iOS only) returns null and
// the Gecko browser-canvas fallback returns null too, so no
// cover could ever be made. v160 adds a third capture path —
// headless Chrome on its own cover profile loads the local MP4
// and canvas-draws one frame at FULL native size (1620x2880,
// no downscale) — so the guarantee now holds on Windows too.
//
// The real Chrome path cannot run in flutter_test (no Chrome
// binary on this VM, and the function returns null on
// non-Windows by design), so the engine tests below inject a
// fake chrome seam, exactly like the v158/v159 hardware and
// browser seams. The pure canvas script is tested directly:
// it must draw at videoWidth x videoHeight with no scaling.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:gemini_hd_studio/video_cover.dart';

void main() {
  AnimationVideo video({
    required String id,
    String localPath = '/tmp/anim_v160.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'fire magnetic charging animation',
        prompt: 'fire magnetic charging animation',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v160.mp4',
        width: 1620,
        height: 2880,
        fps: 30,
        durationSec: 6,
        createdAt: DateTime.now(),
        metadata: SetMetadata(
          title: 'Neon Blue Phone',
          description: 'A neon blue phone charging.',
          tags: ['neon', 'phone', 'charging'],
          category: 'DESIGNS',
          generatedAtMs: 1,
        ),
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

  Future<AnimationVideo> videoFile(Directory tmp) async {
    final path = '${tmp.path}/anim_v160.mp4';
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    return video(id: 'v1', localPath: path);
  }

  group('v160 chrome cover script', () {
    test('draws at full native size, no downscale, at the asked time',
        () {
      final script = chromeCoverScript(1.0);
      // Full native size: canvas takes the video's own size.
      expect(script, contains('c.width = v.videoWidth'));
      expect(script, contains('c.height = v.videoHeight'));
      expect(script, contains("toDataURL('image/jpeg', 0.85)"));
      // The asked timestamp is embedded in the call.
      expect(script, contains('})(1.0)'));
      // No scaling anywhere: no maxWidth/maxHeight, no Math.min
      // downscale, no fixed small size.
      expect(script, isNot(contains('maxWidth')));
      expect(script, isNot(contains('maxHeight')));
      expect(script, isNot(contains('Math.min')));
      // Seeks the page's <video> element.
      expect(script, contains('document.querySelector(\'video\')'));
      expect(script, contains('v.currentTime = t'));
    });

    test('script embeds each fallback timestamp', () {
      expect(chromeCoverScript(0.0), contains('})(0.0)'));
      expect(chromeCoverScript(2.0), contains('})(2.0)'));
    });

    test('real chrome capture returns null on this (non-Windows) host',
        () async {
      // No Chrome binary is launched here: the function guards
      // on Platform.isWindows before touching anything.
      expect(await captureVideoCoverViaChrome('/tmp/no_such_video.mp4'),
          isNull);
      expect(await captureVideoCoverViaChrome('/tmp/no_such_video.mp4',
          timeMs: 0), isNull);
    });
  });

  group('v160 chrome cover in the panel upload', () {
    test('chrome is the third path: hw + browser null, chrome works',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v160_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final hwCalls = <int>[];
      final browserCalls = <int>[];
      final chromeCalls = <int>[];
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
        chromeCoverCapture: (path, {int timeMs = 1000}) async {
          chromeCalls.add(timeMs);
          return cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.accountName, 'zedge_1');
      expect(r.firebaseKey, '-Nkey1');
      // Both earlier paths were exhausted first (three
      // timestamps each) before Chrome was tried.
      expect(hwCalls, [1000, 0, 2000]);
      expect(browserCalls, [1000, 0, 2000]);
      // Chrome found a frame on its first try (~1s in).
      expect(chromeCalls, [1000]);
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

    test('chrome never runs when hardware succeeds', () async {
      final tmp = Directory.systemTemp.createTempSync('v160_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final chromeCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => cover1620(),
        chromeCoverCapture: (path, {int timeMs = 1000}) async {
          chromeCalls.add(timeMs);
          return cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(chromeCalls, isEmpty);
    });

    test('chrome fallback: 1000ms fails, first frame works', () async {
      final tmp = Directory.systemTemp.createTempSync('v160_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final chromeCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => null,
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
        chromeCoverCapture: (path, {int timeMs = 1000}) async {
          chromeCalls.add(timeMs);
          return timeMs == 1000 ? null : cover1620();
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(chromeCalls, [1000, 0]);
    });

    test('all three paths null: upload is BLOCKED, no Firebase record',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v160_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final chromeCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => null,
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
        chromeCoverCapture: (path, {int timeMs = 1000}) async {
          chromeCalls.add(timeMs);
          return null;
        },
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              contains('Thumbnail banano jayni'))));
      expect(fbReq, isNull);
      // Chrome got the same three tries as the other paths.
      expect(chromeCalls, [1000, 0, 2000]);
      expect(
          r2Reqs
              .where((req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
    });

    test('chrome throws (no Chrome installed): upload BLOCKED, error '
        'names Chrome', () async {
      final tmp = Directory.systemTemp.createTempSync('v160_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async => null,
        browserCoverCapture: (path, {int timeMs = 1000}) async => null,
        chromeCoverCapture: (path, {int timeMs = 1000}) async =>
            throw Exception('Chrome khola jayni — Windows-e cover '
                'banate Chrome, Edge ba Brave install koro.'),
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              allOf(contains('Thumbnail banano jayni'),
                  contains('chrome capture threw'),
                  contains('Chrome khola jayni')))));
      expect(fbReq, isNull);
    });
  });
}
