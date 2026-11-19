// v94 — the signaler key lives in the Gemini UI JS bundle, not the
// page HTML: bundle URL extraction, bundle-first key ordering, and
// GeminiApi.ensureBundleApiKeys (fetch once per UI version, cached).
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/task_backend.dart';

String _key(String ch) => 'AIza${ch * 35}';

GeminiSession _session({
  List<String> apiKeys = const [],
  String bundleUrl = '',
}) =>
    GeminiSession(
      authUser: 0,
      email: 'u0@test',
      at: 'AT-TEST',
      bl: 'boq_test_bl',
      fSid: '12345',
      cookieHeader: 'SAPISID=abc123;',
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      apiKeys: apiKeys,
      bundleUrl: bundleUrl,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v94: bundle URL + key ordering (pure)', () {
    test('extractBundleUrl finds the preload link, unescapes &amp;', () {
      const html =
          '<link rel="preload" href="https://gemini.gstatic.com/_/mss/'
          'boq-gemini-web-uiserver/_/js/k=boq-gemini-web-uiserver.'
          'BardChatUi.en.NcE3BnbhJwQ.2018.O/am=hG8EQIl9ANb-P7jAP4EOH'
          'JCAoiAnCEIXAAAAABAC/d=1&amp;excm=_b/ed=1/dg=0/br=1/wt=2/'
          'ujg=1/rs=AKrAJMqbTq0Qqlsxs6bmXcWJouydeWVzRg/ee=EmZ2Bf:zr">';
      final url = extractBundleUrl(html);
      expect(url, isNotNull);
      expect(url, startsWith(
          'https://gemini.gstatic.com/_/mss/boq-gemini-web-uiserver/_/js/k='));
      expect(url, contains('/d=1&excm=_b/'));
      expect(url, isNot(contains('&amp;')));
    });

    test('extractBundleUrl returns null when the bundle is absent', () {
      expect(extractBundleUrl('<html><body>no scripts</body></html>'),
          isNull);
    });

    test('mergeApiKeys: bundle first, then doc, deduped, capped', () {
      final b1 = _key('B');
      final b2 = _key('C');
      final d1 = _key('D');
      expect(
          mergeApiKeys(bundleKeys: [b1, b2], docKeys: [b2, d1]),
          [b1, b2, d1]);
      expect(mergeApiKeys(bundleKeys: [], docKeys: [d1]), [d1]);
      final many = List<String>.generate(25, (i) => '${_key('E')}$i');
      // Keys are 39 chars; the suffix keeps them distinct.
      expect(mergeApiKeys(bundleKeys: many, docKeys: []).length, 20);
    });
  });

  group('v94: ensureBundleApiKeys (MockClient + mock prefs)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('fetches the bundle once, returns bundle-first keys', () async {
      final bundleKey1 = _key('B');
      final bundleKey2 = _key('C');
      final docKey = _key('D');
      var hits = 0;
      final api = GeminiApi(
        client: MockClient((req) async {
          hits++;
          expect(req.url.toString(),
              'https://example.test/bundle-a.js');
          return http.Response(
              'var a="$bundleKey1"; var b="$bundleKey2";', 200);
        }),
      );
      final session = _session(
        apiKeys: [docKey],
        bundleUrl: 'https://example.test/bundle-a.js',
      );
      final keys = await api.ensureBundleApiKeys(session);
      expect(keys, [bundleKey1, bundleKey2, docKey]);
      expect(hits, 1);
      // Second call: in-memory cache, no new fetch.
      expect(await api.ensureBundleApiKeys(session), keys);
      expect(hits, 1);
    });

    test('prefs cache is used when the in-memory cache is cold', () async {
      final bundleKey = _key('F');
      final docKey = _key('G');
      SharedPreferences.setMockInitialValues({
        'taskBackendBundleUrl': 'https://example.test/bundle-b.js',
        'taskBackendBundleKeys': [bundleKey],
      });
      var hits = 0;
      final api = GeminiApi(
        client: MockClient((req) async {
          hits++;
          return http.Response('', 200);
        }),
      );
      final session = _session(
        apiKeys: [docKey],
        bundleUrl: 'https://example.test/bundle-b.js',
      );
      expect(await api.ensureBundleApiKeys(session), [bundleKey, docKey]);
      expect(hits, 0);
    });

    test('bundle fetch failure falls back to document keys', () async {
      final docKey = _key('H');
      final api = GeminiApi(
        client: MockClient((req) async {
          return http.Response('gone', 404);
        }),
      );
      final session = _session(
        apiKeys: [docKey],
        bundleUrl: 'https://example.test/bundle-c.js',
      );
      expect(await api.ensureBundleApiKeys(session), [docKey]);
    });

    test('no bundle URL: document keys, no HTTP at all', () async {
      final docKey = _key('I');
      var hits = 0;
      final api = GeminiApi(
        client: MockClient((req) async {
          hits++;
          return http.Response('', 200);
        }),
      );
      expect(await api.ensureBundleApiKeys(_session(apiKeys: [docKey])),
          [docKey]);
      expect(hits, 0);
    });
  });
}
