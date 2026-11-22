import 'dart:io';

import 'package:flutter/material.dart';
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
  });

  Future<void> pumpVideoDialog(
    WidgetTester tester, {
    VoidCallback? onOpenInBrowser,
    String videoPath = '/tmp/anim_v1.mp4',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => showDeviceVideoPreview(
            context,
            videoPath: videoPath,
            title: 'Neon blue phone',
            onOpenInBrowser: onOpenInBrowser,
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
