import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/main.dart';

void main() {
  testWidgets('v57 account bar fits: actions live in the menu',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // Session status is one short line, not a cut-off chip.
    expect(find.text('Not connected'), findsOneWidget);
    // The three actions are behind the ⋮ menu, with the same labels.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Add Gmail'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
  });

  testWidgets('v57 empty Showcase hides the disabled action row',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // v85: the empty gallery is inline below the designer on the
    // Studio screen — no Showcase tab to open any more.
    await tester.ensureVisible(find.text('No sets yet'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No sets yet'), findsOneWidget);
    expect(find.text('Metadata (all)'), findsNothing);
    expect(find.text('Ready ZIP'), findsNothing);
    expect(find.text('Upload to Panel'), findsNothing);
  });
}
