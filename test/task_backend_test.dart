// v92 — Task-mode video backend: channel protocol + hNvQHb poll +
// MP4 download, all against a MockClient (no live Gemini account).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/task_backend.dart';

GeminiSession _session({List<String> apiKeys = const ['AIzaTESTKEY']}) =>
    GeminiSession(
      authUser: 0,
      email: 'u0@test',
      at: 'AT-TEST',
      bl: 'boq_test_bl',
      fSid: '12345',
      cookieHeader: 'SAPISID=abc123; __Secure-1PSID=xyz;',
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      apiKeys: apiKeys,
      serverToken: 'CAMS-TEST-TOKEN',
    );

/// v98 — a page transport that is always unreachable, so the client
/// falls back to Dart HTTP deterministically (no real MethodChannel).
class _FailingPageTransport implements BackendTransport {
  @override
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
  }) async {
    throw const TaskBackendException('transport', 'no tab');
  }
}

/// v98 — a page transport answering from a canned handler, so a test
/// can prove the flow runs on the page transport.
class _CannedPageTransport implements BackendTransport {
  _CannedPageTransport(this._answer);
  final BackendResponse Function(String method, Uri uri, String? body)
      _answer;
  @override
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
  }) async =>
      _answer(method, uri, body);
}

void main() {
  group('v92: Task backend protocol (pure)', () {
    test('sapisidHash: "<ts>_<sha1(ts + sapisid + origin)>"', () {
      final h = sapisidHash('abc123', 'https://gemini.google.com', 1700000000);
      expect(h, startsWith('1700000000_'));
      final digest = h.split('_').last;
      expect(digest.length, 40);
      expect(
          digest,
          sha1
              .convert(utf8.encode(
                  '1700000000 abc123 https://gemini.google.com'))
              .toString());
    });

    test('buildTaskMessage round-trips the text', () {
      const text = 'Create a 10 second 1620x2880 9:16 video, phone charging';
      final bytes = buildTaskMessage(text);
      final root = pbDecode(bytes);
      expect(root.length, 1);
      final f2 = root.first.value as List<int>;
      final outer = pbDecode(f2);
      expect(outer[0].value, 1); // f1: 1
      final inner = pbDecode(outer[1].value as List<int>);
      expect(utf8.decode(inner.single.value as List<int>), text);
    });

    test('buildSetupMessage: client id + uuid twice, no blob/hash', () {
      const uuid = '93B43343-021F-4AE6-B0A6-1146955C2418';
      final bytes = buildSetupMessage(uuid);
      final root = pbDecode(bytes);
      // root: f1 = head {f1:1, f2:clientId, f3:en, f4:uuid}, f2 = 0,
      // f8 = {f5:{f1:{...}}, f4:1}.
      String s(dynamic v) => utf8.decode(v as List<int>);
      final head =
          pbDecode(root.firstWhere((e) => e.field == 1).value as List<int>);
      expect(head.firstWhere((e) => e.field == 1).value, 1);
      expect(s(head.firstWhere((e) => e.field == 2).value),
          'e6fa609c3fa255c0');
      expect(s(head.firstWhere((e) => e.field == 3).value), 'en');
      expect(s(head.firstWhere((e) => e.field == 4).value), uuid);
      final f8 = pbDecode(root.firstWhere((e) => e.field == 8).value as List<int>);
      final f5 = pbDecode(f8.firstWhere((e) => e.field == 5).value as List<int>);
      final inner =
          pbDecode(f5.firstWhere((e) => e.field == 1).value as List<int>);
      final fields = inner.map((e) => e.field).toSet();
      // The web page's encrypted token (f4) + its hash (f5) are the
      // two fields v92 cannot mint — they must be absent.
      expect(fields.contains(4), isFalse);
      expect(fields.contains(5), isFalse);
      expect(s(inner.firstWhere((e) => e.field == 60).value), uuid);
      expect(inner.firstWhere((e) => e.field == 50).value, 40);
      expect(inner.firstWhere((e) => e.field == 69).value, 2);
    });

    test('parseChooseServer / parseChannelOpen', () {
      expect(
          parseChooseServer(
              '["59RlWeJObywn35CmAmKDH-PPU47KdCQ1F8ZYECzKS9E",3,null]'),
          '59RlWeJObywn35CmAmKDH-PPU47KdCQ1F8ZYECzKS9E');
      expect(parseChooseServer('[]'), isNull);
      expect(
          parseChannelOpen(
              '51\n[[0,["c","4tCyPvjmcfzwGQ_kKEpMpw","",8,15,30000]]]\n'),
          '4tCyPvjmcfzwGQ_kKEpMpw');
      expect(parseChannelOpen('8\n[1,1,7]\n'), isNull);
    });

    test('extractStreamIds finds c_/r_ ids in raw bytes', () {
      final bytes = utf8.encode(
          'xx\x00c_0123456789abcdef\x00r_fedcba9876543210\x00zz');
      final ids = extractStreamIds(bytes);
      expect(ids.conversations, {'c_0123456789abcdef'});
      expect(ids.responses, {'r_fedcba9876543210'});
    });

    test('extractVideoDownloadUrl unescapes + finds the URL', () {
      const body =
          r''')]}'  48252 [["wrb.fr","hNvQHb",[[["https://lh3.googleusercontent.com/gg/AAA","https://contribution.usercontent.google.com/download?c\u003dABC123xyz",22,18]],null,[1795099400,421018407],null,"video/mp4",null]]]''';
      expect(extractVideoDownloadUrl(body),
          'https://contribution.usercontent.google.com/download?c=ABC123xyz');
      expect(extractVideoDownloadUrl('no video here'), isNull);
    });

    test('extractApiKeys collects distinct AIza keys', () {
      final key1 = 'AIza${'A' * 35}';
      final key2 = 'AIza${'B' * 35}';
      final html = '"k1":"$key1","k2":"$key2","k1b":"$key1"';
      expect(extractApiKeys(html), [key1, key2]);
    });

    test('chooseServer body is the captured verbatim JSON', () {
      expect(
          buildChooseServerBody(),
          '[[null,null,null,[9,5],null,[["assistant-bard"],[null,1],'
          '[[["bard-client-sync"]]]]],null,null,0,0]');
    });
  });

  group('v92: Task backend client (MockClient)', () {
    test('full flow: chooseServer -> open -> stream -> task -> poll -> download',
        () async {
      const cid = 'c_0123456789abcdef';
      const videoUrl =
          'https://contribution.usercontent.google.com/download?c=VID123';
      final seen = <String>[];
      final streamPayload =
          base64Encode(utf8.encode('xx${cid}yy'));
      final streamChunk = '[[3,["$streamPayload"]]]';
      final streamBody = '${streamChunk.length}\n$streamChunk\n';
      final client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('chooseServer')) {
          seen.add('chooseServer');
          return http.Response('["GS-TEST",3,null,"1","2"]', 200);
        }
        if (url.contains('processSession') && req.method == 'GET') {
          seen.add('stream');
          return http.Response(streamBody, 200);
        }
        if (url.contains('processSession')) {
          final body = req.body;
          if (body.startsWith('count=0')) {
            seen.add('open');
            return http.Response(
                '51\n[[0,["c","SID-TEST","",8,15,30000]]]\n', 200);
          }
          if (body.contains('ofs=0')) {
            seen.add('setup');
            return http.Response('8\n[1,1,7]\n', 200);
          }
          if (body.contains('ofs=1')) {
            seen.add('task');
            // The task text rides inside the base64 protobuf.
            final data = Uri.splitQueryString(body)['req0___data__']!;
            final raw = base64Url.decode(
                data.padRight(data.length + (4 - data.length % 4) % 4, '='));
            expect(String.fromCharCodes(raw),
                contains('phone charging with golden energy'));
            return http.Response('8\n[1,3,7]\n', 200);
          }
        }
        if (url.contains('batchexecute')) {
          seen.add('poll');
          expect(req.body, contains('hNvQHb'));
          expect(req.body, contains(cid));
          return http.Response(
              ''')]}' [["wrb.fr","hNvQHb",[[["$videoUrl","video/mp4"]]]]]''',
              200);
        }
        if (url.contains('usercontent')) {
          seen.add('download');
          return http.Response.bytes([9, 8, 7, 6], 200);
        }
        return http.Response('not found', 404);
      });
      final backend = TaskBackendClient(
        client: client,
        session: _session(),
        pollInterval: const Duration(milliseconds: 10),
        submitTimeout: const Duration(seconds: 5),
        pageTransport: _FailingPageTransport(),
      );
      final bytes = await backend.run(
        'phone charging with golden energy',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(bytes, [9, 8, 7, 6]);
      expect(seen, containsAll(
          ['chooseServer', 'open', 'stream', 'setup', 'task', 'poll', 'download']));
    });

    test('chooseServer failure names the step', () async {
      final client = MockClient((req) async {
        if (req.url.toString().contains('chooseServer')) {
          return http.Response('nope', 500);
        }
        return http.Response('not found', 404);
      });
      final backend = TaskBackendClient(
        client: client,
        session: _session(),
        pollInterval: const Duration(milliseconds: 10),
        submitTimeout: const Duration(seconds: 5),
        pageTransport: _FailingPageTransport(),
      );
      try {
        await backend.run(
          'phone charging',
          onPhase: (_, __) {},
          deadline: DateTime.now().add(const Duration(seconds: 30)),
        );
        fail('should throw');
      } on TaskBackendException catch (e) {
        expect(e.step, 'chooseServer');
      }
    });
  });

  group('v97: chooseServer tries override keys in parallel, browser-like headers', () {
    test('first key 403, second key 200 -> flow continues; headers set',
        () async {
      const cid = 'c_0123456789abcdef';
      const videoUrl =
          'https://contribution.usercontent.google.com/download?c=VID123';
      final key1 = 'AIza${'B' * 35}';
      final key2 = 'AIza${'C' * 35}';
      final docKey = 'AIza${'D' * 35}';
      final triedKeys = <String>[];
      var sawAuthUserHeader = false;
      var sawAcceptHeader = false;
      var sawNoCookieHeader = false;
      var sawSecFetchHeaders = false;
      final streamPayload = base64Encode(utf8.encode('xx${cid}yy'));
      final streamChunk = '[[3,["$streamPayload"]]]';
      final streamBody = '${streamChunk.length}\n$streamChunk\n';
      final client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('chooseServer')) {
          sawAuthUserHeader = req.headers['X-Goog-AuthUser'] == '0';
          sawAcceptHeader = req.headers['Accept'] == '*/*';
          // v97 — the browser's working request carried no cookies,
          // even though this test session has a cookie header; and
          // it sent the fetch metadata headers.
          sawNoCookieHeader = !req.headers.containsKey('Cookie');
          sawSecFetchHeaders = req.headers['Sec-Fetch-Mode'] == 'cors' &&
              req.headers['Sec-Fetch-Site'] == 'same-site' &&
              req.headers['Sec-Fetch-Dest'] == 'empty';
          final key = req.url.queryParameters['key'] ?? '';
          triedKeys.add(key);
          if (key == key2) {
            return http.Response('["GS-TEST",3,null,"1","2"]', 200);
          }
          return http.Response('forbidden', 403);
        }
        if (url.contains('processSession') && req.method == 'GET') {
          return http.Response(streamBody, 200);
        }
        if (url.contains('processSession')) {
          if (req.body.startsWith('count=0')) {
            return http.Response(
                '51\n[[0,["c","SID-TEST","",8,15,30000]]]\n', 200);
          }
          return http.Response('8\n[1,1,7]\n', 200);
        }
        if (url.contains('batchexecute')) {
          return http.Response(
              ''')]}' [["wrb.fr","hNvQHb",[[["$videoUrl","video/mp4"]]]]]''',
              200);
        }
        if (url.contains('usercontent')) {
          return http.Response.bytes([9, 8, 7, 6], 200);
        }
        return http.Response('not found', 404);
      });
      final backend = TaskBackendClient(
        client: client,
        session: _session(apiKeys: [docKey]),
        // v101 — all keys fire at once (parallel race); the second
        // key's 200 wins and the flow continues.
        apiKeysOverride: [key1, key2, docKey],
        pollInterval: const Duration(milliseconds: 10),
        submitTimeout: const Duration(seconds: 5),
        pageTransport: _FailingPageTransport(),
      );
      final bytes = await backend.run(
        'phone charging',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(bytes, [9, 8, 7, 6]);
      // v101 — the race fires every candidate, including the no-key
      // attempt (''); order is not fixed.
      expect(triedKeys.toSet(), {key1, key2, docKey, ''});
      expect(sawAuthUserHeader, isTrue);
      expect(sawAcceptHeader, isTrue);
      expect(sawNoCookieHeader, isTrue);
      expect(sawSecFetchHeaders, isTrue);
    });
  });

  group('v92: Task backend client (MockClient) — download', () {
    test('download 403 names the step (OSID case)', () async {      const cid = 'c_0123456789abcdef';
      const videoUrl =
          'https://contribution.usercontent.google.com/download?c=VID123';
      final streamPayload = base64Encode(utf8.encode('xx${cid}yy'));
      final streamChunk = '[[3,["$streamPayload"]]]';
      final streamBody = '${streamChunk.length}\n$streamChunk\n';
      final client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('chooseServer')) {
          return http.Response('["GS-TEST",3,null,"1","2"]', 200);
        }
        if (url.contains('processSession') && req.method == 'GET') {
          return http.Response(streamBody, 200);
        }
        if (url.contains('processSession')) {
          if (req.body.startsWith('count=0')) {
            return http.Response(
                '51\n[[0,["c","SID-TEST","",8,15,30000]]]\n', 200);
          }
          return http.Response('8\n[1,1,7]\n', 200);
        }
        if (url.contains('batchexecute')) {
          return http.Response(
              ''')]}' [["wrb.fr","hNvQHb",[[["$videoUrl","video/mp4"]]]]]''',
              200);
        }
        if (url.contains('usercontent')) {
          return http.Response('forbidden', 403);
        }
        return http.Response('not found', 404);
      });
      final backend = TaskBackendClient(
        client: client,
        session: _session(),
        pollInterval: const Duration(milliseconds: 10),
        submitTimeout: const Duration(seconds: 5),
        pageTransport: _FailingPageTransport(),
      );
      try {
        await backend.run(
          'phone charging',
          onPhase: (_, __) {},
          deadline: DateTime.now().add(const Duration(seconds: 30)),
        );
        fail('should throw');
      } on TaskBackendException catch (e) {
        expect(e.step, 'download');
        expect(e.message, contains('403'));
      }
    });
  });

  group('v98: page transport first, Dart HTTP fallback', () {
    test('full flow runs on the page transport; HTTP only sees the stream',
        () async {
      const cid = 'c_0123456789abcdef';
      const videoUrl =
          'https://contribution.usercontent.google.com/download?c=VID123';
      final seenPage = <String>[];
      final page = _CannedPageTransport((method, uri, body) {
        final url = uri.toString();
        if (url.contains('chooseServer')) {
          seenPage.add('chooseServer');
          return BackendResponse(
              200, utf8.encode('["GS-TEST",3,null,"1","2"]'));
        }
        if (url.contains('processSession')) {
          if (body != null && body.startsWith('count=0')) {
            seenPage.add('open');
            return BackendResponse(200,
                utf8.encode('51\n[[0,["c","SID-TEST","",8,15,30000]]]\n'));
          }
          if (body != null && body.contains('ofs=0')) {
            seenPage.add('setup');
            return BackendResponse(200, utf8.encode('8\n[1,1,7]\n'));
          }
          if (body != null && body.contains('ofs=1')) {
            seenPage.add('task');
            return BackendResponse(200, utf8.encode('8\n[1,3,7]\n'));
          }
        }
        if (url.contains('batchexecute')) {
          seenPage.add('poll');
          return BackendResponse(200,
              utf8.encode(''')]}' [["wrb.fr","hNvQHb",[[["$videoUrl","video/mp4"]]]]]'''));
        }
        if (url.contains('usercontent')) {
          seenPage.add('download');
          return BackendResponse(200, [9, 8, 7, 6]);
        }
        return BackendResponse(404, utf8.encode('not found'));
      });
      final streamPayload = base64Encode(utf8.encode('xx${cid}yy'));
      final streamChunk = '[[3,["$streamPayload"]]]';
      final streamBody = '${streamChunk.length}\n$streamChunk\n';
      final client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('processSession') && req.method == 'GET') {
          return http.Response(streamBody, 200);
        }
        fail('HTTP transport must not be used for $url');
      });
      final backend = TaskBackendClient(
        client: client,
        session: _session(),
        pageTransport: page,
        pollInterval: const Duration(milliseconds: 10),
        submitTimeout: const Duration(seconds: 5),
      );
      final bytes = await backend.run(
        'phone charging with golden energy',
        onPhase: (_, __) {},
        deadline: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(bytes, [9, 8, 7, 6]);
      expect(seenPage, containsAll(
          ['chooseServer', 'open', 'setup', 'task', 'poll', 'download']));
    });

    testWidgets('PageBackendTransport decodes the bridge reply; '
        'null reply is a transport failure', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.geminihd.studio/gecko'),
          (call) async {
        if (call.method != 'backendFetch') return null;
        final args = jsonDecode(call.arguments as String) as Map;
        if ((args['url'] as String).contains('chooseServer')) {
          return jsonEncode({
            'status': 200,
            'data':
                'data:application/json;base64,${base64Encode(utf8.encode('["GS",3]'))}',
          });
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(
          const MethodChannel('com.geminihd.studio/gecko'), null));
      final transport = PageBackendTransport();
      final res = await transport.fetch(
        method: 'POST',
        uri: Uri.https('signaler-pa.clients6.google.com',
            '/punctual/v1/chooseServer', {'key': 'k'}),
        headers: {'Origin': 'https://gemini.google.com'},
        body: '{}',
      );
      expect(res.status, 200);
      expect(res.text, '["GS",3]');
      try {
        await transport.fetch(
          method: 'GET',
          uri: Uri.https('example.com', '/nope'),
        );
        fail('should throw');
      } on TaskBackendException catch (e) {
        expect(e.step, 'transport');
      }
    });
  });
}
