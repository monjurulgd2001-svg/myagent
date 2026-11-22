// v147 — image-to-prompt upload 401 retry: the upload is the FIRST
// step of generatePromptFromImage, and the Generate-RPC retry below it
// only fires AFTER a successful upload — so a stale/expired session
// (the user's screenshot: 'Gemini rejected the session (HTTP 401)')
// killed the whole job at the upload with no retry. v147 refreshes
// the session the same browser-first way the RPC retry does
// (getSession with forceRefresh) and re-uploads ONCE.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/session_store.dart';

const _appHtml = '{"SNlM0e":"TESTAT","cfb2h":"TESTBL",'
    '"FdrFJe":"TESTFSID","PI9WOb":"TESTTOKEN",'
    '"oPEP7c":"test@gmail.com",'
    '"key":"<redacted>"}';

String _generateRaw() {
  final inner = jsonEncode([
    null,
    ['conv1', 'resp1'],
    null,
    null,
    [
      [
        'choice1',
        ['Hello world answer'],
        null,
        null,
        [
          'https://lh3.googleusercontent.com/gg-dl/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd=s1024'
        ]
      ]
    ]
  ]);
  final line = jsonEncode([
    ['wrb.fr', null, inner]
  ]);
  return ")]}'\n123\n$line\n";
}

void main() {
  late int initCalls;
  late int appCalls;

  Future<GeminiApi> makeApi({
    required int firstInitStatus,
    required int refreshAppStatus,
  }) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    GeminiApi.clearSessionCacheForTest();
    await SessionStore.saveCookieForUser(
        0, '__Secure-1PSID=x; __Secure-1PSIDTS=y');
    initCalls = 0;
    appCalls = 0;
    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('push.clients6.google.com/upload')) {
        initCalls++;
        if (initCalls == 1) {
          return http.Response('', firstInitStatus);
        }
        return http.Response('', 200, headers: {
          'x-goog-upload-url': 'https://upload.example/session1',
        });
      }
      if (url.contains('upload.example/session1')) {
        return http.Response('/contrib_service/abc123', 200);
      }
      if (url.contains('/app')) {
        appCalls++;
        if (appCalls == 1) {
          // The first session fetch (before the upload) succeeds —
          // the session only goes stale at the upload.
          return http.Response(_appHtml, 200);
        }
        return http.Response(
            refreshAppStatus == 200 ? _appHtml : '', refreshAppStatus);
      }
      if (url.contains('ProcessFile')) {
        return http.Response('', 200);
      }
      if (url.contains('BardChatUi')) {
        return http.Response(_generateRaw(), 200);
      }
      return http.Response('', 404);
    });
    return GeminiApi(client: client);
  }

  test('v147: upload 401 -> session refresh -> re-upload succeeds',
      () async {
    final api = await makeApi(firstInitStatus: 401, refreshAppStatus: 200);
    final prompt = await api.generatePromptFromImage(
      Uint8List.fromList([1, 2, 3]),
      'test.jpg',
    );
    expect(prompt, contains('Hello world answer'));
    // The upload ran twice: the 401 attempt, then the retry on the
    // refreshed session. The refresh itself re-fetched /app.
    expect(initCalls, 2);
    expect(appCalls, 2);
  });

  test('v147: upload 401 -> refresh fails -> honest failure, no loop',
      () async {
    final api = await makeApi(firstInitStatus: 401, refreshAppStatus: 401);
    await expectLater(
      api.generatePromptFromImage(
        Uint8List.fromList([1, 2, 3]),
        'test.jpg',
      ),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('HTTP 401'),
      )),
    );
    // Exactly one upload attempt: the retry never ran because the
    // refresh itself failed — no second upload, no loop.
    expect(initCalls, 1);
  });

  test('v147: non-auth upload failure (HTTP 500) is not retried',
      () async {
    final api = await makeApi(firstInitStatus: 500, refreshAppStatus: 200);
    await expectLater(
      api.generatePromptFromImage(
        Uint8List.fromList([1, 2, 3]),
        'test.jpg',
      ),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('HTTP 500'),
      )),
    );
    // A 500 is not a stale session — no refresh, no re-upload.
    expect(initCalls, 1);
    expect(appCalls, 1);
  });
}
