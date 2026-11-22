/// v92 — Task-mode video BACKEND: generate a video through Gemini's
/// Task (Spark) agent WITHOUT opening the browser.
///
/// Wire protocol, reverse-engineered from the user's own Task-mode
/// HARs (Nov 2026, two captures — one mid-session, one from page
/// load):
///  1. chooseServer (signaler-pa) -> gsessionid. The API key (AIza…)
///     is one of the page HTML's own document keys (v97, verified
///     against the HAR by hash — v94's bundle-keys idea was wrong)
///     and the X-Server-Token (page key "PI9WOb") from the page HTML
///     at session fetch, exactly like SNlM0e — never hardcoded.
///  v98 — the requests below run through [BackendTransport]: the
///  page transport performs them INSIDE the signed-in Gemini page
///  (the extension's content-script fetch — the browser's own
///  requests: its cookies, Origin, Referer, sec-fetch, HTTP/2 and
///  TLS), with the Dart HTTP transport as fallback when the page is
///  unreachable. The long-poll stream stays on Dart HTTP (its GET
///  matches the browser's multi-watch shape).
///  2. processSession channel open (POST count=0) -> SID. Auth is
///     the $httpHeaders param: SAPISIDHASH (computed from the
///     SAPISID cookie — standard sha1 scheme), X-Goog-AuthUser,
///     X-Goog-Api-Key, X-Server-Token.
///  3. processSession long-poll GET -> the stream carries the
///     conversation id (c_…) and response id (r_…) as plain ASCII
///     inside base64 protobuf chunks.
///  4. processSession setup (ofs=0) + task (ofs=1). The task text
///     is a plain string in a tiny protobuf — trivially buildable.
///  5. batchexecute hNvQHb poll -> the finished MP4's
///     contribution.usercontent.google.com/download URL.
///  6. Download the MP4 with the account cookies.
///
/// Honest limits (from the HAR analysis — read before "fixing"):
/// - The setup message the web page sends carries an encrypted
///   client token (f4) + its hash (f5) that the page's JS mints and
///   that appears in NO captured response, document, or cookie, so
///   v92 sends the setup WITHOUT those two fields. If the server
///   requires them, the backend fails with the exact step and the
///   engine falls back to the v91 browser driver — the video still
///   gets made, just in the browser.
/// - The MP4 download may need a browser-minted OSID cookie (the
///   Chat-flow devlog); v92 tries the cookie jar first and reports
///   the exact HTTP status on failure (same fallback).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'gecko_browser.dart';
import 'models.dart';

/// The backend failed at a named step. The engine reports the step
/// and falls back to the browser driver.
class TaskBackendException implements Exception {
  final String step;
  final String message;
  const TaskBackendException(this.step, this.message);
  @override
  String toString() => 'Task backend ($step): $message';
}

// ---------------------------------------------------------------------
// v98 — Backend transport: WHO performs the HTTP exchanges.
// The page transport runs each request INSIDE the signed-in Gemini
// page (the extension's content-script fetch), so the request IS the
// browser's own: its cookies, Origin, Referer, sec-fetch headers,
// HTTP/2 and TLS fingerprint all come from the real browser, and no
// header has to be faked in Dart. The HTTP transport is plain Dart
// HttpClient (v97 behaviour) — the fallback when the page is
// unreachable, and the transport the tests drive with a MockClient.
// A transport-level failure is reported as step 'transport' so the
// client can retry the whole flow on the other transport; an HTTP
// error status is a real step failure and is never retried.
// ---------------------------------------------------------------------

/// One HTTP exchange, however it was performed.
class BackendResponse {
  BackendResponse(this.status, this.bytes, {this.headers = const {}});
  final int status;
  final List<int> bytes;
  final Map<String, String> headers;
  String get text => utf8.decode(bytes);
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }
}

/// Performs one HTTP exchange. [headers] are the headers the caller
/// wants; a transport may drop the ones it supplies itself (the page
/// transport drops Origin/Referer/Cookie/User-Agent/sec-fetch-* —
/// fetch forbids setting them, and the page provides the real ones).
abstract class BackendTransport {
  /// [timeout] bounds the whole exchange when given (v142: the
  /// long-poll stream GET legitimately takes ~52s+, so the stream
  /// passes its own timeout; every other call leaves it null).
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  });
}

/// Plain Dart HTTP (v92–v97 behaviour).
class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport(this._client);
  final http.Client _client;

  @override
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    Future<BackendResponse> go() async {
      final req = http.Request(method, uri);
      if (headers != null) req.headers.addAll(headers);
      if (body != null) req.body = body;
      final streamed = await _client.send(req);
      final bytes = await streamed.stream.toBytes();
      return BackendResponse(streamed.statusCode, bytes,
          headers: streamed.headers);
    }

    return timeout == null ? go() : go().timeout(timeout);
  }
}

