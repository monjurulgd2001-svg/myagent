// v156 — the video's AI metadata is shown attached to its card
// (description + tags), the same way image cards show metadata
// with the image. Before v156 it only existed behind the
// sparkle-icon dialog — the user asked for it on the card itself
// ("image-e jemon metadata image-r sathei dekhay, video-teo jemon
// sathei dekhay, card system kore").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/animation_screen.dart';
import 'package:gemini_hd_studio/models.dart';

void main() {
  AnimationVideo video({required String id, SetMetadata? metadata}) =>
      AnimationVideo(
        id: id,
        title: 'fire magnetic charging animation',
        prompt: 'fire magnetic charging animation',
        modelId: 'neon',
        styleId: 'cinematic',
        requestedDurationSec: 10,
        localPath: '/tmp/anim_v1.mp4',
        fileName: 'anim_v1.mp4',
        fps: 30,
        durationSec: 6,
        createdAt: DateTime.now(),
        metadata: metadata,
      );

  SetMetadata meta() => SetMetadata(
        title: 'Fire Magnetic Charging Live Wallpaper',
        description:
            'A blazing fire ring charges the phone with neon sparks.',
        tags: ['fire', 'charging', 'neon'],
        category: 'Live Wallpaper',
      );

  Future<void> pumpSection(
      WidgetTester tester, AnimationEngine engine) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimationSection(
            engine: engine,
            signedIn: true,
            wide: false,
            onGenerate: (_, __) async {},
            onPlay: (_) {},
            onDelete: (_) {},
            onExportZip: () {},
            onMetadata: (_) async {},
            onUploadToPanel: (_) async {},
            onUploadAllToPanel: () async {},
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  AnimationEngine engineWith(AnimationVideo v) {
    final engine = AnimationEngine();
    engine.videos = [v];
    return engine;
  }

  testWidgets('v156 grid tile shows the video metadata on the card',
      (tester) async {
    await pumpSection(tester, engineWith(video(id: 'v1', metadata: meta())));
    // Default view is the 3-column grid: description + tags are
    // visible on the tile itself, no tap needed.
    expect(find.byKey(const ValueKey('animMetaBlock-v1')), findsOneWidget);
    expect(
        find.text('A blazing fire ring charges the phone with neon sparks.'),
        findsOneWidget);
    expect(find.text('fire'), findsOneWidget);
    expect(find.text('neon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v156 list card shows the video metadata on the card',
      (tester) async {
    await pumpSection(tester, engineWith(video(id: 'v1', metadata: meta())));
    // Switch the grid to 1 column (list view). The header sits
    // below the test viewport fold — scroll it into view first.
    final fewer = find.byTooltip('Fewer columns (larger cards)');
    await tester.ensureVisible(fewer);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(fewer);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(fewer);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('animMetaBlock-v1')), findsOneWidget);
    expect(
        find.text('A blazing fire ring charges the phone with neon sparks.'),
        findsOneWidget);
    // v159 second pass — the list card mirrors the image card:
    // the category pill is the filled purple UPPERCASE pill
    // ('LIVE WALLPAPER'), while the panel-type chip still reads
    // 'Live Wallpaper' — one of each now, not two of the latter.
    expect(find.text('LIVE WALLPAPER'), findsOneWidget);
    expect(find.text('Live Wallpaper'), findsOneWidget);
    // v159 second pass — tags use the image card's '#tag' chip.
    expect(find.text('#charging'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v156 no metadata: the card stays compact, no block',
      (tester) async {
    await pumpSection(tester, engineWith(video(id: 'v1')));
    expect(find.byKey(const ValueKey('animMetaBlock-v1')), findsNothing);
    expect(
        find.text('A blazing fire ring charges the phone with neon sparks.'),
        findsNothing);
    // The card itself (title + spec) is still there.
    expect(find.text('fire magnetic charging animation'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
