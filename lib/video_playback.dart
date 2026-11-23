// v153 — finished-video playback dispatch.
//
// v141 plays the MP4 inside the phone mockup (video_player) with
// the in-app browser as fallback — but the fallback, _playAnimation,
// called GeckoBrowser.open('file://...'), whose MethodChannel has
// no native side on Windows: MissingPluginException, unhandled.
// The in-frame player already degrades gracefully on Windows
// (device_mockup catches the initialise failure and offers the
// fallback button); this file makes the fallback real on Windows
// by opening the file in the user's own browser instead —
// ExternalBrowser has a genuine Windows implementation
// (chrome.exe / shell start). Android keeps the Gecko browser.
//
// Returns false instead of throwing when nothing could open it,
// so the caller can say so instead of crashing.
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'external_browser.dart';
import 'gecko_browser.dart';
import 'mp4_info.dart';

enum VideoPlaybackTarget { gecko, external }

/// Pure dispatch, so the platform rule is unit-testable.
VideoPlaybackTarget videoPlaybackTargetFor(TargetPlatform platform) =>
    platform == TargetPlatform.android
        ? VideoPlaybackTarget.gecko
        : VideoPlaybackTarget.external;

Future<bool> openVideoFile(String path,
    {TargetPlatform? platformOverride}) async {
  final target = videoPlaybackTargetFor(
      platformOverride ?? defaultTargetPlatform);
  final url = Uri.file(path).toString();
  try {
    if (target == VideoPlaybackTarget.gecko) {
      await GeckoBrowser.instance.open(url);
      return true;
    }
    return await ExternalBrowser.open(url);
  } catch (_) {
    return false;
  }
}

/// v156 — is this player failure the phone's hardware decoder
/// rejecting the stream (rather than a bad source)? Live
/// 2026-11-22: "PlatformException(VideoError, Video player had
/// error d0.k: MediaCodecVideoRenderer error, …)" on TECNO CAMON
/// 30S — the file was a valid MP4 that Chrome plays, ExoPlayer's
/// renderer refused it. Decoder errors fall back to the embedded
/// Gecko view inside the mockup; source errors keep the v154
/// message instead. Pure, so it is unit-testable.
bool isDecoderError(String message) {
  final m = message.toLowerCase();
  return m.contains('mediacodec') ||
      m.contains('renderer') ||
      m.contains('decoder');
}

int _moovU32(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

int _moovU64(Uint8List b, int off) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[off + i];
  }
  return v;
}

/// v156 — synchronously reads just the file's moov box (the
/// header; the media data is never read). Sync on purpose: async
/// file IO never completes in flutter_test's fake-async zone (see
/// videoPreviewProblem) and this runs on the preview dialog's
/// decoder-error path. Walks the top-level boxes, seeking past
/// mdat/free boxes of any size, and returns the moov box bytes
/// (header included) or null when the file has no moov box or
/// cannot be read. The caller feeds the bytes to [readMp4VideoCodec]
/// / [readMp4Info], which both find the moov box at offset 0.
Uint8List? readMp4MoovBytes(String path) {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    final length = raf.lengthSync();
    var pos = 0;
    while (pos + 8 <= length) {
      raf.setPositionSync(pos);
      final header = raf.readSync(8);
      if (header.length < 8) return null;
      var size = _moovU32(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1) {
        final ext = raf.readSync(8);
        if (ext.length < 8) return null;
        size = _moovU64(ext, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = length - pos;
      }
      if (size < headerSize) return null;
      if (type == 'moov') {
        if (size > 64 * 1024 * 1024) return null;
        raf.setPositionSync(pos);
        final bytes = raf.readSync(size);
        return bytes.length == size ? bytes : null;
      }
      pos += size;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

/// v154 — preview source resolution: the in-frame player only ever
/// gets a LOCAL file that exists and starts with an MP4 ftyp box.
/// Returns a Banglish problem message (naming the file) when the
/// file is missing or is not an MP4, else null. The caller shows
/// the message instead of letting ExoPlayer fail with a raw
/// PlatformException ("Source error", live 2026-11-22) — and a
/// remote URL needing auth is never passed to the player at all.
///
/// Synchronous on purpose: a 64-byte header read is sub-ms, and
/// async file IO never completes inside flutter_test's fake-async
/// zone — the dialog's _initVideo would hang on the check there.
String? videoPreviewProblem(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return 'Video file-ti pawa jayni: $path — abar Generate koro.';
  }
  try {
    final raf = file.openSync();
    try {
      final head = raf.readSync(64);
      if (!isMp4Bytes(Uint8List.fromList(head))) {
        return 'Video file-ti kharap (MP4 na): $path — abar Generate koro.';
      }
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return 'Video file-ti khola jayni: $path — abar Generate koro.';
  }
  return null;
}