/// v98 — the requests run in the Gemini page via the extension
/// bridge (GeckoBrowser.backendFetch -> background.js -> content.js
/// fetch with the page's own credentials). The reply is a JSON
/// string {status, data: "data:<mime>;base64,…", error?}; a null
/// reply (no tab, no answer in time) or an error field is a
/// transport failure.
class PageBackendTransport implements BackendTransport {
  @override
  Future<BackendResponse> fetch({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    final raw = await GeckoBrowser.instance.backendFetch(
      method: method,
      url: uri.toString(),
      headers: headers ?? const {},
      body: body ?? '',
      // v142 — the stream poll passes its own (long) timeout; every
      // other call keeps the 60s native default (v101).
      timeoutMs: timeout?.inMilliseconds ?? 60000,
    );
    if (raw == null) {
      throw const TaskBackendException('transport',
          'Page transport-e jukto hoyni — Gemini tab khuleni ba uttor asheni.');
    }
    Map m;
    try {
      m = jsonDecode(raw) as Map;
    } catch (_) {
      throw const TaskBackendException(
          'transport', 'Page transport theke bujha jayna uttor aslo.');
    }
    if (m['error'] != null) {
      throw TaskBackendException('transport', '${m['error']}');
    }
    final data = m['data'] as String? ?? '';
    final b64 =
        data.contains(',') ? data.substring(data.indexOf(',') + 1) : data;
    List<int> bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      throw const TaskBackendException(
          'transport', 'Page transport-er uttor base64 na.');
    }
    return BackendResponse(m['status'] as int? ?? 0, bytes);
  }
}

// ---------------------------------------------------------------------
// SAPISIDHASH scheme (Google's standard): "<unix seconds>_<sha1(
// "<seconds> <SAPISID> <origin>")>". The app's cookie jar holds
// SAPISID, so the hash is computable without ever seeing a password.
// ---------------------------------------------------------------------

/// Google's SAPISIDHASH scheme: "<unix seconds>_<sha1("<seconds>
/// <SAPISID> <origin>")>". The app's cookie jar holds SAPISID, so
/// the hash is computable without ever seeing a password.
String sapisidHash(String sapisid, String origin, [int? timestampSec]) {
  final ts = timestampSec ??
      (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final digest = sha1.convert(utf8.encode('$ts $sapisid $origin'));
  return '${ts}_$digest';
}

// ---------------------------------------------------------------------
// Minimal protobuf writer (varint + length-delimited only —
// everything the Task channel sends).
// ---------------------------------------------------------------------

class _PbWriter {
  final _buf = BytesBuilder();
  void varintField(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  void bytesField(int field, List<int> bytes) {
    _tag(field, 2);
    _varint(bytes.length);
    _buf.add(bytes);
  }

  void stringField(int field, String value) =>
      bytesField(field, utf8.encode(value));

  void messageField(int field, List<int> nested) =>
      bytesField(field, nested);

  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int value) {
    var v = value;
    while (true) {
      if ((v & ~0x7F) == 0) {
        _buf.addByte(v);
        return;
      }
      _buf.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
  }

  Uint8List toBytes() => _buf.toBytes();
}

/// Minimal protobuf reader, for tests (round-trip the builders).
/// Length-delimited values are always returned as raw bytes — the
/// caller decodes strings with [utf8.decode].
List<({int field, int wire, dynamic value})> pbDecode(List<int> bytes) {
  final out = <({int field, int wire, dynamic value})>[];
  var i = 0;
  int varint() {
    var shift = 0;
    var v = 0;
    while (true) {
      final b = bytes[i++];
      v |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return v;
      shift += 7;
    }
  }

  while (i < bytes.length) {
    final tag = varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 0) {
      out.add((field: field, wire: wire, value: varint()));
    } else if (wire == 2) {
      final len = varint();
      final sub = bytes.sublist(i, i + len);
      i += len;
      out.add((field: field, wire: wire, value: sub));
    } else if (wire == 1) {
      i += 8;
      out.add((field: field, wire: wire, value: null));
    } else if (wire == 5) {
      i += 4;
      out.add((field: field, wire: wire, value: null));
    } else {
      throw const FormatException('bad protobuf wire type');
    }
  }
  return out;
}

String _uuid() {
  final r = Random.secure();
  String hex(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${hex(8)}-${hex(4)}-4${hex(3)}-'
      '${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-'
      '${hex(12)}'.toUpperCase();
}

String _randZx([int n = 12]) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

String _b64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

// ---------------------------------------------------------------------
// Message builders (pure — unit-tested). Field layouts are from the
// user's Task-mode HARs; the fixed byte blobs are the web client's
// constant sub-messages, copied verbatim.
// ---------------------------------------------------------------------

/// The task submit (HAR: POST ofs=1):
/// f2 { f1: 1, f9 { f1: "<task text>" } }.
Uint8List buildTaskMessage(String taskText) {
  final inner = _PbWriter()..stringField(1, taskText);
  final outer = _PbWriter()
    ..varintField(1, 1)
    ..messageField(9, inner.toBytes());
  final root = _PbWriter()..messageField(2, outer.toBytes());
  return root.toBytes();
}

/// The session setup (HAR: POST ofs=0). The web page's version also
/// carries an encrypted client token (f4) + its hash (f5) that the
/// page's JS mints and that appears in no captured response,
/// document, or cookie — v92 sends the setup WITHOUT them. Every
/// other field is exactly as captured (fixed blobs copied verbatim).
Uint8List buildSetupMessage(String uuid) {
  final inner = _PbWriter()
    ..bytesField(1, [0x0A, 0x00, 0x10, 0x00, 0x38, 0x00])
    ..bytesField(2, [0x0A, 0x02, 0x65, 0x6E])
    ..bytesField(7, [0x08, 0x01])
    ..varintField(8, 1)
    ..varintField(11, 1)
    ..varintField(12, 0)
    ..bytesField(18, [0x0A, 0x02, 0x08, 0x00])
    ..varintField(19, 0)
    ..varintField(28, 1)
    ..bytesField(31, [0x04, 0x1B, 0x1C, 0x10, 0x13, 0x0C])
    ..bytesField(42, [0x08, 0x01])
    ..varintField(50, 40)
    ..varintField(54, 0)
    ..stringField(60, uuid)
    ..stringField(62, '')
    ..varintField(68, 0)
    ..varintField(69, 2)
    ..varintField(80, 3)
    ..varintField(81, 1)
    ..varintField(92, 1)
    ..varintField(97, 0)
    ..varintField(99, 1);
  final f5 = _PbWriter()
    ..messageField(1, inner.toBytes())
    ..varintField(4, 1);
  final f8 = _PbWriter()..messageField(5, f5.toBytes());
  final f1 = _PbWriter()
    ..messageField(1, (_PbWriter()
          ..varintField(1, 1)
          ..stringField(2, 'e6fa609c3fa255c0')
          ..stringField(3, 'en')
          ..stringField(4, uuid))
        .toBytes())
    ..varintField(2, 0)
    ..messageField(8, f8.toBytes());
  return f1.toBytes();
}

/// chooseServer request body (HAR: verbatim JSON).
String buildChooseServerBody() =>
    '[[null,null,null,[9,5],null,[["assistant-bard"],[null,1],'
    '[[["bard-client-sync"]]]]],null,null,0,0]';

/// chooseServer response: ["<gsessionid>",3,null,"...","..."].
String? parseChooseServer(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded[0];
      if (first is String && first.isNotEmpty) return first;
    }
  } catch (_) {}
  return null;
}

