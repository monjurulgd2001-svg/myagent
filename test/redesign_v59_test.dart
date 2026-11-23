import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/image_search.dart';

void main() {
  testWidgets('v59 Search: source group has a caption + one swipe row',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: ImageSearchScreen(promptMode: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('SOURCE'), findsOneWidget);
    // All four source chips live inside one horizontal scroller,
    // not a Wrap that spills into ragged rows.
    expect(
        find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.text('Pinterest')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.text('Lexica')),
        findsOneWidget);
    // The collect action is secondary now: outlined, not tonal,
    // so Open browser stays the primary action. (find.byType
    // misses .icon factory buttons in this Flutter version, so
    // the button type is matched with a predicate instead.)
    expect(
        find.ancestor(
            of: find.text('Collect image links & prompts'),
            matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
        findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('Collect image links & prompts'),
            matching: find.byWidgetPredicate((w) => w is FilledButton)),
        findsNothing);
    expect(find.text('Open browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
