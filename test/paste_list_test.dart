// v119: Paste list — clipboard paste fills rows; an empty or
// failed clipboard read opens a paste box instead of doing nothing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _mockClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          SystemChannels.platform, (MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        if (text == null) return null;
        return <String, dynamic>{'text': text};
      case 'Clipboard.hasStrings':
        return <String, dynamic>{'value': text != null};
      case 'Clipboard.setData':
        return null;
      case 'LiveText.isLiveTextInputAvailable':
        return false;
      default:
        return null;
    }
  });
}

Future<void> _pumpStudio(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  await tester.pumpWidget(const GeminiHdStudioApp());
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('clipboard list fills one row per line', (tester) async {
    _mockClipboard('neon lake\nmountain dusk\ncalm sea');
    await _pumpStudio(tester);
    await tester.ensureVisible(find.text('Paste list'));
    await tester.pump();
    await tester.tap(find.text('Paste list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Each prompt is findable in its row field AND the batch queue
    // panel (find.text matches EditableText too — v112 lesson).
    expect(find.text('neon lake'), findsWidgets);
    expect(find.text('mountain dusk'), findsWidgets);
    expect(find.text('calm sea'), findsWidgets);
    expect(find.text('3 prompts pasted.'), findsOneWidget);
  });

  testWidgets('empty clipboard opens the paste box', (tester) async {
    _mockClipboard(null);
    await _pumpStudio(tester);
    await tester.ensureVisible(find.text('Paste list'));
    await tester.pump();
    await tester.tap(find.text('Paste list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Paste prompts'), findsOneWidget);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'river dawn\nforest night');
    await tester.tap(find.text('Add prompts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('river dawn'), findsWidgets);
    expect(find.text('forest night'), findsWidgets);
    expect(find.text('2 prompts pasted.'), findsOneWidget);
  });

  testWidgets('empty paste box does not add rows', (tester) async {
    _mockClipboard(null);
    await _pumpStudio(tester);
    await tester.ensureVisible(find.text('Paste list'));
    await tester.pump();
    await tester.tap(find.text('Paste list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Add prompts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Type or paste at least one prompt.'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