/// Channel-open response: `51\n[[0,["c","<SID>","",8,15,30000]]]\n`.
String? parseChannelOpen(String body) {
  final m = RegExp(r'\["c","([A-Za-z0-9_\-]+)"').firstMatch(body);
  return m?.group(1);
}

/// Scan raw stream bytes for conversation / response ids (they ride
/// as plain ASCII inside the base64 protobuf chunks).
({Set<String> conversations, Set<String> responses}) extractStreamIds(
    List<int> bytes) {
  final text = String.fromCharCodes(bytes);
  final conv = <String>{};
  final resp = <String>{};
  void scan(String s) {
    for (final m in RegExp(r'c_[0-9a-f]{16}').allMatches(s)) {
      conv.add(m.group(0)!);
    }
    for (final m in RegExp(r'r_[0-9a-f]{16}').allMatches(s)) {
      resp.add(m.group(0)!);
    }
  }
  scan(text);
  // v137 (HAR #224): processSession stream delivers protobuf payloads as
  // base64 strings inside JSON arrays; decode each candidate chunk too.
  for (final m in RegExp(r'"([A-Za-z0-9+/=_-]{24,})"').allMatches(text)) {
    final raw = m.group(1)!;
    try {
      final norm = base64.normalize(raw.replaceAll('-', '+').replaceAll('_', '/'));
      scan(String.fromCharCodes(base64.decode(norm)));
    } catch (_) {}
  }
  return (conversations: conv, responses: resp);
}

/// hNvQHb request inner args (HAR: verbatim):
/// ["<conversation id>",10,null,1,[1],[4,12],null,1].
String buildHnvQhbReq(String conversationId) => jsonEncode([
      conversationId,
      10,
      null,
      1,
      [1],
      [4, 12],
      null,
      1,
    ]);

/// The finished MP4's download URL inside a batchexecute response.
/// The response text carries JSON escapes (\u003d etc.), so unescape
/// first, then take the URL up to its closing quote.
String? extractVideoDownloadUrl(String body) {
  // v139 (HAR #409): batchexecute double-escapes nested JSON strings
  // (\\u003d / \\u0026), so unescape double backslashes BEFORE \uXXXX.
  // v140 - the chain missed \u002B (+) and \u002F (/): a download
  // token carrying either left a literal backslash in the URL, the
  // URL regex below stops at the backslash, and the truncated URL
  // 404s on download. Both cases (B/F upper + lower) are handled.
  final unescaped = body
      .replaceAll(r'\\u003d', '=')
      .replaceAll(r'\\u0026', '&')
      .replaceAll(r'\\u002b', '+')
      .replaceAll(r'\\u002B', '+')
      .replaceAll(r'\\u002f', '/')
      .replaceAll(r'\\u002F', '/')
      .replaceAll(r'\u003d', '=')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\u002b', '+')
      .replaceAll(r'\u002B', '+')
      .replaceAll(r'\u002f', '/')
      .replaceAll(r'\u002F', '/')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\');
  final m = RegExp(
          r'https://contribution\.usercontent\.google\.com/download\?c=[^"\\\s,\]]+')
      .firstMatch(unescaped);
  return m?.group(0);
}

