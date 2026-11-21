// v107: the built-in sign-in screen must not close the moment the
// Google login lands — the PSID cookie is set at login, but the
// Gemini session (SNlM0e + the full cookie set) settles over the
// redirect chain after it. Live 2026-11-20 the screen closed at the
// first page-stop ("Login hoyar sathe sathe close hoye jay browser")
// and handed Dart a half-settled jar, so the verify fetch found no
// token. Kotlin cannot compile on this VM (no Android SDK — CI is
// first compile), so guard the markers here like the v102/v103 JS
// marker tests do for content.js.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v107: sign-in waits for the session to settle before closing',
      () async {
    final kt = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/GeckoSignInActivity.kt')
        .readAsString();
    // Only the app page counts — not any gemini.google.com page.
    expect(kt, contains('contains("/app")'));
    // A 4s settle runs before the close, and the PSID is re-checked.
    expect(kt, contains('settlePending'));
    expect(kt, contains('postDelayed'));
    expect(kt, contains('4000'));
    expect(kt, contains('hasPsid(json2)'));
    // The old immediate close on the first PSID sighting is gone.
    expect(kt, isNot(contains('hasPsid(json)) close()')));
  });

  test('v108: sign-in wipes the profile before the page loads', () async {
    final kt = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/GeckoSignInActivity.kt')
        .readAsString();
    // The profile's site data is cleared first — "Remove" only
    // clears the app's saved header, and a stale / mixed jar in
    // the profile made every fresh sign-in fail the same way.
    expect(kt, contains('loadSignInFresh'));
    expect(kt, contains('clearData'));
    expect(kt, contains('SITE_DATA'));
    expect(kt, contains('StorageController'));
    // The page load waits for the wipe (both outcomes load it).
    expect(kt, contains(".then("));
    // No direct load of the sign-in URL on create anymore.
    expect(kt, isNot(contains('s.loadUri(intent.getStringExtra')));
    // The Login screen shows the build, so its screenshots prove
    // which version is installed.
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('App v2.5.50'));
  });
}
