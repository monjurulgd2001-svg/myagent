// v156 — the in-app browser engine (GeckoView) embedded as a
// Flutter platform view, for MP4s the phone's hardware decoder
// (ExoPlayer/MediaCodec) rejects.
//
// Live 2026-11-22: the finished animation failed the in-frame
// video_player with "MediaCodecVideoRenderer error" on TECNO CAMON
// 30S, while the same file plays in Chrome — Gecko bundles its own
// software decoders, so it plays what MediaCodec cannot. The
// preview must happen ON THE DEVICE, inside the phone mockup, so
// this view sits in the mockup's screen area instead of opening
// the (separate-activity) browser.
//
// Android only: on any other platform this widget builds an empty
// black box — the dialog only offers the fallback on Android (the
// only platform with a GeckoView). The native side is
// GeckoVideoViewFactory (one fresh GeckoSession per view, on the
// shared GeckoRuntime, closed with the view — never the shared
// browser tab session).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GeckoVideoView extends StatelessWidget {
  /// URL of the page to play — normally the WRAPPER page URL
  /// (see video_preview_wrapper.dart: a cover-fit `<video>`,
  /// no browser chrome), not the raw MP4 URL: loading the raw
  /// file shows Gecko's built-in media viewer with black bars.
  final String fileUrl;

  const GeckoVideoView({required this.fileUrl, super.key});

  @override
  Widget build(BuildContext context) {
    // Android only — GeckoView exists nowhere else. Off Android
    // this is a black box; the dialog gates the fallback on
    // Android, so this is only a safety net.
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Container(color: Colors.black);
    }
    return AndroidView(
      viewType: 'com.geminihd.studio/gecko_video',
      creationParams: <String, dynamic>{'url': fileUrl},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