/// Extract every AIza API key from the Gemini page HTML (the signaler
/// key is one of them; the client tries each for chooseServer).
/// v97 — verified against the HAR by hash: the chooseServer ?key=
/// is one of these document keys (also the ?key= on the signaler
/// multi-watch/refreshCreds calls). The v94 idea that the key lived
/// in the UI JS bundle was wrong — the bundle's keys belong to other
/// Google services (one is the X-Goog-Api-Key on a waa-pa call).
List<String> extractApiKeys(String html) {
  final seen = <String>{};
  for (final m in RegExp(r'AIza[0-9A-Za-z_\-]{35}').allMatches(html)) {
    seen.add(m.group(0)!);
    if (seen.length >= 20) break;
  }
  return seen.toList();
}

// ---------------------------------------------------------------------
// The client: channel + task + poll + download.
// ---------------------------------------------------------------------

class TaskBackendClient {
  TaskBackendClient({
    required http.Client client,
    required this.session,
    this.pollInterval = const Duration(seconds: 30),
    this.submitTimeout = const Duration(minutes: 10),
    this.apiKeysOverride,
    BackendTransport? pageTransport,
  })  : _client = client,
        _httpTransport = HttpBackendTransport(client),
        _pageTransport = pageTransport ?? PageBackendTransport();

  final http.Client _client;

  /// Dart HTTP transport — the fallback when the page transport is
  /// unreachable (v142: the long-poll stream also runs on the
  /// transport now, page first; the raw-HTTP stream GET was the last
  /// request Google could bot-check).
  final BackendTransport _httpTransport;

  /// v98 — page transport (requests run inside the Gemini page).
  final BackendTransport _pageTransport;
  final GeminiSession session;

  /// The key list to try for chooseServer. When set, it replaces the
  /// session's document keys (a seam for tests and for callers that
  /// already resolved the keys); otherwise the session's document
  /// keys are used.
  final List<String>? apiKeysOverride;

  /// How often to poll hNvQHb for the finished video URL.
  final Duration pollInterval;

  /// How long to wait for the channel + conversation id before
  /// giving up (the engine then falls back to the browser driver).
  final Duration submitTimeout;

  static const _signalerHost = 'signaler-pa.clients6.google.com';
  static const _channelHost = 'geminiweb-pa.clients6.google.com';
  static const _origin = 'https://gemini.google.com';
  // v137 (HAR #128/#222): Gemini Web's public client-side API key for
  // geminiweb-pa.clients6.google.com/v1/processSession.
  static const _geminiWebPaApiKey = 'AIzaSyAPW83vB9zFQqfpMup_cMJdELqDQkWvTho';

  String? _sapisid;
  String get _cookieHeader => session.cookieHeader;

  /// Closes the underlying HTTP client. Only call when this client
  /// owns it (StudioEngine closes the one it created; an injected
  /// test client stays open).
  void close() => _client.close();

  /// v97 — chooseServer mirrors the browser's working request (HAR
  /// entry #97) exactly: NO Cookie header (the browser's request
  /// carried none — the app's session cookies on this call are the
  /// prime suspect for the 403), plus the fetch metadata headers a
  /// browser sends. The channel open and the rest of the flow keep
  /// using [_formHeaders] (with cookies + SAPISIDHASH).
  Map<String, String> _chooseServerHeaders() => {
        'Content-Type': 'application/json+protobuf',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.7',
        'User-Agent': _ua,
        'Origin': _origin,
        'Referer': '$_origin/',
        'X-Goog-AuthUser': '${session.authUser}',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      };

  Map<String, String> _formHeaders() => {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': _ua,
        'Origin': _origin,
        'Referer': '$_origin/',
        if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
      };

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  String? _cookieValue(String name) {
    final m = RegExp('(?:^|;\\s*)$name=([^;]+)')
        .firstMatch(_cookieHeader);
    return m?.group(1);
  }

