// v156 — decoder fallback: the phone's hardware decoder rejects
// a valid MP4 (live 2026-11-22: MediaCodecVideoRenderer error on
// TECNO CAMON 30S, same file plays in Chrome), so the preview
// switches to the embedded browser engine inside the mockup, and
// the app must be able to say WHICH codec it was.
//
// Covers: the MP4 codec probe (readMp4VideoCodec), the decoder
// error classifier (isDecoderError), and the real ffmpeg files
// (H.264 + HEVC at the Zedge spec size).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gemini_hd_studio/mp4_info.dart';
import 'package:gemini_hd_studio/video_playback.dart';

import 'mp4_test_helpers.dart';

void main() {
  group('v156: MP4 codec probe', () {
    test('avc1: H.264 High @ 5.1, 1620x2880', () {
      final codec = readMp4VideoCodec(minimalMp4());
      expect(codec, isNotNull);
      expect(codec!.codec, 'H.264');
      expect(codec.detail, 'High @ 5.1');
      expect(codec.width, 1620);
      expect(codec.height, 2880);
      expect(codec.label, 'H.264 High @ 5.1 · 1620x2880');
    });

    test('avc1: Baseline @ 3.0 when the config says so', () {
      final codec = readMp4VideoCodec(
          minimalMp4(avcProfile: 66, avcLevel: 30));
      expect(codec, isNotNull);
      expect(codec!.codec, 'H.264');
      expect(codec.detail, 'Baseline @ 3.0');
    });

    test('hev1: HEVC Main 10 @ 5.0', () {
      final codec = readMp4VideoCodec(minimalMp4(codec: 'hev1'));
      expect(codec, isNotNull);
      expect(codec!.codec, 'HEVC');
      expect(codec.detail, 'Main 10 @ 5.0');
      expect(codec.width, 1620);
      expect(codec.height, 2880);
    });

    test('vp09: VP9, no profile detail', () {
      final codec = readMp4VideoCodec(minimalMp4(codec: 'vp09'));
      expect(codec, isNotNull);
      expect(codec!.codec, 'VP9');
      expect(codec.detail, isEmpty);
    });

    test('no stsd / garbage: null, never a guessed codec', () {
      expect(readMp4VideoCodec(minimalMp4(codec: 'none')), isNull);
      expect(readMp4VideoCodec(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(readMp4VideoCodec(Uint8List(0)), isNull);
    });

    test('real ffmpeg files: H.264 + HEVC at 1620x2880', () async {
      final dir = Directory.systemTemp.createTempSync('anim-v156-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<String> render(String codec, String out) async {
        final r = await Process.run('ffmpeg', [
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=0x0a0a2a:s=1620x2880:d=1',
          '-c:v',
          codec,
          '-pix_fmt',
          'yuv420p',
          '-r',
          '30',
          out,
        ]);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        return out;
      }

      final h264 = await render('libx264', '${dir.path}/h264.mp4');
      final c264 = readMp4VideoCodec(await File(h264).readAsBytes());
      expect(c264, isNotNull);
      expect(c264!.codec, 'H.264');
      expect(c264.width, 1620);
      expect(c264.height, 2880);
      expect(c264.detail, isNotEmpty);

      final hevc = await render('libx265', '${dir.path}/hevc.mp4');
      final c265 = readMp4VideoCodec(await File(hevc).readAsBytes());
      expect(c265, isNotNull);
      expect(c265!.codec, 'HEVC');
      expect(c265.width, 1620);
      expect(c265.height, 2880);
    });
  });

  group('v156: decoder error classifier', () {
    test('the live MediaCodec error is a decoder error', () {
      expect(
          isDecoderError(
              'PlatformException(VideoError, Video player had error '
              'd0.k: MediaCodecVideoRenderer error, index out of '
              'bounds)'),
          isTrue);
      expect(isDecoderError('Decoder init failed'), isTrue);
      expect(isDecoderError('MediaCodecVideoRenderer error'), isTrue);
    });

    test('source / generic errors are NOT decoder errors', () {
      expect(isDecoderError('Source error'), isFalse);
      expect(isDecoderError('no player'), isFalse);
      expect(isDecoderError('PlatformException(VideoError, '
          'Video player had error d0.k: Source error, null, null)'),
          isFalse);
      expect(isDecoderError(''), isFalse);
    });
  });

  group('v156: moov box reader', () {
    test('reads just the moov box; the probes work on those bytes',
        () {
      final dir = Directory.systemTemp.createTempSync('anim-v156-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v.mp4')
        ..writeAsBytesSync(minimalMp4());
      final moov = readMp4MoovBytes(file.path);
      expect(moov, isNotNull);
      // The whole file is ftyp + moov here, so the moov bytes are
      // most of the file — but never the media data of a real clip.
      expect(moov!.length, lessThan(file.lengthSync()));
      final codec = readMp4VideoCodec(moov);
      expect(codec, isNotNull);
      expect(codec!.codec, 'H.264');
      expect(codec.label, 'H.264 High @ 5.1 · 1620x2880');
      final info = readMp4Info(moov);
      expect(info, isNotNull);
      expect(info!.fps, 30);
    });

    test('missing / non-MP4 file: null, never throws', () {
      final dir = Directory.systemTemp.createTempSync('anim-v156-');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(readMp4MoovBytes('${dir.path}/nope.mp4'), isNull);
      final html = File('${dir.path}/bad.mp4')
        ..writeAsStringSync('<!doctype html><html>sign in</html>');
      expect(readMp4MoovBytes(html.path), isNull);
    });
  });
}
