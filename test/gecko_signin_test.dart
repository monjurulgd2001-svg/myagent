// v107: the built-in sign-in screen must not close the moment the
// Google login lands — the PSID cookie is set at login, but the
// Gemini session (SNlM0e + the full cookie set) settles over the
// redirect chain after it. Live 2026-11-20 the screen closed at the
// first page-stop ("Login hoyar sathe sathe close hoye jay browser")
// and handed Dart a half-settled jar, so the verify fetch found no
// token. Kotlin cannot compile on this VM (no Android SDK — CI is
// first compile), so guard the markers here like the v102/v103 JS
// marker tests do for content.js.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/gecko_signin.dart';
import 'package:gemini_hd_studio/gemini_api.dart';

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
    // v117 — the listeners are explicitly-typed SAMs: a bare
    // lambda left the type parameter U of GeckoResult.then()
    // uninferred (CI failed at compileReleaseKotlin twice —
    // v116's `null as Void?` did not fix it, the compiler had
    // picked the flatMap-style `then` overload). Explicit SAM
    // types pin U to Void? and leave only the plain overload.
    expect(kt, contains('GeckoResult.OnValueListener<Void, Void?>'));
    expect(kt, contains('GeckoResult.OnExceptionListener<Void?>'));
    // No direct load of the sign-in URL on create anymore.
    expect(kt, isNot(contains('s.loadUri(intent.getStringExtra')));
    // The Login screen shows the build, so its screenshots prove
    // which version is installed.
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('App v2.5.56'));
  });

  test('v121: the browser reads the session token off its own page',
      () async {
    // Live 2026-11-21 the sign-in itself worked, but the Dart
    // verify fetch of /u/0/app got a Google bot-check page
    // instead of Gemini (v118 diagnosis). The fix: the token is
    // read from the page the real browser already loaded — no
    // HTTP fetch at all.
    final content = await File(
            'android/app/src/main/assets/ais_cookies/content.js')
        .readAsString();
    expect(content, contains('function sessionPage(m)'));
    expect(content, contains("m.type === 'sessionPage'"));
    expect(content, contains("type: 'sessionPage'"));
    // Same field set as Dart's _parseSessionHtml — only the
    // extracted fields leave the page, never the whole HTML.
    expect(content, contains('SNlM0e'));
    expect(content, contains('cfb2h'));
    expect(content, contains('PI9WOb'));

    final bg = await File(
            'android/app/src/main/assets/ais_cookies/background.js')
        .readAsString();
    expect(bg, contains('case "sessionPage"'));
    expect(bg, contains('sessionPageTab'));
    expect(bg, contains('pendingSessionPage'));
    expect(bg, contains('m.type === "sessionPage"'));

    final bridge = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/GeckoBridge.kt')
        .readAsString();
    expect(bridge, contains('fun readSessionPage'));
    expect(bridge, contains('put("cmd", "sessionPage")'));
    expect(bridge, contains('lastSessionPage'));
    expect(bridge, contains('mergedSignInPayload'));

    final activity = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/GeckoSignInActivity.kt')
        .readAsString();
    // The token is read in the settle path, before the close —
    // after onDestroy the session is gone.
    expect(activity, contains('readSessionPage(this, 8000)'));
    expect(activity, contains('lastSessionPage = page'));

    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('_browserSessionFromResult'));
    expect(login, contains('browserSession:'));
    expect(login, contains('browserSession ??'));
  });

  test('v121: sign-in payload parsing — new shape, old shape, junk',
      () {
    const cookies = [
      {'name': '__Secure-1PSID', 'value': 'psid-value'},
      {'name': '__Secure-1PSIDTS', 'value': 'ts-value'},
      {'name': 'NID', 'value': 'nid-value'},
      {'name': 'OTHER', 'value': 'ignored'},
    ];
    const session = {
      'at': 'TOKEN123',
      'bl': 'BL123',
      'fSid': 'FSID123',
      'email': 'Test@Gmail.com',
      'serverToken': 'SRV123',
      'apiKeys': ['AIza12345678901234567890123456789012345'],
      'url': 'https://gemini.google.com/u/0/app?authuser=0',
    };
    final merged = jsonEncode({'cookies': cookies, 'session': session});

    // New shape: header from the cookies half, fields from the
    // session half.
    expect(GeckoSignIn.headerFromCookiesJson(merged),
        '__Secure-1PSID=psid-value; __Secure-1PSIDTS=ts-value; NID=nid-value');
    final page = GeckoSignIn.sessionPageFromResult(merged);
    expect(page, isNotNull);
    expect(page!.at, 'TOKEN123');
    expect(page.bl, 'BL123');
    expect(page.fSid, 'FSID123');
    expect(page.email, 'Test@Gmail.com');
    expect(page.serverToken, 'SRV123');
    expect(page.apiKeys, ['AIza12345678901234567890123456789012345']);
    expect(page.url, contains('/u/0/app'));

    // Old shape (bare cookie array): header still works, no page.
    final bare = jsonEncode(cookies);
    expect(GeckoSignIn.headerFromCookiesJson(bare),
        '__Secure-1PSID=psid-value; __Secure-1PSIDTS=ts-value; NID=nid-value');
    expect(GeckoSignIn.sessionPageFromResult(bare), isNull);

    // Junk: no crash, no page, no header.
    expect(GeckoSignIn.sessionPageFromResult(null), isNull);
    expect(GeckoSignIn.sessionPageFromResult(''), isNull);
    expect(GeckoSignIn.sessionPageFromResult('not json'), isNull);
    expect(GeckoSignIn.sessionPageFromResult('{"cookies": []}'), isNull);
    expect(
        GeckoSignIn.sessionPageFromResult(
            jsonEncode({'session': {'bl': 'x'}})),
        isNull);
    expect(
        GeckoSignIn.sessionPageFromResult(
            jsonEncode({'session': {'at': ''}})),
        isNull);
    expect(GeckoSignIn.headerFromCookiesJson('not json'), '');
    expect(GeckoSignIn.headerFromCookiesJson('{"cookies": []}'), '');
  });

  test('v121: session built from in-browser fields', () {
    final s = GeminiApi.sessionFromPageFields(
      authUser: 0,
      cookieHeader: '__Secure-1PSID=x',
      at: 'TOKEN123',
      bl: 'BL123',
      fSid: 'FSID123',
      email: 'test@gmail.com',
      serverToken: 'SRV123',
      apiKeys: const ['AIza12345678901234567890123456789012345'],
    );
    expect(s.at, 'TOKEN123');
    expect(s.bl, 'BL123');
    expect(s.fSid, 'FSID123');
    expect(s.email, 'test@gmail.com');
    expect(s.serverToken, 'SRV123');
    expect(s.apiKeys, ['AIza12345678901234567890123456789012345']);
    expect(s.cookieHeader, '__Secure-1PSID=x');
    expect(s.authUser, 0);
    expect(s.isFresh, isTrue);

    // Empty bl / email fall back to the same defaults as the
    // HTML parser — an in-browser read with a missing field must
    // not produce a half-broken session.
    final bare = GeminiApi.sessionFromPageFields(
      authUser: 2,
      cookieHeader: '__Secure-1PSID=x',
      at: 'TOKEN123',
    );
    expect(bare.bl, GeminiApi.defaultBl);
    expect(bare.email, 'Account u/2');
    expect(bare.apiKeys, isEmpty);
  });

  test('v121: the fallback /app fetch looks like a browser navigation',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Map<String, String>? seenHeaders;
    const appHtml = '{"SNlM0e":"TESTAT","cfb2h":"TESTBL",'
        '"FdrFJe":"TESTFSID","PI9WOb":"TESTTOKEN",'
        '"oPEP7c":"test@gmail.com",'
        '"key":"AIza12345678901234567890123456789012345"}';
    final client = MockClient((req) async {
      seenHeaders = Map<String, String>.from(req.headers);
      return http.Response(appHtml, 200);
    });
    final api = GeminiApi(client: client);
    final session = await api.getSession(
      forceRefresh: true,
      explicitAuthUser: 0,
      verifyHeader: '__Secure-1PSID=x; __Secure-1PSIDTS=y',
    );
    expect(session.at, 'TESTAT');
    final lower = {
      for (final e in seenHeaders!.entries) e.key.toLowerCase(): e.value
    };
    // A bare Dart fetch is what Google bot-checked; a real
    // browser navigation always carries these.
    expect(lower['sec-fetch-dest'], 'document');
    expect(lower['sec-fetch-mode'], 'navigate');
    expect(lower['sec-fetch-site'], 'same-origin');
    expect(lower['sec-fetch-user'], '?1');
    expect(lower['accept-language'], 'en-US,en;q=0.9');
    expect(lower['upgrade-insecure-requests'], '1');
    expect(lower['cookie'], contains('__Secure-1PSID=x'));
  });
}