  /// Runs the whole backend flow and returns the finished MP4 bytes.
  /// Throws [TaskBackendException] naming the failed step; the caller
  /// (AnimationEngine) falls back to the browser driver.
  /// v98 — the flow runs on the page transport first (the browser's
  /// own requests). A transport-level failure ('transport' step: no
  /// Gemini tab, no reply) retries the whole flow on Dart HTTP; a
  /// real step failure is NOT retried — the page IS the browser, so
  /// Dart would fail the same way.
  Future<Uint8List> run(
    String taskText, {
    required void Function(String phase, String message) onPhase,
    required DateTime deadline,
  }) async {
    _sapisid = _cookieValue('SAPISID');
    if (_sapisid == null || _sapisid!.isEmpty) {
      throw const TaskBackendException(
          'auth', 'SAPISID cookie pelam na — Login tab-e abar sign in koro.');
    }
    // v140 — page transport FIRST (v98 behaviour, restored): the
    // requests run inside the signed-in Gemini page, so Google sees
    // a real browser, not a bot. v137 ran the whole flow on raw Dart
    // HTTP and Google bot-checked it live (chooseServer 403 + the
    // /u/0/app bot-check, 2026-11-21) — the backend never succeeded
    // live in any version. Only a transport failure ('transport'
    // step: no Gemini tab, no reply) retries the whole flow on Dart
    // HTTP; a real step failure is NOT retried — the page IS the
    // browser, so Dart would fail the same way. The flow itself is
    // still v137's HAR-verified one (processSession direct #222,
    // long-poll stream #224, setup + task #225/#229, hNvQHb #409).
    // v142 — the stream GET runs on the page too: the 20:47 live
    // test proved the raw-HTTP stream never delivers a c_... id.
    try {
      return await _runFlow(_pageTransport, taskText,
          onPhase: onPhase, deadline: deadline);
    } on TaskBackendException catch (e) {
      if (e.step != 'transport') rethrow;
      onPhase('opening', 'Page transport hoyni — Dart diye chesta…');
      return await _runFlow(_httpTransport, taskText,
          onPhase: onPhase, deadline: deadline);
    }
  }

  Future<Uint8List> _runFlow(
    BackendTransport transport,
    String taskText, {
    required void Function(String phase, String message) onPhase,
    required DateTime deadline,
  }) async {
    _workingApiKey = _geminiWebPaApiKey;
    onPhase('opening', 'Gemini Task channel khulche…');
    final opened = await _openChannelDirect(transport);
    final sid = opened.sid;
    var gsessionid = opened.gsessionid;
    if (gsessionid.isEmpty) {
      // Fallback for unit-test mocks that expect chooseServer.
      gsessionid = await _chooseServer(transport);
    }
    // v137 (HAR #224 -> #225 -> #229): start long-poll stream, then send
    // setup (ofs=0) and task (ofs=1) IMMEDIATELY before awaiting c_...
    // (Gemini creates c_... in response to setup + task).
    // v142 — the stream runs on the SAME transport as the POSTs: the
    // 20:47 live test proved the channel/setup/task POSTs succeed via
    // the page while the raw-HTTP stream never delivered a c_... id
    // in 10 min (Google bot-checks raw Dart HTTP — chooseServer 403
    // + /u/0/app bot-check, 2026-11-21). The page fetch carries the
    // live browser cookies, so a stale Dart-side jar can't starve
    // the stream either.
    final stream = _ChannelStream(transport, sid, gsessionid, _cookieHeader, initialRid: opened.rid);
    unawaited(stream.run(deadline));
    try {
      onPhase('opening', 'Task pathacche…');
      await _sendSetup(transport, sid, gsessionid, stream);
      await _sendTask(transport, sid, gsessionid, stream, taskText);
      onPhase('creating', 'Task thread toiri hocche…');
      final conversationId = await stream.conversationId.timeout(
          submitTimeout,
          onTimeout: () => throw TaskBackendException(
              'channel',
              'Conversation id asheni — channel khuleche kintu Gemini '
              'kono task thread banayni. (stream: ${stream.polls} poll, '
              'sesh HTTP ${stream.lastStatus ?? '-'}, ${stream.lastBytes} byte.)'));
      onPhase('creating', 'Backend-e video banacche…');
      final url = await _pollForVideo(transport, conversationId, onPhase, deadline);
      onPhase('downloading', 'MP4 download hocche…');
      return await _download(transport, url);
    } finally {
      stream.stop();
    }
  }

  /// The API key that worked for chooseServer (the channel open must
  /// use the same one). Empty when chooseServer worked without a key.
  String _workingApiKey = '';

  Future<String> _chooseServer(BackendTransport transport) async {
    final keys = [...(apiKeysOverride ?? session.apiKeys), ''];
    // v101 — fire ALL key attempts AT ONCE and take the first 200:
    // sequentially the loop burned up to 9 x 25s = ~4 min on a slow
    // network before the channel even opened. The winner's key is
    // recorded (the channel open must use the same key), so the
    // attempts return records and only the winner's key is kept.
    // NOTE: Dart's Future.any completes on the FIRST error too, so
    // it cannot race fallible attempts — _firstSuccess below waits
    // for the first VALUE and only errors when every attempt failed.
    // A transport failure still rethrows at once (the page is
    // unreachable — no key would work), exactly like before.
    final attempts =
        keys.map((key) => _tryChooseServerKey(transport, key));
    try {
      final winner = await _firstSuccess(attempts);
      _workingApiKey = winner.key;
      return winner.gsessionid;
    } catch (e) {
      if (e is TaskBackendException && e.step == 'transport') rethrow;
      // v97 — report how many keys were tried: 1 means the page
      // gave no keys at all, 9 means all 8 page keys + no-key failed.
      throw TaskBackendException('chooseServer',
          'Server pick kora jayni (${keys.length} key try): $e');
    }
  }

