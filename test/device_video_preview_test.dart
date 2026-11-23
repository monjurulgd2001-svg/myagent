import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:gemini_hd_studio/widgets/device_mockup.dart';

import 'fake_video_player.dart';
import 'mp4_test_helpers.dart';

void main() {
  late FakeVideoPlayerPlatform fake;
  late VideoPlayerPlatform previous;

  setUp(() {
    fake = FakeVideoPlayerPlatform();
    previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = fake;
    // v154 — the dialog checks the file BEFORE creating the player,
    // so the happy-path tests need a real MP4 at the video path.
    File('/tmp/anim_v1.mp4').writeAsBytesSync(minimalMp4());
  });

  tearDown(() {
    VideoPlayerPlatform.instance = previous;
    final f = File('/tmp/anim_v1.mp4');
    if (f.existsSync()) f.deleteSync();
    final w = File('/tmp/anim_v1.mp4.preview.html');
    if (w.existsSync()) w.deleteSync();
  });

  Future<void> pumpVideoDialog(
    WidgetTester tester, {
    VoidCallback? onOpenInBrowser,
    String videoPath = '/tmp/anim_v1.mp4',
    // v156 — injected embedded-browser view for the decoder
    // fallback (the real GeckoView cannot exist in tests).
    Widget Function(String fileUrl)? videoBrowserViewBuilder,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => showDeviceVideoPreview(
            context,
            videoPath: videoPath,
            title: 'Neon blue phone',
            onOpenInBrowser: onOpenInBrowser,
            videoBrowserViewBuilder: videoBrowserViewBuilder,
          ),
          child: const Text('Open'),
        );
      }),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    // v154 — the preflight check is synchronous (a 64-byte header
    // read), so the fake player initialises within these pumps.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('v141 video preview plays the MP4 inside the phone frame',
      (tester) async {
    await pumpVideoDialog(tester);
    expect(find.text('Device preview'), findsOneWidget);
    expect(find.text('Neon blue phone'), findsOneWidget);
    expect(find.byKey(const ValueKey('fakeVideoView')), findsOneWidget);
    // The controller asked for the file, then looped, muted, played.
    expect(fake.lastDataSource?.sourceType, DataSourceType.file);
    expect(fake.lastDataSource?.uri, contains('anim_v1.mp4'));
    expect(fake.calls, contains('setLooping:true'));
    expect(fake.calls, contains('setVolume:0.0'));
    expect(fake.calls, contains('play'));
    // Play/pause toggle talks to the player.
    expect(find.byKey(const ValueKey('deviceVideoPlayPause')),
        findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('deviceVideoPlayPause')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('deviceVideoPlayPause')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('pause'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v141 video preview shows lock/home modes, not call',
      (tester) async {
    await pumpVideoDialog(tester);
    expect(find.text('Wallpaper'), findsOneWidget);
    // 'Lock' also shows in the bottom mode label (default mode).
    expect(find.text('Lock'), findsWidgets);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
    // The Call overlay needs a still image for the caller avatar.
    expect(find.text('Call'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v154 video preview: missing file shows a clear error, '
      'no player is created', (tester) async {
    await pumpVideoDialog(tester, videoPath: '/tmp/anim_missing.mp4');
    expect(find.text('Video preview khola jayni'), findsOneWidget);
    expect(find.textContaining('pawa jayni'), findsOneWidget);
    expect(find.textContaining('/tmp/anim_missing.mp4'), findsOneWidget);
    // The raw PlatformException never appears, and the player was
    // never even created for a file that does not exist.
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(fake.calls, isNot(contains('create')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v154 video preview: non-MP4 file shows a clear error, '
      'no player is created', (tester) async {
    File('/tmp/anim_v1.mp4')
        .writeAsStringSync('<!doctype html><html>sign in</html>');
    await pumpVideoDialog(tester);
    expect(find.text('Video preview khola jayni'), findsOneWidget);
    expect(find.textContaining('MP4 na'), findsOneWidget);
    expect(fake.calls, isNot(contains('create')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v141 video preview failure offers the browser fallback',
      (tester) async {
    fake.failCreate = true;
    var fallbackTapped = false;
    await pumpVideoDialog(tester,
        onOpenInBrowser: () => fallbackTapped = true);
    expect(find.text('Video preview khola jayni'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceVideoOpenBrowserError')),
        findsOneWidget);
    // The button sits inside the phone frame, below the test
    // viewport fold — scroll the dialog to it first (v112 lesson).
    await tester.ensureVisible(
        find.byKey(const ValueKey('deviceVideoOpenBrowserError')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('deviceVideoOpenBrowserError')));
    // The button sits inside the phone's rotate GestureDetector
    // (onDoubleTap), so the single tap resolves only after the
    // double-tap timeout — pump past it before asserting.
    await tester.pump(const Duration(milliseconds: 400));
    expect(fallbackTapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v156 decoder error on init falls back to the embedded browser '
      'view inside the mockup', (tester) async {
    // The live 2026-11-22 failure: a valid MP4 the hardware
    // decoder rejects (MediaCodecVideoRenderer error).
    fake.failCreateError = PlatformException(
        code: 'VideoError',
        message: 'Video player had error d0.k: '
            'MediaCodecVideoRenderer error, index out of bounds');
    String? seenUrl;
    await pumpVideoDialog(tester,
        onOpenInBrowser: () {},
        videoBrowserViewBuilder: (url) {
          seenUrl = url;
          return Container(key: const ValueKey('fakeGeckoVideoView'));
        });
    // The fallback probes the file (async read) before showing.
    await tester.pump(const Duration(milliseconds: 100));
    // The preview still plays ON THE DEVICE, inside the phone
    // frame — the embedded browser view, not an error screen.
    expect(find.byKey(const ValueKey('deviceVideoBrowserFallback')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('fakeGeckoVideoView')), findsOneWidget);
    // v159 second pass — the fallback loads the WRAPPER page, not
    // the raw MP4 URL (the raw file shows Gecko's built-in media
    // viewer with its own chrome and black bars).
    expect(seenUrl, startsWith('file://'));
    expect(seenUrl, endsWith('anim_v1.mp4.preview.html'));
    // …and the wrapper file beside the MP4 really is the
    // cover-fit page (no controls, no text on the video).
    final wrapper = File('/tmp/anim_v1.mp4.preview.html');
    expect(wrapper.existsSync(), isTrue);
    final wrapperHtml = wrapper.readAsStringSync();
    expect(wrapperHtml, contains('object-fit:cover'));
    expect(wrapperHtml, contains('anim_v1.mp4'));
    expect(wrapperHtml, isNot(contains('controls')));
    // The video area is COMPLETELY CLEAN: no overlay text widget
    // inside the fallback container at all.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('deviceVideoBrowserFallback')),
            matching: find.byType(Text)),
        findsNothing);
    expect(find.byKey(const ValueKey('deviceVideoDecoderNote')),
        findsNothing);
    // The Banglish note names the measured codec, never the raw
    // PlatformException — and it lives UNDER the mockup (the hint
    // line), not on the video.
    expect(find.textContaining('decoder'), findsOneWidget);
    expect(find.textContaining('H.264 High @ 5.1'), findsOneWidget);
    expect(find.textContaining('1620x2880'), findsOneWidget);
    expect(find.text('Video preview khola jayni'), findsNothing);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(find.textContaining('MediaCodecVideoRenderer'), findsNothing);
    // The failed player is released in the runtime-error case
    // (init succeeded there); after a failed create there is no
    // platform player to release — video_player's dispose awaits a
    // never-completing future then, so nothing is recorded.
    expect(fake.calls, contains('create'));
    expect(find.byKey(const ValueKey('deviceVideoOpenBrowser')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v156 non-decoder init error still shows the error screen, '
      'no browser fallback', (tester) async {
    fake.failCreate = true;
    await pumpVideoDialog(tester,
        onOpenInBrowser: () {},
        videoBrowserViewBuilder: (_) =>
            Container(key: const ValueKey('fakeGeckoVideoView')));
    expect(find.text('Video preview khola jayni'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceVideoBrowserFallback')),
        findsNothing);
    expect(find.byKey(const ValueKey('fakeGeckoVideoView')), findsNothing);
    expect(find.byKey(const ValueKey('deviceVideoOpenBrowserError')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v156 runtime decoder error after init falls back',
      (tester) async {
    await pumpVideoDialog(tester,
        videoBrowserViewBuilder: (_) =>
            Container(key: const ValueKey('fakeGeckoVideoView')));
    // Playing normally first.
    expect(find.byKey(const ValueKey('fakeVideoView')), findsOneWidget);
    fake.emitRuntimeError(
        fake.lastPlayerId!,
        'Video player had error d0.k: MediaCodecVideoRenderer error, '
        'index out of bounds');
    // The error travels platform stream -> controller value ->
    // dialog listener -> fallback (several async hops); pump until
    // the fallback lands, bounded so a real failure still fails.
    for (var i = 0; i < 10; i++) {
      if (find
          .byKey(const ValueKey('deviceVideoBrowserFallback'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The fallback UI lands on setState; the controller's dispose
    // chain (subscription cancel -> platform dispose) only
    // completes on real event-loop time, not fake-async pumps
    // (proven by a scratch run: runAsync + a real delay lands it).
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('deviceVideoBrowserFallback')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('fakeGeckoVideoView')), findsOneWidget);
    // v159 second pass — the video area is clean (no overlay note)
    // but the codec line still shows under the mockup.
    expect(find.byKey(const ValueKey('deviceVideoDecoderNote')),
        findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('deviceVideoBrowserFallback')),
            matching: find.byType(Text)),
        findsNothing);
    expect(find.textContaining('H.264 High @ 5.1'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    // The playing controller was released on the switch.
    expect(fake.calls, contains('dispose'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v141 image preview still works (no regression)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => showDevicePreview(
            context,
            imageUrl: 'assets/logo.png',
            title: 'Test wallpaper',
          ),
          child: const Text('Open'),
        );
      }),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Device preview'), findsOneWidget);
    expect(find.text('Test wallpaper'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
