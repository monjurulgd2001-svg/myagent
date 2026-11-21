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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/gecko_signin.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/session_store.dart';

void main() {
  // v123 — the session cache is shared (static) across GeminiApi
  // instances now, so every test starts from an empty cache.
  setUp(() => GeminiApi.clearSessionCacheForTest());

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

  test('v108/v124: the profile wipe runs only on a proven-stale jar',
      () async {
    final kt = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/GeckoSignInActivity.kt')
        .readAsString();
    // v124 — the v108 wipe no longer runs before every sign-in:
    // a sign-in that failed on a slow network wiped the working
    // browser login and left Refresh with nothing to recover,
    // while the saved login sat untouched in the app. The wipe
    // now runs only when the loaded /app page is signed in but
    // yields no token twice — a proven-stale jar.
    expect(kt, isNot(contains('loadSignInFresh')));
    expect(kt, contains('wipeProfileThenLoad'));
    expect(kt, contains('wipedOnce'));
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
    // On create the sign-in URL loads directly, on top of
    // whatever the profile holds.
    expect(kt, contains('session?.loadUri(intent.getStringExtra'));
    // The Login screen shows the build, so its screenshots prove
    // which version is installed.
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('App v2.5.59'));
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
    // after onDestroy the session is gone. v124 lengthened the
    // read timeout and retries it once (a single miss can mean
    // the extension tab had not connected yet).
    expect(activity, contains('readSessionPageWithRetry'));
    expect(activity, contains('readSessionPage(this, 15000)'));
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

  test('v122: session page carries its account slot', () {
    GeckoSessionPage? pageFor(String? url) {
      final session = <String, Object?>{'at': 'T'};
      if (url != null) session['url'] = url;
      return GeckoSignIn.sessionPageFromResult(
          jsonEncode({'cookies': [], 'session': session}));
    }

    expect(pageFor('https://gemini.google.com/u/0/app?authuser=0')!.authUser,
        0);
    expect(pageFor('https://gemini.google.com/u/2/app')!.authUser, 2);
    // A plain /app load serves the profile's default account —
    // no slot in the URL, so the caller falls back to the active
    // slot instead of guessing.
    expect(pageFor('https://gemini.google.com/app')!.authUser, isNull);
    expect(pageFor(null)!.authUser, isNull);
  });

  test('v122: refreshSessionPage returns the browser session', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.geminihd.studio/gecko');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const cookies = [
      {'name': '__Secure-1PSID', 'value': 'psid-value'},
      {'name': '__Secure-1PSIDTS', 'value': 'ts-value'},
    ];
    const session = {
      'at': 'TOKEN123',
      'bl': 'BL123',
      'fSid': 'FSID123',
      'email': 'test@gmail.com',
      'serverToken': 'SRV123',
      'apiKeys': ['AIza12345678901234567890123456789012345'],
      'url': 'https://gemini.google.com/u/0/app?authuser=0',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'refresh') {
        return jsonEncode({'cookies': cookies, 'session': session});
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final out = await GeckoSignIn.refreshSessionPage();
    expect(out, isNotNull);
    expect(out!.header,
        '__Secure-1PSID=psid-value; __Secure-1PSIDTS=ts-value');
    expect(out.page.at, 'TOKEN123');
    expect(out.page.email, 'test@gmail.com');
    expect(out.page.authUser, 0);

    // No signed-in profile (null result) → null, never a crash.
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await GeckoSignIn.refreshSessionPage(), isNull);
    // Page read missed (cookies but no session half) → null.
    messenger.setMockMethodCallHandler(
        channel, (_) async => jsonEncode({'cookies': cookies}));
    expect(await GeckoSignIn.refreshSessionPage(), isNull);
  });

  test('v122: Test button and renewal verify through the browser',
      () async {
    // Live 2026-11-21 v121 proved the sign-in itself works
    // (Connected! on the browser path), but the Test button kept
    // failing: it still used the Dart /app fetch, which Google
    // bot-checks. The Test and the renewal now go through the
    // browser first — the same headless page read v121 built.
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('refreshSessionPage'));
    expect(login, contains('_browserSessionFromPage'));
    // Only the unchanged box goes through the browser — a fresh
    // paste can only be proven by fetching with it.
    expect(login, contains('headerToSave == null'));

    final main = await File('lib/main.dart').readAsString();
    expect(main, contains('_renewSessionViaBrowser'));
    expect(main, contains('refreshSessionPage'));
    // Silent renewal renews through the browser first, then still
    // runs the Dart calls (they fail silently when blocked).
    expect(main,
        contains('final renewed = await _renewSessionViaBrowser(api)'));

    final gecko = await File('lib/gecko_signin.dart').readAsString();
    expect(gecko, contains('refreshSessionPage'));
    expect(gecko, contains('static Future<({String header,'));
  });

  test('v122: a bot-blocked check is not a dead session', () {
    expect(
        GeminiApi.isBotBlocked(Exception(
            'Could not find Gemini session token (SNlM0e) for Account u/0. '
            'Google showed a bot check instead of Gemini — the request '
            'was blocked. Try again later.')),
        isTrue);
    expect(
        GeminiApi.isBotBlocked(Exception(
            'Google returned its sign-in page — the saved cookies are '
            'dead (signed out). Remove them and sign in again.')),
        isFalse);
    expect(GeminiApi.isBotBlocked(Exception('No Gemini login found.')),
        isFalse);
  });

  test('v122: Refresh answers only from the real /app page, and a '
      'blocked check says so instead of "not connected"', () async {
    // Live 2026-11-21: first connect shows Connected, Refresh
    // shows not connected. The headless refresh answered on the
    // FIRST page-stop — a consent page or bot-check interstitial
    // carries no token, so Refresh reported failure on a session
    // that was fine. The reply is now gated on the real /app page.
    final bridge =
        await File('android/app/src/main/kotlin/com/geminihd/studio/'
                'GeckoBridge.kt')
            .readAsString();
    final refresh = bridge.substring(bridge.indexOf('fun refresh('));
    expect(refresh, contains('onLocationChange'));
    expect(refresh, contains('lastUrl'));
    expect(refresh, contains('gemini.google.com'));
    expect(refresh, contains('"/app"'));
    // A failed load must not trigger the reply either.
    expect(refresh, contains('!success'));

    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('Could not verify right now'));
    expect(login, contains('isBotBlocked'));
    // The blocked-check message must say the saved session is
    // untouched — never report the account as disconnected.
    expect(login, contains('Your saved session is untouched'));
  });

  // v123 — live 2026-11-21 12:18 (v122, App v2.5.57): Refresh
  // still reported "Could not verify" on a 2.4 KB/s network, and
  // the user read that as "the Gmail login is not staying saved".
  // The audit found three real faults, not one:
  // (1) the session cache was per-instance, so a session proven
  // in the browser (sign-in / renewal) was invisible to the
  // generation engine, which re-fetched over Dart HTTP — the
  // exact fetch Google bot-checks; (2) a blocked re-fetch threw
  // even when the app held a good session, so generation died on
  // a blocked CHECK, not a dead login; (3) the headless refresh
  // waited for the full page load (30s cap) although the token is
  // readable at document_end, and the Login screen showed nothing
  // saved whenever a live check failed.
  test('v123: a browser sign-in feeds generation — the session cache '
      'is shared across GeminiApi instances', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('<html></html>', 200);
    });
    // Sign-in (its own GeminiApi instance, as the Login screen
    // builds one) adopts the browser-proven session.
    final signInApi = GeminiApi();
    await signInApi.adoptSession(GeminiSession(
      authUser: 0,
      email: 'borer.jazmin@gmail.com',
      at: 'FRESHAT',
      bl: 'FRESHBL',
      fSid: '',
      cookieHeader: '__Secure-1PSID=x; __Secure-1PSIDTS=y',
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    // Generation (a different instance, as the engine builds one)
    // sees it with no HTTP fetch at all.
    final engineApi = GeminiApi(client: client);
    final session = await engineApi.getSession(explicitAuthUser: 0);
    expect(session.at, 'FRESHAT');
    expect(session.email, 'borer.jazmin@gmail.com');
    expect(calls, 0);
  });

  test('v123: a blocked fresh check falls back to the last good '
      'session for generation', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SessionStore.saveCookieForUser(
        0, '__Secure-1PSID=x; __Secure-1PSIDTS=y');
    var calls = 0;
    // Google bot-checks the Dart fetch: a 200 page with no token.
    final client = MockClient((req) async {
      calls++;
      return http.Response('<html><body>consent</body></html>', 200);
    });
    final signInApi = GeminiApi();
    await signInApi.adoptSession(GeminiSession(
      authUser: 0,
      email: 'borer.jazmin@gmail.com',
      at: 'STALEAT',
      bl: 'STALEBL',
      fSid: '',
      cookieHeader: '__Secure-1PSID=x; __Secure-1PSIDTS=y',
      // 1h old: stale (isFresh is 15 min), so the fetch runs.
      fetchedAtMs:
          DateTime.now().millisecondsSinceEpoch - 3600 * 1000,
    ));
    final engineApi = GeminiApi(client: client);
    final session = await engineApi.getSession(explicitAuthUser: 0);
    expect(session.at, 'STALEAT');
    // The fresh check was attempted once — then the fallback
    // carried the generation instead of throwing.
    expect(calls, 1);
  });

  test('v123: the fallback never applies to a verify call, and never '
      'without a cached session', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SessionStore.saveCookieForUser(
        0, '__Secure-1PSID=x; __Secure-1PSIDTS=y');
    final client = MockClient(
        (req) async => http.Response('<html></html>', 200));
    final signInApi = GeminiApi();
    await signInApi.adoptSession(GeminiSession(
      authUser: 0,
      email: 'borer.jazmin@gmail.com',
      at: 'STALEAT',
      bl: 'STALEBL',
      fSid: '',
      cookieHeader: '__Secure-1PSID=x; __Secure-1PSIDTS=y',
      fetchedAtMs:
          DateTime.now().millisecondsSinceEpoch - 3600 * 1000,
    ));
    final api = GeminiApi(client: client);
    // A verify must still throw on a blocked check — it must
    // never silently "verify" with a stale session.
    await expectLater(
      api.getSession(forceRefresh: true, explicitAuthUser: 0),
      throwsException,
    );
    // And with no cached session at all, a plain generation call
    // has nothing to fall back to.
    GeminiApi.clearSessionCacheForTest();
    await expectLater(
      api.getSession(explicitAuthUser: 0),
      throwsException,
    );
  });

  test('v123: Refresh asks for the token early and waits for a slow '
      'page', () async {
    final bridge =
        await File('android/app/src/main/kotlin/com/geminihd/studio/'
                'GeckoBridge.kt')
            .readAsString();
    final refresh = bridge.substring(bridge.indexOf('fun refresh('));
    // The token is readable at document_end, long before the full
    // page finishes loading — ask early with a long timeout instead
    // of waiting for onPageStop.
    expect(refresh, contains('readSessionPage(context, 120000)'));
    // The 30s cap fired mid-load on a 2.4 KB/s network; the cap is
    // now the backstop only.
    expect(refresh, contains('150000'));
    // One guarded answer path shared by the early read, the
    // page-stop read, and the cap.
    expect(refresh, contains('val answer'));

    final dart =
        await File('lib/gecko_signin.dart').readAsString();
    expect(dart, contains('Duration(seconds: 180)'));
  });

  test('v123: the Login screen shows the saved login even when a live '
      'check is blocked', () async {
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('_savedLoginLabel'));
    expect(login, contains('Saved on this phone'));
    expect(login, contains('_refreshSavedInfo'));
    expect(login, contains('loadActiveInfo'));
  });

  test('v124: sign-in polls instead of waiting for a page-stop',
      () async {
    // Live 2026-11-21 12:45 (App v2.5.58): "Sign-in closed
    // without a session" — on a ~5 KB/s network the heavy /app
    // page takes minutes to finish, so onPageStop never fired
    // while the user waited, and the screen sat silent until he
    // closed it by hand. The activity now re-checks every 5s and
    // shows where the browser is.
    final activity = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/'
            'GeckoSignInActivity.kt')
        .readAsString();
    expect(activity, contains('pollRunnable'));
    expect(activity, contains('postDelayed(this, 5000)'));
    expect(activity, contains('checkInFlight'));
    expect(activity, contains('statusView'));
    expect(activity, contains('setStatus'));
    expect(activity, contains('slow connection, please wait'));
  });

  test('v124: a failed sign-in never wipes a good login', () async {
    // The v108 wipe ran before EVERY sign-in, so a sign-in that
    // failed on a slow network destroyed the working browser
    // login and left Refresh with nothing to recover — while the
    // saved login sat untouched in the app. The wipe now runs
    // only on a page proven stale (signed in, tokenless twice).
    final activity = await File(
            'android/app/src/main/kotlin/com/geminihd/studio/'
            'GeckoSignInActivity.kt')
        .readAsString();
    expect(activity, isNot(contains('loadSignInFresh')));
    expect(activity, contains('wipeProfileThenLoad'));
    expect(activity, contains('wipedOnce'));
    expect(activity, contains('clearData'));
    // A manual close mid-settle must not cut the token read off.
    expect(activity, contains('if (settlePending) return'));
    // ...but a dead renderer still closes at once.
    expect(activity, contains('closeAfterCrash'));
    // A vanished PSID mid-settle resets, so the poll can retry
    // and the screen can still be closed by hand.
    expect(activity, contains('PSID vanished mid-settle'));
  });

  test('v124: the empty sign-in message tells the user to wait on '
      'a slow connection', () async {
    // The old message sent the user to Refresh, which cannot help
    // when the profile holds no login at all. The new one says
    // the saved login is untouched and asks for one more Sign in
    // with time to load.
    final login = await File('lib/login_screen.dart').readAsString();
    expect(login, contains('did not finish signing in'));
    expect(login, contains('slow connection'));
    // The message is built from concatenated literals (v105
    // lesson: a phrase split across two literals never matches
    // as one string) — assert the two halves on either side of
    // the split.
    expect(login, contains('saved login below is'));
    expect(login, contains('untouched. Please tap Sign in again'));
    // The old Gecko message is gone (the Windows sign-in's own
    // Refresh wording is a different message and stays).
    expect(login, isNot(contains('Sign-in closed without a session. '
        'If you did sign in, tap Refresh')));
  });
}