  /// First successful result wins; errors are ignored until every
  /// attempt has failed, in which case a transport failure takes
  /// priority (so Dart HTTP fallback runs) over generic timeouts.
  Future<({String key, String gsessionid})> _firstSuccess(
      Iterable<Future<({String key, String gsessionid})>> attempts) {
    final completer = Completer<({String key, String gsessionid})>();
    var remaining = 0;
    Object? lastError;
    StackTrace? lastStack;
    TaskBackendException? transportError;
    StackTrace? transportStack;
    for (final attempt in attempts) {
      remaining++;
      attempt.then((value) {
        if (!completer.isCompleted) completer.complete(value);
      }, onError: (Object e, StackTrace st) {
        if (e is TaskBackendException && e.step == 'transport') {
          transportError ??= e;
          transportStack ??= st;
        }
        lastError = e;
        lastStack = st;
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          if (transportError != null) {
            completer.completeError(transportError!, transportStack!);
          } else {
            completer.completeError(lastError!, lastStack!);
          }
        }
      });
    }
    if (remaining == 0) {
      // Unreachable in practice (the key list always ends with the
      // no-key attempt), but never hang forever on an empty race.
      completer.completeError(const TaskBackendException(
          'chooseServer', 'Server pick kora jayni (0 key try).'));
    }
    return completer.future;
  }

  Future<({String key, String gsessionid})> _tryChooseServerKey(
      BackendTransport transport, String key) async {
    final uri = Uri.https(
      _signalerHost,
      '/punctual/v1/chooseServer',
      {if (key.isNotEmpty) 'key': key},
    );
    final isPage = identical(transport, _pageTransport);
    // v128 — on a slow network (1–5 KB/s), a brand-new headless
    // GeckoView tab can take >25s just to load gemini.google.com/app.
    // Previously TimeoutException was wrapped as step 'chooseServer',
    // which blocked the automatic Dart HTTP fallback (where chooseServer
    // completes directly in ~1s without loading the 6 MB web page).
    // Now a page-transport timeout reports step 'transport' so run()
    // falls back to Dart HTTP cleanly, and Dart HTTP gets 45s.
    final BackendResponse res;
    // v129 — unlimited wait on Dart HTTP; page transport still fails
    // over to Dart HTTP after 20s if the headless tab has not loaded.
    final reqFuture = transport.fetch(
        method: 'POST',
        uri: uri,
        headers: _chooseServerHeaders(),
        body: buildChooseServerBody());
    if (isPage) {
      try {
        res = await reqFuture.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw const TaskBackendException(
            'transport', 'Page transport time out — Dart HTTP diye chesta.');
      }
    } else {
      res = await reqFuture;
    }
    if (res.status != 200) {
      throw TaskBackendException('chooseServer',
          'HTTP ${res.status} (key ${key.isEmpty ? 'chara' : 'diye'})');
    }
    final gs = parseChooseServer(res.text);
    if (gs != null) {
      return (key: key, gsessionid: gs);
    }
    throw const TaskBackendException(
        'chooseServer', 'gsessionid pelam na.');
  }

  String _httpHeadersValue() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final auth = sapisidHash(_sapisid!, _origin, ts);
    final reqUuid = _uuid();
    final ext525005358 = base64.encode((_PbWriter()
          ..stringField(1, reqUuid)
          ..varintField(2, 1))
        .toBytes());
    final apiKey =
        _workingApiKey.isNotEmpty ? _workingApiKey : _geminiWebPaApiKey;
    final parts = <String>[
      'Authorization:SAPISIDHASH $auth '
          'SAPISID1PHASH $auth SAPISID3PHASH $auth',
      'X-Goog-AuthUser:${session.authUser}',
      'X-Goog-Api-Key:$apiKey',
      if (session.serverToken.isNotEmpty)
        'X-Server-Token:${session.serverToken}',
      'x-goog-ext-73010989-bin:CAA=',
      'x-goog-ext-525005358-bin:$ext525005358',
      'x-goog-ext-73010990-bin:CAAQABgA',
      'X-WebChannel-Content-Type:application/x-protobuf',
    ];
    return '${parts.join('\r\n')}\r\n';
  }

  /// v137 (HAR #222): opens geminiweb-pa/v1/processSession directly and
  /// extracts BOTH the channel SID (body) and gsessionid (x-http-session-id
  /// response header) — no signaler-pa/chooseServer call needed.
  Future<({String sid, String gsessionid, int rid})> _openChannelDirect(
      BackendTransport transport) async {
    final rid = 1000 + Random.secure().nextInt(90000);
    final uri = Uri.https(_channelHost, '/v1/processSession', {
      'VER': '8',
      'RID': '$rid',
      'CVER': '22',
      'X-HTTP-Session-Id': 'gsessionid',
      r'$httpHeaders': _httpHeadersValue(),
      'zx': _randZx(),
      't': '1',
    });
    final res = await transport.fetch(
        method: 'POST', uri: uri, headers: _formHeaders(), body: 'count=0');
    if (res.status != 200) {
      throw TaskBackendException(
          'channel', 'Channel khola jayni: HTTP ${res.status}.');
    }
    final sid = parseChannelOpen(res.text);
    if (sid == null) {
      throw const TaskBackendException(
          'channel', 'Channel khullo kintu session id pelam na.');
    }
    final gs = res.header('x-http-session-id') ?? '';
    return (sid: sid, gsessionid: gs, rid: rid);
  }

  Uri _messageUri(String sid, String gsessionid, _ChannelStream stream) {
    stream.nextRid();
    return Uri.https(_channelHost, '/v1/processSession', {
      'VER': '8',
      'gsessionid': gsessionid,
      'SID': sid,
      'RID': '${stream.rid}',
      'AID': '${stream.lastMsgIndex}',
      'zx': _randZx(),
      't': '1',
    });
  }

  Future<void> _sendSetup(BackendTransport transport, String sid,
      String gsessionid, _ChannelStream stream) async {
    final uuid = _uuid();
    final body =
        'count=1&ofs=0&req0___data__=${Uri.encodeQueryComponent(base64.encode(buildSetupMessage(uuid)))}';
    final res = await transport
        .fetch(
            method: 'POST',
            uri: _messageUri(sid, gsessionid, stream),
            headers: _formHeaders(),
            body: body);
    if (res.status != 200) {
      throw TaskBackendException(
          'setup', 'Session setup pathano jayni: HTTP ${res.status}.');
    }
  }

  Future<void> _sendTask(BackendTransport transport, String sid,
      String gsessionid, _ChannelStream stream, String taskText) async {
    final body =
        'count=1&ofs=1&req0___data__=${Uri.encodeQueryComponent(base64.encode(buildTaskMessage(taskText)))}';
    final res = await transport
        .fetch(
            method: 'POST',
            uri: _messageUri(sid, gsessionid, stream),
            headers: _formHeaders(),
            body: body);
    if (res.status != 200) {
      throw TaskBackendException(
          'task', 'Task pathano jayni: HTTP ${res.status}.');
    }
  }

  Future<String> _pollForVideo(BackendTransport transport,
      String conversationId, void Function(String phase, String message) onPhase,
      DateTime deadline) async {
    var waited = 0;
    while (DateTime.now().isBefore(deadline)) {
      final uri = Uri.https('gemini.google.com',
          '/_/BardChatUi/data/batchexecute', {
        'rpcids': 'hNvQHb',
        'source-path': '/app/$conversationId',
        'bl': session.bl,
        'f.sid': session.fSid,
        'hl': 'en',
        '_reqid': '${100000 + Random.secure().nextInt(900000)}',
        'rt': 'c',
      });
      final freReq = jsonEncode([
        [
          [
            'hNvQHb',
            buildHnvQhbReq(conversationId),
            null,
            'generic',
          ]
        ]
      ]);
      try {
        final res = await transport
            .fetch(
                method: 'POST',
                uri: uri,
                headers: {
                  'Content-Type':
                      'application/x-www-form-urlencoded;charset=UTF-8',
                  'X-Same-Domain': '1',
                  'User-Agent': _ua,
                  'Origin': _origin,
                  'Referer': '$_origin/',
                  if (_cookieHeader.isNotEmpty)
                    'Cookie': _cookieHeader,
                },
                body: Uri(queryParameters: {
                  'f.req': freReq,
                  'at': session.at,
                }).query)
            .timeout(const Duration(seconds: 60));
        if (res.status == 200) {
          final url = extractVideoDownloadUrl(res.text);
          if (url != null) return url;
        }
      } on TaskBackendException catch (e) {
        // v98 — a transport failure (page unreachable) must surface
        // so run() can retry the whole flow on the other transport;
        // only a real poll failure is retried here.
        if (e.step == 'transport') rethrow;
        // One failed poll never kills the run — the next poll retries.
      } catch (_) {
        // One failed poll never kills the run — the next poll retries.
      }
      waited += pollInterval.inSeconds;
      onPhase('creating', 'Backend-e video banacche… (${waited}s)');
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future.delayed(
          remaining < pollInterval ? remaining : pollInterval);
    }
    throw const TaskBackendException('poll',
        'Video link asheni — Task sesh hoyeche kina bujha jayni.');
  }

  Future<Uint8List> _download(BackendTransport transport, String url) async {
    final res = await transport.fetch(method: 'GET', uri: Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Referer': '$_origin/',
      if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
    });
    if (res.status != 200 || res.bytes.isEmpty) {
      throw TaskBackendException('download',
          'MP4 download hoyni: HTTP ${res.status}. Browser theke '
          'download korte hobe (OSID cookie lagte pare).');
    }
    return Uint8List.fromList(res.bytes);
  }
}

