// v159 second pass — the browser-fallback preview wrapper (fourth
// v159 item): the mockup's Gecko view loads a minimal HTML page
// with a cover-fit <video> instead of the raw MP4 URL, so Gecko's
// built-in media viewer (own chrome + contain-fit black bars)
// never appears — and no text is ever drawn over the video.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gemini_hd_studio/widgets/video_preview_wrapper.dart';

void main() {
  group('v159 video preview wrapper HTML', () {
    test('cover-fit video, autoplay muted loop, no chrome, no text', () {
      final html =
          buildVideoPreviewWrapperHtml(videoFileName: 'anim_123.mp4');
      expect(html, contains('<video'));
      expect(html, contains('src="anim_123.mp4"'));
      expect(html, contains('object-fit:cover'));
      expect(html, contains('width:100%'));
      expect(html, contains('height:100%'));
      expect(html, contains('autoplay'));
      expect(html, contains('muted'));
      expect(html, contains('loop'));
      expect(html, contains('playsinline'));
      // No browser chrome and nothing drawn over the video.
      expect(html, isNot(contains('controls')));
      expect(html, isNot(contains('<div')));
      expect(html, isNot(contains('decoder')));
      expect(html, isNot(contains('Phone-er')));
    });

    test('file name is HTML-escaped in the src', () {
      final html =
          buildVideoPreviewWrapperHtml(videoFileName: 'a&b"c.mp4');
      expect(html, contains('src="a&amp;b&quot;c.mp4"'));
    });
  });

  group('v159 video preview wrapper file', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('v159b_wrapper_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('written beside the MP4, returns its file:// URL', () {
      final mp4 = File('${tmp.path}/anim_x.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final url = writeVideoPreviewWrapper(mp4.path);
      expect(url, isNotNull);
      expect(url, startsWith('file://'));
      expect(url, endsWith('anim_x.mp4.preview.html'));
      final wrapper = File('${tmp.path}/anim_x.mp4.preview.html');
      expect(wrapper.existsSync(), isTrue);
      final html = wrapper.readAsStringSync();
      expect(html, contains('object-fit:cover'));
      expect(html, contains('src="anim_x.mp4"'));
    });

    test('file name with a space is percent-encoded in the src', () {
      final mp4 = File('${tmp.path}/my video.mp4')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final url = writeVideoPreviewWrapper(mp4.path);
      expect(url, endsWith('my%20video.mp4.preview.html'));
      final html = File('${tmp.path}/my video.mp4.preview.html')
          .readAsStringSync();
      expect(html, contains('src="my%20video.mp4"'));
    });

    test('unwritable location returns null, never throws', () {
      expect(
          writeVideoPreviewWrapper(
              '${tmp.path}/no_such_dir/anim_x.mp4'),
          isNull);
    });
  });
}
