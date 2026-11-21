// v63 (rewritten for v111): the Set Designer card is gone — the
// Text / Image toggle stands alone directly under the top bar,
// like the reference's main screen, and the set-type chips moved
// into the Model & Size card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v63 toggle stands alone under the top bar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Set Designer'), findsNothing);
    expect(find.text('Text to Image'), findsOneWidget);
    expect(find.text('Image to Image'), findsOneWidget);
    expect(find.text('Set type'), findsOneWidget);
    // The toggle is above the Prompts card.
    expect(tester.getTopLeft(find.text('Text to Image')).dy,
        lessThan(tester.getTopLeft(find.text('Prompts')).dy));
    expect(tester.takeException(), isNull);
  });
}
