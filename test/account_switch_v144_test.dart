// v144 — generation kept using the default Gmail (u/0) even after the
// user signed into a second Gmail (u/1):
// (1) the Login screen's account dropdown only changed which slot's
//     cookies that screen shows — it never told generation which
//     account to use;
// (2) the 1037 quota failover switched accounts in memory only when
//     the mode was 'auto', so the next generation (fresh GeminiApi,
//     activeAuthUserIndex back to 0) retried the exhausted u/0 again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/login_screen.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/session_store.dart';

const _appHtml = '{"SNlM0e":"TESTAT","cfb2h":"TESTBL",'
    '"FdrFJe":"TESTFSID","PI9WOb":"TESTTOKEN",'
    '"oPEP7c":"second@gmail.com",'
    '"key":"<redacted>"}';

void main() {
  test('v144: quota failover persists the switched account in auto mode',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    GeminiApi.clearSessionCacheForTest();
    // Two signed-in accounts; mode untouched ('auto' by default).
    await SessionStore.saveDiscoveredAccounts([
      const GeminiAccount(
          authUser: 0, email: 'borer.jazmin@gmail.com', bl: ''),
      const GeminiAccount(authUser: 1, email: 'second@gmail.com', bl: ''),
    ]);
    await SessionStore.saveCookieForUser(
        1, '__Secure-1PSID=x; __Secure-1PSIDTS=y');
    expect(await SessionStore.loadAccountMode(), 'auto');

    final client = MockClient((_) async => http.Response(_appHtml, 200));
    final api = GeminiApi(client: client);
    final switched = await api.trySwitchToNextAccount(0);

    expect(switched, isNotNull);
    expect(switched!.authUser, 1);
    expect(api.activeAuthUserIndex, 1);
    // The switch sticks: the mode is saved, not just held in memory.
    expect(await SessionStore.loadAccountMode(), '1');
    // A FRESH GeminiApi — the next generation — starts on u/1 now,
    // not on the exhausted u/0 again.
    final nextApi = GeminiApi(client: client);
    expect(await nextApi.resolveTargetAuthUser(), 1);
  });

  testWidgets('v144: picking a slot in the Login dropdown pins it '
      'as the generation account', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen(initialAuthUser: 0)),
    );
    await tester.pumpAndSettle();
    expect(await SessionStore.loadAccountMode(), 'auto');

    await tester.tap(find.text('u/0 (Default Gmail)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('u/1 (Gmail #2)'));
    await tester.pumpAndSettle();

    expect(find.text('u/1 (Gmail #2)'), findsOneWidget);
    expect(await SessionStore.loadAccountMode(), '1');
  });
}
