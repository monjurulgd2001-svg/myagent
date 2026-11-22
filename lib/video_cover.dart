// v158 — cover frame for a finished animation video, sent to
// the panel as the queue record's thumbUrl so the panel shows a
// preview instead of an empty card (QueueItem.previewUrl returns
// thumbUrl for video types). Mirrors the panel's own video upload,
// which captures a cover frame and uploads it beside the MP4.
//
// The capture runs through the video_thumbnail plugin
// (MediaMetadataRetriever on Android). The plugin has NO Windows /
// macOS / web implementation, so on desktop this returns null
// without ever calling the channel.
// v159 SECOND PASS — the "no cover, no upload" guarantee: a total
// capture failure no longer means "upload without a cover" —
// StudioEngine throws before the Firebase record is pushed, so
// the video stays on the device for a retry instead of reaching
// the panel thumbnail-less (the v158 behaviour is revoked).
//
// Cover size (user order 2026-11-22: "Cover size kintu
// 1620x2880"): the frame is captured at the video's FULL native
// resolution — maxWidth/maxHeight stay 0, which the plugin
// documents (and its Android source confirms) means "same
// resolution as the original video", so a 1620x2880 clip yields
// a 1620x2880 cover. There is deliberately no size parameter on
// the capture seam, so no caller can downscale it by accident.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'cdp.dart';
import 'chromium_browser.dart';

/// The capture seam: (video path, timeMs) -> JPEG bytes, or null
/// when no frame could be captured. Injected into StudioEngine
/// so tests can fake it (the real plugin needs a real video file
/// on a real Android device).
typedef VideoCoverCapture = Future<Uint8List?> Function(
  String videoPath, {
  int timeMs,
});

// v162 — brightness gate for cover frames.
//
// Live 2026-11-22 the "Crimson Facet Tree" panel tile was BLACK —
// the record DID carry a thumbUrl, but the JPEG itself was a
// near-black frame: Dark Moody opens with a fade from black, and
// the capture accepted the FIRST non-empty frame (~1s) without
// ever looking at the pixels. Every candidate frame is now
// measured and a frame below [kCoverMinLuminance] is rejected
// (StudioEngine tries the next timestamp instead).
//
// The gate is measured HERE in Dart, from the exact JPEG bytes
// that get uploaded, on EVERY capture path — deliberately NOT in
// the JS canvas scripts: the Kotlin bridge returns ByteArray
// only, so a JS-side luma would need a new channel return type
// plus content-script/background.js changes in the user's patched
// extension, and a JS-side reject (return null) would make the
// brightest-frame fallback impossible, since a rejected frame
// never reaches Dart. One meter, one threshold, all paths.

/// A cover frame counts as a visible thumbnail only at or above
/// this average luminance (0–255). Below it the panel tile reads
/// as black to the eye. 10 is deliberately low: a genuinely dark
/// but visible scene (Dark Moody: dark slate + glowing crimson
/// facets) still measures well above it, because any visible
/// highlights or mid-tones lift the frame mean; a fade-from-black
/// opening measures ~0–5. And the threshold can never strand an
/// upload — when no sampled frame passes, StudioEngine uploads
/// the brightest sampled frame instead of blocking.
const double kCoverMinLuminance = 10.0;

/// Average luminance (Rec. 601 luma, 0–255) of a cover-frame
/// JPEG, measured from the decoded pixels — downscaled to 32x32
/// first (a 1620x2880 decode is only ever read at 32x32, so the
/// meter costs one small resize, not a full-res pixel walk).
/// Returns null when the bytes are not a decodable image; the
/// caller treats unmeasurable bytes as acceptable rather than
/// blocking an upload on a meter failure (the capture paths
/// return real JPEGs in practice — a null here means a bug, not
/// a dark frame).
double? coverFrameLuminance(Uint8List jpegBytes) {
  try {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return null;
    final small = img.copyResize(decoded, width: 32, height: 32);
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y < small.height; y++) {
      for (var x = 0; x < small.width; x++) {
        final p = small.getPixel(x, y);
        sum += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
        n++;
      }
    }
    if (n == 0) return null;
    return sum / n;
  } catch (_) {
    return null;
  }
}

