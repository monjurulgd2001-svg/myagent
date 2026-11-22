/// v159 second pass — minimal HTML wrapper for the browser-fallback
/// video preview (the phone's hardware decoder rejected the MP4,
/// so the mockup plays it in the embedded GeckoView instead).
///
/// Problem (live 2026-11-22, Christmas-tree video): the factory
/// loaded the raw MP4 URL, so Gecko showed its BUILT-IN media
/// viewer — its own chrome (play / zoom / 100% bar, "Select
/// pictures") and a contain-fit with black bars top and bottom,
/// instead of filling the mockup screen. The wrapper is a plain
/// `<video>` styled `width:100%; height:100%; object-fit:cover`
/// (autoplay + muted + loop + playsinline, NO controls), so the
/// 1620x2880 video fills the screen edge-to-edge with no black
/// bars and nothing cut off — the same cover-fit the video_player
/// path already uses.
///
/// Why a FILE next to the MP4, not a data: URL: a data: document
/// has an opaque origin in Gecko and cannot load file://
/// subresources — the video would never load. A file:// document
/// in the SAME directory CAN load its sibling MP4 (relative
/// `src`, just the file name), so the wrapper is written beside
/// the video and loaded by its file:// URL. The write is
/// best-effort: on failure the caller loads the raw MP4 URL
/// instead (old behaviour), never a broken preview.
library;

import 'dart:io';

/// The wrapper page for [videoFileName] (the MP4's bare file name,
/// percent-encoded for use as a relative `src`). No text, no
/// controls, no browser chrome anywhere — the video area must be
/// completely clean.
String buildVideoPreviewWrapperHtml({required String videoFileName}) {
  final src = _escapeHtml(videoFileName);
  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
video{width:100%;height:100%;object-fit:cover;display:block;background:#000}
</style>
</head>
<body>
<video src="$src" autoplay muted loop playsinline></video>
</body>
</html>
''';
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Writes the wrapper beside the MP4 at [videoPath] (same
/// directory, `<name>.preview.html`) and returns its file:// URL,
/// or null when it cannot be written. The caller deletes the
/// sidecar when the preview closes (best effort).
String? writeVideoPreviewWrapper(String videoPath) {
  try {
    final file = File(videoPath);
    final base = file.path.split(Platform.pathSeparator).last;
    if (base.isEmpty) return null;
    final wrapper =
        File('${file.parent.path}${Platform.pathSeparator}$base.preview.html');
    wrapper.writeAsStringSync(buildVideoPreviewWrapperHtml(
        videoFileName: Uri.encodeComponent(base)));
    return wrapper.uri.toString();
  } catch (_) {
    return null;
  }
}
