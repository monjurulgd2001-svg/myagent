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
///
/// v166 — wait for a PRESENTED frame before drawing (same defect
/// as content.js onCapture): the old play() -> immediate pause()
/// never presented a frame in a headless tab, so every draw was
/// a blank/black canvas. After the seek, requestVideoFrameCallback
/// (fires only when a frame is actually presented) is awaited
/// with a timeout fallback; when it never fires, the video plays
/// briefly so the decoder presents the seek target, then draws.
/// Never hangs on the wait.
///
/// v167 — the drawn canvas is sampled before it is returned: a
/// black canvas returns '' (no frame) instead of a black JPEG,
/// and the seek is followed by a wait for HAVE_FUTURE_DATA
/// (readyState >= 3) so the decoder has data to present.
String chromeCoverScript(double timeSec) => '''
(async (t) => {
  const v = document.querySelector('video');
  if (!v) return '';
  // v166 — prime the decoder by REALLY playing for a moment.
  try { await v.play(); await new Promise(r => setTimeout(r, 400)); } catch (e) {}
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
  // v167 — wait until the decoder actually has future data
  // (HAVE_FUTURE_DATA) before asking for a presented frame; a
  // seek landing on metadata alone still draws blank.
  await new Promise((res) => {
    const to = setTimeout(res, 3000);
    const check = () => {
      if (v.readyState >= 3) { clearTimeout(to); res(); return; }
      setTimeout(check, 100);
    };
    check();
  });
  let presented = false;
  await new Promise((res) => {
    const to = setTimeout(res, 3000);
    try {
      if (typeof v.requestVideoFrameCallback === 'function') {
        v.requestVideoFrameCallback(() => { presented = true; clearTimeout(to); res(); });
      } else { clearTimeout(to); res(); }
    } catch (e) { clearTimeout(to); res(); }
  });
  if (!presented) {
    try { await v.play(); await new Promise(r => setTimeout(r, 300)); } catch (e) {}
    v.pause();
  }
  const c = document.createElement('canvas');
  c.width = v.videoWidth;
  c.height = v.videoHeight;
  c.getContext('2d').drawImage(v, 0, 0);
  // v167 — never hand back a blank canvas as a frame: sample
  // the drawn pixels first; a black canvas (no frame was ever
  // presented in this headless tab) returns '' so the caller
  // treats it as "no frame" instead of a black thumbnail.
  const probe = document.createElement('canvas');
  probe.width = 32; probe.height = 32;
  let blank = false;
  try {
    const pctx = probe.getContext('2d');
    pctx.drawImage(c, 0, 0, 32, 32);
    const d = pctx.getImageData(0, 0, 32, 32).data;
    let sum = 0; let n = 0;
    for (let i = 0; i < d.length; i += 4) {
      sum += 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
      n++;
    }
    blank = n > 0 && sum / n < 10;
  } catch (e) {}
  if (blank) return '';
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

// v166 — native cover capture, the panel's recipe
// (VideoUtils.captureFrames in the Zedge Content Studio panel):
// MediaMetadataRetriever, frames at duration percentages, with
// a 4-option fallback per timestamp. The panel's own submitVideo
// proves this API decodes Gemini's H.264 High @ 5.2
// 1620x2880@60fps files on this phone — the video_thumbnail
// plugin's single-option call returns null for the same files,
// so this channel is the FIRST capture path now (the plugin
// stays as a later fallback). Same seam shape as
// [captureVideoCover] so StudioEngine can inject a fake in
// tests. Returns null on non-Android and on any failure.
Future<Uint8List?> captureVideoCoverViaRetriever(
  String videoPath, {
  int timeMs = 1000,
}) async {
  // v168 — a point of the 3-4s cover window asks the native side
  // for the WHOLE window in one call and caches it: the native
  // software decoder decodes the clip once for all five points
  // (instead of once per point), and the cover sampler's next
  // four calls are answered from the cache.
  final cached = _retrieverBatchCache[videoPath];
  if (cached != null && cached.containsKey(timeMs)) return cached[timeMs];
  final batch = kCoverWindowTimesMs.contains(timeMs);
  final points = batch ? List<int>.of(kCoverWindowTimesMs) : [timeMs];
  final frames = await captureCoverFramesViaRetriever(
    videoPath,
    pointsMs: points,
  );
  if (frames.isEmpty) return null;
  if (batch) {
    _retrieverBatchCache
      ..clear()
      ..[videoPath] = {
        for (var i = 0; i < points.length && i < frames.length; i++)
          points[i]: frames[i],
      };
  }
  final at = points.indexOf(timeMs);
  return at >= 0 && at < frames.length ? frames[at] : null;
}

/// v168 — the last retriever batch (one video path at a time).
final Map<String, Map<int, Uint8List?>> _retrieverBatchCache = {};

/// One native-channel call returning the JPEG bytes for every
/// requested timestamp, in the same order as [pointsMs] (a null
/// slot means that timestamp yielded no frame). The channel is
/// `com.geminihd.studio/video_cover` (VideoCoverBridge.kt) — NOT
/// the gecko channel, so it works without any browser session.
/// Returns [] on non-Android and on any failure.
Future<List<Uint8List?>> captureCoverFramesViaRetriever(
  String videoPath, {
  required List<int> pointsMs,
}) async {
  if (!Platform.isAndroid) return [];
  if (pointsMs.isEmpty) return [];
  try {
    final raw = await const MethodChannel('com.geminihd.studio/video_cover')
        .invokeMethod<List<dynamic>>('captureCoverFrames', {
      'path': videoPath,
      'pointsMs': pointsMs,
    });
    if (raw == null) return [];
    return [
      for (final f in raw)
        if (f is Uint8List && f.isNotEmpty) f else null,
    ];
  } catch (_) {
    return [];
  }
}

// v166 — the panel's frame points, as fractions of the video
// duration (VideoUtils.FRAME_POINTS in the panel): 8% / 28% /
// 50% / 72% / 92% — the middle frame is the default pick there,
// and the spread means a fade-in from black is over by the
// second point.
const List<double> kCoverCandidateFractions = [0.08, 0.28, 0.50, 0.72, 0.92];

/// v168 — the cover window (user order 2026-11-23: the cover is
/// taken automatically from the ORIGINAL video at 3-4 seconds, no
/// manual picking needed): the automatic cover is the BEST frame
/// sampled between 3s and 4s of the clip. 3s is well past the
/// usual fade-in from black; 4s keeps the cover representative of
/// the opening. The manual picker (optional) offers the same points.
const List<int> kCoverWindowTimesMs = [3000, 3250, 3500, 3750, 4000];

/// The timestamps (ms) sampled for the cover of a clip of
/// [durationSec] (0 = unknown, the fixed window). Each point is
/// coerced inside the clip like the panel does (duration - 40ms);
/// a clip shorter than the window collapses the clamped points
/// (deduped, order kept). A clip under 3s has no 3-4s window at
/// all, so five points are spread across its middle instead.
List<int> coverWindowTimesMs(double durationSec) {
  if (durationSec <= 0) return List<int>.of(kCoverWindowTimesMs);
  final totalMs = (durationSec * 1000).round();
  final maxMs = totalMs - 40 > 0 ? totalMs - 40 : totalMs;
  if (maxMs < kCoverWindowTimesMs.first) {
    return [
      for (final f in const [0.3, 0.4, 0.5, 0.6, 0.7])
        (totalMs * f).round().clamp(0, maxMs),
    ];
  }
  final out = <int>[];
  for (final t in kCoverWindowTimesMs) {
    final c = t > maxMs ? maxMs : t;
    if (!out.contains(c)) out.add(c);
  }
  return out;
}

/// Candidate timestamps (ms) for the manual cover picker: the
/// same 3-4s window the automatic cover samples (v168; v166's
/// panel percentage points 8/28/50/72/92% are gone).
List<int> coverCandidateTimesMs(double durationSec) =>
    coverWindowTimesMs(durationSec);

/// One candidate cover frame for the manual picker: the
/// timestamp it was captured at, the full-res JPEG bytes, and
/// its measured luminance (null when unmeasurable — the frame
/// is still shown, the picker just cannot mark it dark).
class CoverCandidate {
  const CoverCandidate({
    required this.timeMs,
    required this.bytes,
    this.luma,
  });

  final int timeMs;
  final Uint8List bytes;
  final double? luma;

  bool get isDark => luma != null && luma! < kCoverMinLuminance;
}

/// v167 — the result of a candidate capture: the frames that
/// could be captured, plus a per-path diagnostic (which paths
/// failed and why) so the picker can say WHY the frames are
/// missing or dark instead of silently showing black frames.
/// [allDark] is true when frames exist but every one of them is
/// below the luminance gate.
class CoverCandidatesResult {
  const CoverCandidatesResult({required this.frames, this.diagnostic = ''});

  final List<CoverCandidate> frames;
  final String diagnostic;

  bool get allDark =>
      frames.isNotEmpty && frames.every((c) => c.isDark);
}

/// The candidates seam: (video path, timestamps) -> the frames
/// that could be captured, in timestamp order, plus a per-path
/// diagnostic. Injected into StudioEngine so tests can fake it
/// (the real paths need a real video file on a real device).
typedef CoverCandidatesCapture = Future<CoverCandidatesResult> Function(
  String videoPath, {
  required List<int> timesMs,
});

/// v166 — captures one frame per timestamp in [timesMs] for the
/// manual cover picker. First path with at least one frame wins
/// (paths are not merged — the native retriever already tries
/// every timestamp in one call): native retriever, plugin,
/// browser canvas, headless Chrome.
///
/// v167 — a path is ACCEPTED only when at least one of its
/// frames passes the luminance gate (an unmeasurable frame
/// counts as passing, per v162). Live 2026-11-23 the picker
/// showed five "ondhokar" frames for a BRIGHT icy video
/// ("Icy Energy Battery") because the first path's black frames
/// were accepted as success and the other paths never ran — the
/// v162 gate was never applied here. A path whose frames are
/// ALL dark is now treated as failed and the next path is
/// tried. When no path has a passing frame, the brightest set
/// is returned (v162 semantics) with a diagnostic naming it,
/// so the picker can say why instead of silently showing
/// black frames. The per-path capture functions are optional
/// overrides so tests can fake each path (the real ones need
/// a real video file on a real device).
Future<CoverCandidatesResult> captureCoverCandidates(
  String videoPath, {
  required List<int> timesMs,
  Future<List<Uint8List?>> Function(
    String videoPath, {
    required List<int> pointsMs,
  })? retrieverFrames,
  VideoCoverCapture? pluginCapture,
  VideoCoverCapture? browserCapture,
  VideoCoverCapture? chromeCapture,
}) async {
  final retriever = retrieverFrames ?? captureCoverFramesViaRetriever;
  final plugin = pluginCapture ?? captureVideoCover;
  final browser = browserCapture ?? captureVideoCoverViaBrowser;
  final chrome = chromeCapture ?? captureVideoCoverViaChrome;

  Future<List<CoverCandidate>> viaRetriever() async {
    final frames = await retriever(
      videoPath,
      pointsMs: timesMs,
    );
    return [
      for (var i = 0; i < timesMs.length && i < frames.length; i++)
        if (frames[i] != null)
          CoverCandidate(
            timeMs: timesMs[i],
            bytes: frames[i]!,
            luma: coverFrameLuminance(frames[i]!),
          ),
    ];
  }

  Future<List<CoverCandidate>> viaSingle(VideoCoverCapture capture) async {
    final out = <CoverCandidate>[];
    for (final t in timesMs) {
      try {
        final bytes = await capture(videoPath, timeMs: t);
        if (bytes == null || bytes.isEmpty) continue;
        out.add(CoverCandidate(
            timeMs: t, bytes: bytes, luma: coverFrameLuminance(bytes)));
      } catch (_) {
        // One timestamp failing must not kill the rest.
      }
    }
    return out;
  }

  final notes = <String>[];
  List<CoverCandidate>? brightest;
  var brightestMax = -1.0;
  final attempts = <(String, Future<List<CoverCandidate>> Function())>[
    ('retriever', viaRetriever),
    ('plugin', () => viaSingle(plugin)),
    ('browser', () => viaSingle(browser)),
    ('chrome', () => viaSingle(chrome)),
  ];
  for (final (name, run) in attempts) {
    final frames = await run();
    if (frames.isEmpty) {
      notes.add('$name: no frame');
      continue;
    }
    final maxLuma = frames
        .map((c) => c.luma ?? kCoverMinLuminance)
        .fold(0.0, (a, b) => a > b ? a : b);
    if (maxLuma > brightestMax) {
      brightestMax = maxLuma;
      brightest = frames;
    }
    if (frames.every((c) => c.isDark)) {
      notes.add('$name: ${frames.length}-ti frame-i ondhokar');
      continue;
    }
    final darkCount = frames.where((c) => c.isDark).length;
    if (darkCount > 0) notes.add('$name: $darkCount dark');
    return CoverCandidatesResult(
        frames: frames, diagnostic: notes.join('; '));
  }
  return CoverCandidatesResult(
    frames: brightest ?? [],
    diagnostic: notes.join('; '),
  );
}
