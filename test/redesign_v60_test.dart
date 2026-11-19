import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/image_search.dart';

void main() {
  testWidgets('v60 Similarity card is compact: aspects hide in a preview',
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
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump(const Duration(milliseconds: 300));
    // The preview header shows the counts; the long lists are
    // collapsed away until tapped.
    expect(find.text('What stays & what changes'), findsOneWidget);
    expect(find.text('2 stay · 9 change'), findsOneWidget);
    expect(find.text('Similarity target'), findsOneWidget);
    // One tap opens the same two groups as before.
    await tester.tap(find.text('What stays & what changes'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Stays the same (2)'), findsOneWidget);
    expect(find.text('Will change (9)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
