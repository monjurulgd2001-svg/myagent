// v148 — Image to Prompt SEARCH screen layout (his 2026-11-22
// screenshot): the search screen (_BrowserScreen, reached via
// "Collect image links & prompts") is now a queue layout —
// thumbnail cards with Queued/Failed pills, Resume / Retry failed /
// Clear finished, a Batch Sets button, and the Options card at the
// bottom. Function is unchanged: same search, same link paste,
// same basket, same batch generation, same send to Batch Sets.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/image_search.dart';

Future<void> _openSearchScreen(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(home: ImageSearchScreen(promptMode: true)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Collect image links & prompts'));
  await tester.pumpAndSettle();
}

Finder _linkField() => find.byWidgetPredicate((w) =>
    w is TextField &&
    w.decoration?.hintText == 'Paste an image link (https://...)');

Future<void> _addLink(WidgetTester tester, String url) async {
  await tester.enterText(_linkField(), url);
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('v148 search screen: queue layout, Batch Sets, Options card',
      (tester) async {
    await _openSearchScreen(tester);
    // Reference header: "Image to Prompt" + layers + gear actions.
    expect(find.text('Image to Prompt', skipOffstage: true), findsOneWidget);
    expect(find.byTooltip('Batch Sets'), findsOneWidget);
    expect(find.byTooltip('Options'), findsOneWidget);
    // Search still there: box + source chips.
    expect(find.text('Search images...'), findsOneWidget);
    expect(find.text('Google Images', skipOffstage: true), findsOneWidget);
    // Queue section: Batch Sets button + empty state, no Resume yet.
    expect(find.text('Image links (0)', skipOffstage: true), findsOneWidget);
    expect(find.text('Batch Sets', skipOffstage: true), findsOneWidget);
    expect(find.text('Resume', skipOffstage: true), findsNothing);
    expect(find.text('Retry failed', skipOffstage: true), findsNothing);
    expect(find.text('Clear finished', skipOffstage: true), findsNothing);
    // Options card at the bottom: Auto-add + Gemini web cookies.
    expect(find.text('Options', skipOffstage: true), findsOneWidget);
    expect(find.text('Auto-add to Prompts list', skipOffstage: true),
        findsOneWidget);
    expect(find.text('Gemini web cookies', skipOffstage: true),
        findsOneWidget);
    expect(find.text('Auto - browser sign-in, else saved', skipOffstage: true),
        findsOneWidget);
    expect(find.text('Similarity target', skipOffstage: true), findsOneWidget);
    // Docked bridge actions stay; the old docked Generate button is
    // gone (Resume + Batch Sets in the queue section replace it).
    expect(find.text('Paste link'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Generate prompt for 1 image'), findsNothing);
    expect(find.text('Generate prompts for 1 image'), findsNothing);
    expect(find.text('External browser'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v148 queue card: a pasted link becomes a Queued card',
      (tester) async {
    await _openSearchScreen(tester);
    await _addLink(
        tester, 'https://example.com/xiaomi-wallpaper.jpg');
    expect(find.text('Image links (1)', skipOffstage: true), findsOneWidget);
    expect(find.text('Queued', skipOffstage: true), findsOneWidget);
    expect(find.text('Waiting for its turn…', skipOffstage: true),
        findsOneWidget);
    expect(find.text('xiaomi-wallpaper.jpg', skipOffstage: true),
        findsOneWidget);
    expect(find.text('Resume (1)', skipOffstage: true), findsOneWidget);
    expect(find.text('Retry failed', skipOffstage: true), findsNothing);
    expect(find.text('Clear finished', skipOffstage: true), findsNothing);
    // Per-card actions: use the image + remove it.
    expect(find.byTooltip('Use this image', skipOffstage: true),
        findsOneWidget);
    expect(find.byTooltip('Remove', skipOffstage: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v148 batch sheet: queue cards + Resume / Batch Sets',
      (tester) async {
    await _openSearchScreen(tester);
    await _addLink(
        tester, 'https://example.com/xiaomi-wallpaper.jpg');
    await tester.tap(find.text('Batch Sets', skipOffstage: true));
    await tester.pumpAndSettle();
    expect(find.text('Generate prompts (1 images)'), findsOneWidget);
    // The sheet card is Queued, like the reference's first card.
    expect(find.text('Queued'), findsWidgets);
    expect(find.text('Waiting for its turn…'), findsWidgets);
    // Sheet action row: Resume (1); nothing failed / finished yet.
    expect(find.text('Resume (1)'), findsWidgets);
    expect(find.text('Retry failed'), findsNothing);
    expect(find.text('Clear finished'), findsNothing);
    expect(find.text('Stop after current'), findsNothing);
    // Per-card retry + delete (delete is behind the sheet here, so
    // the visible one is the sheet's).
    expect(find.byTooltip('Retry this image'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('v148: queue layout strings in the source, old labels gone', () async {
    final src = await File('lib/image_search.dart').readAsString();
    expect(src, contains('_QueueItemCard'));
    expect(src, contains('_statusPill'));
    expect(src, contains("label: 'Queued'"));
    expect(src, contains("'Waiting for its turn…'"));
    expect(src, contains("label: const Text('Batch Sets')"));
    expect(src, contains("'Resume ("));
    expect(src, contains("label: const Text('Clear finished')"));
    expect(src, contains("'Retry failed ("));
    expect(src, contains("title: Text(widget.promptMode ? 'Image to Prompt'"));
    expect(src, isNot(contains("title: const Text('External browser')")));
    expect(src, isNot(contains('Retry remaining')));
    expect(src, isNot(contains('Send \$_doneCount prompts to Batch Sets')));
    expect(src, isNot(contains('Generate prompt for 1 image')));
  });
}
