import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v63 subtitle sits directly under the title text',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // The subtitle's left edge lines up with the title's left edge
    // (indented past the logo), instead of the container's left edge.
    final titleLeft =
        tester.getTopLeft(find.text('Zedge Studio')).dx;
    final subtitleLeft =
        tester.getTopLeft(find.text('Wallpaper Set Designer')).dx;
    expect(subtitleLeft, moreOrLessEquals(titleLeft, epsilon: 1.0));
    // And it is below the title, not on the same row.
    final titleTop = tester.getTopLeft(find.text('Zedge Studio')).dy;
    final subtitleTop =
        tester.getTopLeft(find.text('Wallpaper Set Designer')).dy;
    expect(subtitleTop, greaterThan(titleTop));
    expect(find.text('Version 2.5.42'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
