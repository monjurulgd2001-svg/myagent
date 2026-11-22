// v153 — Windows silent session renewal.
//
// _silentRenew (startup + every 15 min) renewed through the
// built-in browser first on Android only; on Windows it rode the
// Dart HTTP fetch alone, which Google bot-checks. The Windows
// branch harvests the fresh jar from the app-profile Chrome
// instead. These tests cover the gate + the never-throws contract:
// without Chrome on the host, the harvest fails soft (false),
// and a non-Windows platform never touches the browser at all.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/windows_session_renewal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('non-Windows never harvests', () async {
    expect(
        await WindowsSessionRenewal.refreshSavedJar(
            platformOverride: TargetPlatform.android),
        isFalse);
    expect(
        await WindowsSessionRenewal.refreshSavedJar(
            platformOverride: TargetPlatform.linux),
        isFalse);
  });

  test('Windows without a Chromium install fails soft (false)',
      () async {
    expect(
        await WindowsSessionRenewal.refreshSavedJar(
            slot: 0, platformOverride: TargetPlatform.windows),
        isFalse);
  });
}
