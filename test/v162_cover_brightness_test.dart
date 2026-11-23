// v162 — brightness-gated cover capture.
//
// Live 2026-11-22 the "Crimson Facet Tree" panel tile was BLACK —
// the record DID carry a thumbUrl, but the JPEG itself was a
// near-black frame: Dark Moody opens with a fade from black, and
// the old capture accepted the FIRST non-empty frame (~1s)
// without ever looking at the pixels. v162 measures every
// candidate frame ([coverFrameLuminance]) and rejects frames
// below [kCoverMinLuminance]; timestamps per path are now 1s, 2s,
// 3s, 5s, then mid-video when the duration is known — first
// frame at/above the threshold wins. If NO sampled frame passes
// anywhere, the BRIGHTEST sampled frame is uploaded instead of
// blocking (darkness alone never blocks; the v159 guarantee only
// fires when NO frame bytes exist at all).
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
    double durationSec = 10,
    String localPath = '/tmp/anim_v162.mp4',
  }) =>
      AnimationVideo(
        id: id,
        title: 'crimson facet tree',
        prompt: 'crimson facet tree',
        modelId: 'neon',
        styleId: 'dark-moody',
        requestedDurationSec: 10,
        localPath: localPath,
        fileName: 'anim_v162.mp4',
        width: 1620,
        height: 2880,
        fps: 60,
        durationSec: durationSec,
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
      {double durationSec = 10}) async {
    final path = '${tmp.path}/anim_v162.mp4';
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    return video(id: 'v1', localPath: path, durationSec: durationSec);
  }

  group('v162 coverFrameLuminance', () {
    test('black ~0, dark gray ~8, mid-dark ~25, orange ~111', () {
      expect(coverFrameLuminance(grayJpeg(0)), closeTo(0, 2));
      expect(coverFrameLuminance(grayJpeg(8)), closeTo(8, 2));
      expect(coverFrameLuminance(grayJpeg(25)), closeTo(25, 2));
      final orange = img.Image(width: 64, height: 64);
      img.fill(orange, color: img.ColorRgb8(255, 80, 0));
      final orangeBytes =
          Uint8List.fromList(img.encodeJpg(orange, quality: 85));
      // Rec. 601: 0.2126*255 + 0.7152*80 = ~111.
      expect(coverFrameLuminance(orangeBytes), closeTo(111, 3));
    });

    test('garbage bytes measure null, never a number', () {
      expect(coverFrameLuminance(Uint8List.fromList([1, 2, 3])), isNull);
      expect(coverFrameLuminance(Uint8List(0)), isNull);
    });

    test('threshold sits between a black frame and a visible dark one',
        () {
      expect(kCoverMinLuminance, 10.0);
      expect(8.0, lessThan(kCoverMinLuminance));
      expect(25.0, greaterThanOrEqualTo(kCoverMinLuminance));
    });
  });

  group('v162 brightness gate in the panel upload', () {
    test('black frame at 3000ms rejected, bright frame at 3500ms chosen',
        () async {
      // The live bug, replayed: Dark Moody's ~1s frame is a
      // fade-from-black, so the old code shipped it as the cover.
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final hwCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          if (timeMs == 3000) return grayJpeg(0);
          if (timeMs == 3500) return grayJpeg(200);
          return null;
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(r.thumbUrl, contains('_thumb.jpg'));
      expect(r.coverError, isNull);
      // v168 — the whole 3-4s window is sampled.
      expect(hwCalls, kCoverWindowTimesMs);
      // And the uploaded thumb is the BRIGHT frame, not the black one.
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(200, 3));
    });

    test('dark-but-visible frame is accepted', () async {
      // A real dark scene (luma ~25) is NOT a black frame — the
      // gate must accept it (it never falls through to other paths).
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final hwCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          return grayJpeg(25);
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(hwCalls, kCoverWindowTimesMs);
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(25, 3));
    });

    test('all-black video uses the brightest frame, upload NOT blocked',
        () async {
      // No frame anywhere passes the gate — but the upload must
      // still go through with the brightest sampled frame (luma
      // 8 at 3250ms here), never blocked for darkness alone.
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      http.Request? fbReq;
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (r) => fbReq = r);
      final hwCalls = <int>[];
      final grayByTime = {3000: 0, 3250: 8, 3500: 3, 3750: 6};
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          final g = grayByTime[timeMs];
          return g == null ? null : grayJpeg(g);
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.firebaseKey, '-Nkey1');
      expect(r.thumbUrl, isNotNull);
      expect(r.coverError, isNull);
      expect(fbReq, isNotNull);
      // Every timestamp of the 3-4s window was tried.
      expect(hwCalls, kCoverWindowTimesMs);
      // Brightest sampled frame (luma 8 at 3250ms) was uploaded.
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(8, 3));
    });

    test('short clip: the window collapses inside the clip (3s)', () async {
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final hwCalls = <int>[];
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          hwCalls.add(timeMs);
          return timeMs == 1500 ? grayJpeg(150) : null;
        },
      );
      final r = await engine.uploadVideoToPanel(
          await videoFile(tmp, durationSec: 3));
      expect(r.thumbUrl, isNotNull);
      // A 3s clip has no 3-4s window (it ends at 2960ms): five
      // points are spread across its middle instead.
      expect(hwCalls, [900, 1200, 1500, 1800, 2100]);
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(150, 3));
    });

    test('the BRIGHTEST frame of the 3-4s window wins, not the first',
        () async {
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      setDistConfig();
      final r2Reqs = <http.Request>[];
      final client =
          mockPanelClient(r2Reqs: r2Reqs, onFirebase: (_) {});
      final grayByTime = {3000: 40, 3250: 90, 3500: 200, 3750: 120, 4000: 60};
      final engine = StudioEngine(
        client: client,
        coverCapture: (path, {int timeMs = 1000}) async {
          final g = grayByTime[timeMs];
          return g == null ? null : grayJpeg(g);
        },
      );
      final r = await engine.uploadVideoToPanel(await videoFile(tmp));
      expect(r.thumbUrl, isNotNull);
      expect(thumbGray(thumbReqOf(r2Reqs)), closeTo(200, 3));
    });

    test('guarantee still blocks when no frame bytes exist at all',
        () async {
      // The v159 guarantee, unchanged: null from every path is
      // still a block, not a brightest-frame fallback (there is
      // no frame to fall back to).
      final tmp = Directory.systemTemp.createTempSync('v162_cover_');
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
        chromeCoverCapture: (path, {int timeMs = 1000}) async => null,
      );
      await expectLater(
          engine.uploadVideoToPanel(await videoFile(tmp)),
          throwsA(isA<Exception>().having((e) => '$e', 'message',
              contains('Thumbnail banano jayni'))));
      expect(fbReq, isNull);
      expect(
          r2Reqs
              .where((req) => req.headers['X-File-Type'] == 'image/jpeg'),
          isEmpty);
    });
  });
}
