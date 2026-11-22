// v153 — finished-video playback dispatch.
//
// v141's in-frame player already degrades gracefully on Windows
// (device_mockup catches the initialise failure and offers the
// fallback button), but the fallback itself called
// GeckoBrowser.open('file://...') — a MethodChannel with no native
// side on Windows, so it threw MissingPluginException, unhandled.
// The fallback now opens the file in the user's own browser on
// Windows (ExternalBrowser has a real Windows implementation) and
// keeps the Gecko browser on Android.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/video_playback.dart';

void main() {
  test('Android plays in the Gecko browser, Windows externally', () {
    expect(videoPlaybackTargetFor(TargetPlatform.android),
        VideoPlaybackTarget.gecko);
    expect(videoPlaybackTargetFor(TargetPlatform.windows),
        VideoPlaybackTarget.external);
    expect(videoPlaybackTargetFor(TargetPlatform.linux),
        VideoPlaybackTarget.external);
  });

  test('openVideoFile returns false (never throws) with no player',
      () async {
    // On the test host neither the Gecko channel nor a Windows
    // browser exists — both paths must fail soft, not throw.
    expect(
        await openVideoFile('/tmp/does-not-exist.mp4',
            platformOverride: TargetPlatform.windows),
        isFalse);
    expect(
        await openVideoFile('/tmp/does-not-exist.mp4',
            platformOverride: TargetPlatform.android),
        isFalse);
  });
}
