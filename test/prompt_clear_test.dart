// Prompts clear (v73): the designer prompt field gets an X
// button, and the Search Prompts card's Clear also clears the
// per-picture prompts + status (the card side is covered by the
// full suite's regression net; this file pins the field button).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('designer prompt field clears with the X button',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    final promptField = find.ancestor(
      of: find.text('Prompt'),
      matching: find.byType(TextField),
    );
    expect(promptField, findsOneWidget);
    // Empty field: no clear button.
    expect(find.byTooltip('Clear prompt'), findsNothing);
    await tester.enterText(promptField, 'a frozen glass dune');
    await tester.pump();
    // Text present: the X appears.
    expect(find.byTooltip('Clear prompt'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear prompt'));
    await tester.pump();
    expect(tester.widget<TextField>(promptField).controller?.text, isEmpty);
    // Gone again once the field is empty.
    expect(find.byTooltip('Clear prompt'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
