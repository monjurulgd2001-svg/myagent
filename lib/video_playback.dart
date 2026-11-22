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
import 'package:flutter/foundation.dart';

import 'external_browser.dart';
import 'gecko_browser.dart';

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