/// The processSession long-poll: reads the chunked stream
/// (`<len>\n[[n,["<base64>"]]]\n`) and exposes the conversation id
/// as soon as it arrives. Re-opens the GET with AID=<last index>
/// when the server closes it, until [deadline].
class _ChannelStream {
  _ChannelStream(
      this._transport, this._sid, this._gsessionid, this._cookieHeader,
      {int? initialRid})
      : rid = initialRid ?? (1000 + Random.secure().nextInt(90000));

  /// v142 — the stream runs on the caller's transport (page first,
  /// Dart HTTP on fallback), NOT on a raw http.Client: the raw-HTTP
  /// stream GET was the last request Google could bot-check, and the
  /// 20:47 live test proved it never delivers a c_... id.
  final BackendTransport _transport;
  final String _sid;
  final String _gsessionid;
  final String _cookieHeader;

  int rid;
  int lastMsgIndex = 0;
  bool _stopped = false;

  /// v142 diagnostics for the error log: how many polls ran, the
  /// last poll's HTTP status and how many bytes it carried. A 200
  /// with bytes but no c_... id means Gemini ignored the task
  /// (setup f4/f5 suspect); a non-200 means the stream itself was
  /// blocked.
  int polls = 0;
  int? lastStatus;
  int lastBytes = 0;

