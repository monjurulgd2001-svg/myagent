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
}