/// Captures one frame at [timeMs] into the video, at full native
/// resolution, as a JPEG. Returns null on desktop (no plugin
/// implementation there) and on any failure.
Future<Uint8List?> captureVideoCover(
  String videoPath, {
  int timeMs = 1000,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  try {
    final bytes = await VideoThumbnail.thumbnailData(
      video: videoPath,
      imageFormat: ImageFormat.JPEG,
      // 0 = native resolution (1620x2880 for a 1620x2880 clip).
      // Never pass a maxWidth/maxHeight here.
      maxWidth: 0,
      maxHeight: 0,
      timeMs: timeMs,
      quality: 85,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

// v159 — browser-canvas fallback for [captureVideoCover].
//
// Live 2026-11-22: the hardware path above returned null for a
// valid Gemini MP4 (H.264 High @ Level 5.2, 1620x2880 @ 60fps) on
// TECNO CAMON 30S — the phone's hardware decoder cannot decode
// it, the same decoder that already failed video preview in v156
// (Chrome plays the file fine because Chrome software-decodes).
// Gecko bundles its own software decoders, so the frame is
// captured through a hidden headless Gecko session instead:
// Kotlin opens a SEPARATE session on file://<mp4> (the backend
// session must stay on the Gemini page), the extension's content
// script seeks the video to [timeMs] and canvas-draws the frame
// at FULL native size (1620x2880 — never downscaled, JPEG 0.85,
// mirroring the panel's own submitVideo canvas capture) and the
// JPEG bytes come back over the `gecko` channel.
//
// Same seam shape as [captureVideoCover] so StudioEngine can
// inject a fake in tests. Returns null on desktop (no Gecko
// bridge there — the graceful skip stays), when the bridge
// cannot answer, or when the page reports a failure; it never
// throws. v159 second pass: a null here no longer means "upload
// without a cover" — StudioEngine turns a total capture failure
// into a blocking error before the Firebase push, so the video
// stays on the device for a retry.
// This channel object never sets a method-call handler —
// GeckoBrowser owns the incoming calls on this channel name.
Future<Uint8List?> captureVideoCoverViaBrowser(
  String videoPath, {
  int timeMs = 1000,
}) async {
  if (!Platform.isAndroid) return null;
  try {
    final bytes = await const MethodChannel('com.geminihd.studio/gecko')
        .invokeMethod<Uint8List>(
      'captureVideoCover',
      // JSON string, like the other gecko calls (browserVideoHeadless).
      jsonEncode({'path': videoPath, 'timeMs': timeMs}),
    );
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

// v160 — desktop cover capture through headless Chrome (CDP).
//
// The video_thumbnail plugin has no desktop implementation and
// there is no Gecko bridge on Windows, so on desktop the frame
// is captured the way Chrome itself plays the file: a headless
// Chrome on its own cover profile (chromium-profile-cover —
// never the visible browser's profile, never the video driver's
// chromium-profile-video, so it cannot fight either) loads the
// local MP4 and canvas-draws one frame at FULL native size via
// [chromeCoverScript]. Same seam shape as [captureVideoCover]
// so StudioEngine can inject a fake in tests.
//
// Returns null on non-Windows and when Chrome loads the file
// but finds no frame. THROWS (never returns null) when Chrome
// cannot be started or reached, so the caller can name the
// step in the error log — the thumbnail guarantee then blocks
// the upload with that reason instead of shipping a
// thumbnail-less record.

/// The canvas-capture script run inside headless Chrome for
/// [captureVideoCoverViaChrome]: seeks the page's <video> to
/// [timeSec] and canvas-draws the frame at the video's FULL
/// native size (videoWidth x videoHeight — never downscaled),
/// returning a JPEG data URL (0.85). Pure function so tests can
/// assert the capture never shrinks the frame.
String chromeCoverScript(double timeSec) => '''
(async (t) => {
  const v = document.querySelector('video');
  if (!v) return '';
  try { await v.play(); } catch (e) {}
  v.pause();
  if (v.readyState < 1) {
    await new Promise((res, rej) => {
      const to = setTimeout(() => rej(new Error('metadata timeout')), 15000);
      v.onloadedmetadata = () => { clearTimeout(to); res(); };
    });
  }
  if (!v.videoWidth || !v.videoHeight) return '';
  await new Promise((res, rej) => {
    if (Math.abs(v.currentTime - t) < 0.01) return res();
    const to = setTimeout(() => rej(new Error('seek timeout')), 15000);
    v.onseeked = () => { clearTimeout(to); res(); };
    v.currentTime = t;
  });
  const c = document.createElement('canvas');
  c.width = v.videoWidth;
  c.height = v.videoHeight;
  c.getContext('2d').drawImage(v, 0, 0);
  return c.toDataURL('image/jpeg', 0.85);
})($timeSec)''';

/// The cover browser's own Chrome profile (never the visible
/// browser's chromium-profile, never the video driver's
/// chromium-profile-video — two Chrome processes cannot share
/// one profile, and the cover capture must never fight either).
Future<String> _chromeCoverProfileDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(
      '${base.path}${Platform.pathSeparator}chromium-profile-cover');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir.path;
}

/// Reads `DevToolsActivePort` (written by Chromium when started
/// with `--remote-debugging-port=0`) and returns the browser
/// WebSocket URL.
String? _readChromeWsUrl(String profileDir) {
  final f = File('$profileDir${Platform.pathSeparator}DevToolsActivePort');
  if (!f.existsSync()) return null;
  try {
    final lines = f
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final port = int.tryParse(lines[0]);
    if (port == null || port <= 0) return null;
    return 'ws://127.0.0.1:$port${lines[1]}';
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> captureVideoCoverViaChrome(
  String videoPath, {
  int timeMs = 1000,
}) async {
  if (!Platform.isWindows) return null;
  final exe = ChromiumBrowser.findExecutable();
  if (exe == null) {
    throw Exception('Chrome khola jayni — Windows-e cover banate '
        'Chrome, Edge ba Brave install koro, tarpor abar upload koro.');
  }
  final profile = await _chromeCoverProfileDir();
  CdpConnection? cdp;
  Process? proc;
  String? targetId;
  try {
    // Re-attach to a cover browser left over from an earlier run.
    final existing = _readChromeWsUrl(profile);
    if (existing != null) {
      try {
        cdp = await CdpConnection.connect(existing,
            timeout: const Duration(seconds: 3));
        await cdp.send('Browser.getVersion');
      } catch (_) {
        try {
          await cdp?.close();
        } catch (_) {}
        cdp = null;
      }
    }
    if (cdp == null) {
      try {
        final f = File(
            '$profile${Platform.pathSeparator}DevToolsActivePort');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      proc = await Process.start(exe, [
        '--remote-debugging-port=0',
        '--user-data-dir=$profile',
        '--headless=new',
        '--no-first-run',
        '--no-default-browser-check',
        '--mute-audio',
        '--autoplay-policy=no-user-gesture-required',
        'about:blank',
      ], mode: ProcessStartMode.detached);
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      var exited = false;
      proc.exitCode.then((_) => exited = true);
      String? ws;
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline) && !exited) {
        await Future.delayed(const Duration(milliseconds: 250));
        ws = _readChromeWsUrl(profile);
        if (ws != null) break;
      }
      if (ws == null) {
        throw Exception('Headless Chrome start hoyni — Chrome-er '
            'shob window bondho kore abar try koro.');
      }
      Object? lastErr;
      for (var i = 0; i < 12 && cdp == null; i++) {
        try {
          cdp = await CdpConnection.connect(ws);
        } catch (e) {
          lastErr = e;
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      if (cdp == null) {
        throw Exception(
            'Headless Chrome-er sathe connect hoyni: $lastErr');
      }
    }
    final t = await cdp.send('Target.createTarget',
        params: {'url': 'about:blank', 'background': true});
    targetId = t['targetId'] as String?;
    if (targetId == null) {
      throw Exception('Headless browser-e tab khulte parlam na.');
    }
    final a = await cdp.send('Target.attachToTarget',
        params: {'targetId': targetId, 'flatten': true});
    final sid = a['sessionId'] as String?;
    if (sid == null) {
      throw Exception('Headless browser-e tab attach hoyni.');
    }
    // Load the local MP4 — Chrome's own media page gives us a
    // <video> element for the file, no page of our own needed.
    final fileUri = Uri.file(videoPath).toString();
    await cdp.send('Page.navigate', params: {'url': fileUri},
        sessionId: sid);
    // Wait for the video element to exist (up to 20s).
    var hasVideo = false;
    final videoDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(videoDeadline)) {
      try {
        final r = await cdp.send('Runtime.evaluate',
            params: {
              'expression':
                  'document.querySelector("video") ? "yes" : "no"',
              'returnByValue': true,
              'silent': true,
            },
            sessionId: sid,
            timeout: const Duration(seconds: 5));
        if ((r['result'] as Map?)?['value'] == 'yes') {
          hasVideo = true;
          break;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!hasVideo) return null;
    final r = await cdp.send('Runtime.evaluate',
        params: {
          'expression': chromeCoverScript(timeMs / 1000),
          'awaitPromise': true,
          'returnByValue': true,
        },
        sessionId: sid,
        timeout: const Duration(seconds: 30));
    final value = (r['result'] as Map?)?['value']?.toString() ?? '';
    if (!value.startsWith('data:image/jpeg')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    final bytes = base64Decode(value.substring(comma + 1));
    if (bytes.isEmpty) return null;
    return bytes;
  } finally {
    // Always close the tab and the browser we started — a
    // leftover headless Chrome would hold the cover profile.
    try {
      if (targetId != null && cdp != null) {
        await cdp.send('Target.closeTarget',
            params: {'targetId': targetId},
            timeout: const Duration(seconds: 5));
      }
    } catch (_) {}
    try {
      await cdp?.send('Browser.close',
          timeout: const Duration(seconds: 5));
    } catch (_) {}
    try {
      await cdp?.close();
    } catch (_) {}
    try {
      if (proc != null) {
        await proc.exitCode
            .timeout(const Duration(seconds: 8), onTimeout: () {
          try {
            proc!.kill();
          } catch (_) {}
          return -1;
        });
      }
    } catch (_) {}
    try {
      final f = File(
          '$profile${Platform.pathSeparator}DevToolsActivePort');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
