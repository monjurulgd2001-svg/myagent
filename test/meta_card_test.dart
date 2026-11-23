// v96 — the metadata card inside a SetCard is compact by default
// (2-line description, one scrollable tag row) and expands on tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/main.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';

const _longDescription =
    'Layered alabaster, copper, and frosted indigo glass form a '
    'sculptural tree inside a quiet ice cavern. Rim light casts sharp '
    'refractions across ivory, cobalt, and bronze tones in a calm, '
    'wondrous mood that feels both festive and still.';

SetEntry _entry() => SetEntry(
      id: 't1',
      prompt: 'An architectural Christmas tree sculpture',
      workflowMode: 'set_24h',
      setTypeLabel: '24-Hour Set (4)',
      setFolderName: 'set-01',
      createdAtIso: '2026-11-08T01:00:00.000',
      metadata: SetMetadata(
        title: 'Sculpted Cavern Pine',
        tags: [
          'alabaster',
          'copper',
          'cavern',
          'hoarfrost',
          'cobalt',
          'bronze',
          'refractions',
          'sculpted',
          'subterranean',
          'ivory',
        ],
        category: 'HOLIDAYS',
        description: _longDescription,
      ),
      images: [
        SetImage(
          localPath: '/nonexistent/morning.jpg',
          exactFilename: 'morning.jpg',
          zipName: '01-morning.jpg',
          distSlot: 'morning',
          role: 'morning',
          label: 'Morning',
          badge: 'MORNING',
          slotIndex: 0,
          stageKey: 'morning',
          width: 1620,
          height: 2880,
          byteSize: 3 * 1024 * 1024,
        ),
      ],
    );

void main() {
  testWidgets('v96: meta card is compact by default, expands on tap',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetCard(
            entry: _entry(),
            engine: StudioEngine(),
            onChanged: () async {},
            snack: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    final card = find.byKey(const ValueKey('metaCard'));
    expect(card, findsOneWidget);

    // Collapsed: 2-line description, one scrollable tag row, toggle.
    final desc = tester.widget<Text>(find.text(_longDescription));
    expect(desc.maxLines, 2);
    expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.horizontal),
        findsOneWidget);
    expect(find.text('Aro dekho'), findsOneWidget);
    final collapsed = tester.getSize(card);

    // Expand: full description, wrapped tags, toggle flips.
    await tester.tap(find.byKey(const ValueKey('metaExpandToggle')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Kom dekho'), findsOneWidget);
    expect(tester.widget<Text>(find.text(_longDescription)).maxLines,
        isNull);
    expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.horizontal),
        findsNothing);
    expect(find.byType(Wrap), findsWidgets);
    final expanded = tester.getSize(card);

    // The collapsed card is about half the expanded one.
    expect(expanded.height, greaterThan(collapsed.height));
    expect(collapsed.height, lessThan(expanded.height * 0.7));
  });

  testWidgets('v96: short metadata shows no toggle', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry();
    entry.metadata = SetMetadata(
      title: 'Tiny',
      tags: ['one', 'two'],
      category: 'NATURE',
      description: 'Short.',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetCard(
            entry: entry,
            engine: StudioEngine(),
            onChanged: () async {},
            snack: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Aro dekho'), findsNothing);
    expect(find.text('Kom dekho'), findsNothing);
  });
}
