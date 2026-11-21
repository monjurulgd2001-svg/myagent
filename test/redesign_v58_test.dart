import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:gemini_hd_studio/studio_constants.dart';

void main() {
  test('v58 foldable prompt lives in the backend, word for word', () {
    expect(
        kFoldableAdaptationPrompt,
        'extend this portrait wallpaper outward into a wider landscape frame for foldable and tablet screens (7:6, slightly wider than tall), this is the very same artwork continued sideways, not a new picture, keep the exact same subject identity, geometry, pose, scale, materials, color palette, lighting direction, rendering style and mood - it must be recognizably the same wallpaper at thumbnail size, keep the original portrait composition intact in the middle and continue the existing background, environment and atmosphere naturally to the left and right with seamless matching detail, perspective and light, hero centered horizontally, hero mass slightly below center, whole hero inside the frame with at least 12 percent safe margin on the left and right edges and 6 percent on the top and bottom, quiet low-detail upper third for the clock and widgets, do not crop the subject, do not stretch or squash, do not zoom in, do not duplicate or mirror the subject, do not add new structures or elements the reference does not contain, no borders, no letterbox bars, no blurred side fills');
  });

  testWidgets('v58 Studio shows no foldable prompt field', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // Switch to the mode that used to show the editable field.
    await tester.tap(find.text('9:16 + Foldable'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Foldable adaptation prompt'), findsNothing);
    expect(find.text('Reference image (optional)'), findsOneWidget);
  });
}