  final _conversationIdCompleter = Completer<String>();
  Future<String> get conversationId => _conversationIdCompleter.future;

  void stop() {
    _stopped = true;
  }

  void nextRid() {
    rid++;
  }

  Future<void> run(DateTime deadline) async {
    var transportFailures = 0;
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      try {
        await _onePoll(deadline);
        transportFailures = 0;
      } catch (e) {
        if (_stopped) return;
        // v142 — a transport failure is not a transient stream hiccup:
        // the page tab is gone, so retrying the poll is pointless.
        // Fail the id wait after 2 in a row so run() falls back to
        // Dart HTTP instead of spinning until the submit timeout.
        if (e is TaskBackendException && e.step == 'transport') {
          if (++transportFailures >= 2 &&
              !_conversationIdCompleter.isCompleted) {
            _conversationIdCompleter.completeError(e);
            return;
          }
        } else {
          transportFailures = 0;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_stopped) return;
      if (_conversationIdCompleter.isCompleted) {
        await Future.delayed(const Duration(seconds: 5));
      } else {
        // v142 — a poll that answers instantly (a 403/blocked stream,
        // or a short empty poll) must not spin the loop on microtasks
        // alone: a microtask-only loop starves the event loop's
        // timers, so the submit timeout never fires. A 2s gap is
        // nothing next to a 52s poll, and it keeps a failing stream
        // from hot-spinning on the phone.
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// v138 (HAR #224): processSession GET is a 52s+ server-sent long-poll
  /// stream. v142 — it runs through the transport like every other
  /// backend request (the page fetch waits for the full poll body,
  /// so c_... lands ~52s in instead of ~1s — well inside the 10 min
  /// submit timeout). The poll timeout is 180s: the server holds the
  /// poll ~52s and his ~4 KB/s network adds transfer time; the 60s
  /// native default would cut it off.
  Future<void> _onePoll(DateTime deadline) async {
    if (DateTime.now().isAfter(deadline)) return;
    final uri = Uri.https(
        TaskBackendClient._channelHost, '/v1/processSession', {
      'gsessionid': _gsessionid,
      'VER': '8',
      'RID': 'rpc',
      'SID': _sid,
      'AID': '$lastMsgIndex',
      'CI': '0',
      'TYPE': 'xmlhttp',
      'zx': _randZx(),
      't': '1',
    });
    // The page strips Origin/Referer/Cookie/User-Agent and sets its
    // own (content.js backendFetch); Dart HTTP needs them here.
    final res = await _transport.fetch(
      method: 'GET',
      uri: uri,
      headers: {
        'Accept': '*/*',
        'User-Agent': TaskBackendClient._ua,
        'Origin': TaskBackendClient._origin,
        'Referer': '${TaskBackendClient._origin}/',
        if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
      },
      timeout: const Duration(seconds: 180),
    );
    polls++;
    lastStatus = res.status;
    lastBytes = res.bytes.length;
    if (res.status != 200) return;
    _inspectBuffer(res.bytes);
  }

  void _inspectBuffer(List<int> buffer) {
    if (buffer.isEmpty) return;
    final text = String.fromCharCodes(buffer);
    for (final m in RegExp(r'\[\[(\d+),').allMatches(text)) {
      final idx = int.tryParse(m.group(1)!);
      if (idx != null && idx > lastMsgIndex) lastMsgIndex = idx;
    }
    if (!_conversationIdCompleter.isCompleted) {
      final ids = extractStreamIds(buffer);
      if (ids.conversations.isNotEmpty) {
        _conversationIdCompleter.complete(ids.conversations.first);
      }
    }
  }
}
