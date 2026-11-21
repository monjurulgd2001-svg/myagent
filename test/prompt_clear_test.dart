// v143: the designer prompt row's clear (X) and voice mic buttons
// are REMOVED on his order (screenshot 21:12) — this file pins
// that they stay gone, and that the Polish wand + the remove-row
// button survived. (v73's old X-button test lived here before.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('designer prompt row has no clear X and no mic, wand stays',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // v112: the prompt input is a numbered row list (like the
    // reference's Prompts card) — anchor on the first row's hint.
    final promptField = find.ancestor(
      of: find.text('Prompt 1 - describe the set concept…'),
      matching: find.byType(TextField),
    );
    expect(promptField, findsOneWidget);
    // Empty field: neither removed button exists.
    expect(find.byTooltip('Clear prompt'), findsNothing);
    expect(find.byTooltip('Speak your prompt'), findsNothing);
    await tester.enterText(promptField, 'a frozen glass dune');
    await tester.pump();
    // Text present: still no X and no mic — and the text is
    // untouched (nothing cleared it behind the scenes).
    expect(find.byTooltip('Clear prompt'), findsNothing);
    expect(find.byTooltip('Speak your prompt'), findsNothing);
    expect(tester.widget<TextField>(promptField).controller?.text,
        'a frozen glass dune');
    // The Polish wand stays on the focused row, and the
    // remove-row button stays beside the field.
    expect(find.byTooltip('Polish prompts'), findsOneWidget);
    expect(find.byTooltip('Remove prompt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
