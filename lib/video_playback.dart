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
