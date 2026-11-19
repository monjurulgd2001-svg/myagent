/// v92 — Task-mode video BACKEND: generate a video through Gemini's
/// Task (Spark) agent WITHOUT opening the browser.
///
/// Wire protocol, reverse-engineered from the user's own Task-mode
/// HARs (Nov 2026, two captures — one mid-session, one from page
/// load):
///  1. chooseServer (signaler-pa) -> gsessionid. The API key (AIza…)
///     is read from the Gemini UI's JS bundle (v94 — the page HTML
///     holds only Firebase/web-client keys, which all 403 here) and
///     the X-Server-Token (page key "PI9WOb") from the page HTML at
///     session fetch, exactly like SNlM0e — never hardcoded.
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
  final conv = RegExp(r'c_[0-9a-f]{16}')
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toSet();
  final resp = RegExp(r'r_[0-9a-f]{16}')
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toSet();
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
  final unescaped = body
      .replaceAll(r'\u003d', '=')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\');
  final m = RegExp(
          r'https://contribution\.usercontent\.google\.com/download\?c=[^"\\\s,]+')
      .firstMatch(unescaped);
  return m?.group(0);
}

/// Extract every AIza API key from the Gemini page HTML (the signaler
/// key is one of them; the client tries each for chooseServer).
List<String> extractApiKeys(String html) {
  final seen = <String>{};
  for (final m in RegExp(r'AIza[0-9A-Za-z_\-]{35}').allMatches(html)) {
    seen.add(m.group(0)!);
    if (seen.length >= 20) break;
  }
  return seen.toList();
}

/// v94 — the signaler key is NOT in the page HTML. The page's 8
/// document keys are Firebase/web-client keys; the channel key lives
/// in the Gemini web UI's own JS bundle
/// (gemini.gstatic.com/_/mss/boq-gemini-web-uiserver/_/js/…) — the
/// HAR proved it: the bundle's 5 keys include the one the page sends
/// as X-Goog-Api-Key on its channel calls, and the document keys
/// (zero overlap with the bundle keys) all fail chooseServer with
/// 403. So the app fetches the bundle once per UI version and reads
/// its keys; the document keys stay as fallback.
String? extractBundleUrl(String html) {
  final m = RegExp(
          r'https://gemini\.gstatic\.com/_/mss/boq-gemini-web-uiserver/_/js/[^"'
          r"'\s<>]+")
      .firstMatch(html);
  if (m == null) return null;
  return m.group(0)!.replaceAll('&amp;', '&');
}

/// Bundle keys first (the page's own UI keys — the signaler key is
/// one of them), then the document keys, deduped, capped at 20.
List<String> mergeApiKeys({
  required List<String> bundleKeys,
  required List<String> docKeys,
}) {
  final seen = <String>[];
  for (final k in [...bundleKeys, ...docKeys]) {
    if (k.isEmpty) continue;
    if (!seen.contains(k)) seen.add(k);
    if (seen.length >= 20) break;
  }
  return seen;
}

// ---------------------------------------------------------------------
// The client: channel + task + poll + download.
// ---------------------------------------------------------------------

class TaskBackendClient {
  TaskBackendClient({
    required http.Client client,
    required this.session,
    this.pollInterval = const Duration(seconds: 30),
    this.submitTimeout = const Duration(seconds: 90),
    this.apiKeysOverride,
  }) : _client = client;

  final http.Client _client;
  final GeminiSession session;

  /// v94 — the key list to try for chooseServer. When the caller
  /// (StudioEngine) has already fetched the UI bundle keys, it passes
  /// the merged bundle-first list here; otherwise the session's
  /// document keys are used (v92 behaviour).
  final List<String>? apiKeysOverride;

  /// How often to poll hNvQHb for the finished video URL.
  final Duration pollInterval;

  /// How long to wait for the channel + conversation id before
  /// giving up (the engine then falls back to the browser driver).
  final Duration submitTimeout;

  static const _signalerHost = 'signaler-pa.clients6.google.com';
  static const _channelHost = 'geminiweb-pa.clients6.google.com';
  static const _origin = 'https://gemini.google.com';

  String? _sapisid;
  String get _cookieHeader => session.cookieHeader;

  /// Closes the underlying HTTP client. Only call when this client
  /// owns it (StudioEngine closes the one it created; an injected
  /// test client stays open).
  void close() => _client.close();

  Map<String, String> _jsonHeaders() => {
        'Content-Type': 'application/json+protobuf',
        'Accept': '*/*',
        'User-Agent': _ua,
        'Origin': _origin,
        'Referer': '$_origin/',
        'X-Goog-AuthUser': '${session.authUser}',
        if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
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
    onPhase('opening', 'Backend-e jukto hocche…');
    final gsessionid = await _chooseServer();
    final sid = await _openChannel(gsessionid);
    // The stream carries the conversation id; keep it running in the
    // background while the main flow submits + polls.
    final stream = _ChannelStream(_client, sid, gsessionid, _cookieHeader);
    unawaited(stream.run(deadline));
    try {
      final conversationId = await stream.conversationId
          .timeout(submitTimeout, onTimeout: () => throw const TaskBackendException(
              'channel',
              'Conversation id asheni — channel khuleche kintu Gemini '
              'kono task thread banayni.'));
      onPhase('opening', 'Task pathacche…');
      await _sendSetup(sid, gsessionid, stream);
      await _sendTask(sid, gsessionid, stream, taskText);
      onPhase('creating', 'Backend-e video banacche…');
      final url = await _pollForVideo(conversationId, onPhase, deadline);
      onPhase('downloading', 'MP4 download hocche…');
      return await _download(url);
    } finally {
      stream.stop();
    }
  }

  /// The API key that worked for chooseServer (the channel open must
  /// use the same one). Empty when chooseServer worked without a key.
  String _workingApiKey = '';

  Future<String> _chooseServer() async {
    final keys = [...(apiKeysOverride ?? session.apiKeys), ''];
    Exception? lastErr;
    for (final key in keys) {
      try {
        final uri = Uri.https(
          _signalerHost,
          '/punctual/v1/chooseServer',
          {if (key.isNotEmpty) 'key': key},
        );
        final res = await _client
            .post(uri,
                headers: _jsonHeaders(), body: buildChooseServerBody())
            // v94: a wrong key fails fast with 403 — 25s is plenty,
            // and it keeps a 14-key list from burning 14 minutes.
            .timeout(const Duration(seconds: 25));
        if (res.statusCode != 200) {
          throw TaskBackendException('chooseServer',
              'HTTP ${res.statusCode} (key ${key.isEmpty ? 'chara' : 'diye'})');
        }
        final gs = parseChooseServer(res.body);
        if (gs != null) {
          _workingApiKey = key;
          return gs;
        }
        throw const TaskBackendException(
            'chooseServer', 'gsessionid pelam na.');
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
      }
    }
    throw TaskBackendException(
        'chooseServer', 'Server pick kora jayni: ${lastErr ?? 'unknown'}');
  }

  String _httpHeadersValue() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // sapisidHash already returns "<ts>_<digest>"; the three
    // SAPISID*HASH values are identical in the HAR (same cookie).
    final auth = sapisidHash(_sapisid!, _origin, ts);
    final parts = <String>[
      'Authorization: SAPISIDHASH $auth '
          'SAPISID1PHASH $auth SAPISID3PHASH $auth',
      'X-Goog-AuthUser:${session.authUser}',
      if (_workingApiKey.isNotEmpty)
        'X-Goog-Api-Key:$_workingApiKey',
      if (session.serverToken.isNotEmpty)
        'X-Server-Token:${session.serverToken}',
      'X-WebChannel-Content-Type:application/x-protobuf',
    ];
    return parts.join('\r\n');
  }

  Future<String> _openChannel(String gsessionid) async {
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
    final res = await _client
        .post(uri, headers: _formHeaders(), body: 'count=0')
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw TaskBackendException(
          'channel', 'Channel khola jayni: HTTP ${res.statusCode}.');
    }
    final sid = parseChannelOpen(res.body);
    if (sid == null) {
      throw const TaskBackendException(
          'channel', 'Channel khullo kintu session id pelam na.');
    }
    return sid;
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

  Future<void> _sendSetup(
      String sid, String gsessionid, _ChannelStream stream) async {
    final uuid = _uuid();
    final body =
        'count=1&ofs=0&req0___data__=${_b64Url(buildSetupMessage(uuid))}';
    final res = await _client
        .post(_messageUri(sid, gsessionid, stream),
            headers: _formHeaders(), body: body)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw TaskBackendException(
          'setup', 'Session setup pathano jayni: HTTP ${res.statusCode}.');
    }
  }

  Future<void> _sendTask(String sid, String gsessionid,
      _ChannelStream stream, String taskText) async {
    final body =
        'count=1&ofs=1&req0___data__=${_b64Url(buildTaskMessage(taskText))}';
    final res = await _client
        .post(_messageUri(sid, gsessionid, stream),
            headers: _formHeaders(), body: body)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw TaskBackendException(
          'task', 'Task pathano jayni: HTTP ${res.statusCode}.');
    }
  }

  Future<String> _pollForVideo(String conversationId,
      void Function(String phase, String message) onPhase,
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
        final res = await _client
            .post(uri,
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
                body: {'f.req': freReq, 'at': session.at})
            .timeout(const Duration(seconds: 60));
        if (res.statusCode == 200) {
          final url = extractVideoDownloadUrl(res.body);
          if (url != null) return url;
        }
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

  Future<Uint8List> _download(String url) async {
    final res = await _client.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Referer': '$_origin/',
      if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
    }).timeout(const Duration(minutes: 10));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw TaskBackendException('download',
          'MP4 download hoyni: HTTP ${res.statusCode}. Browser theke '
          'download korte hobe (OSID cookie lagte pare).');
    }
    return res.bodyBytes;
  }
}

/// The processSession long-poll: reads the chunked stream
/// (`<len>\n[[n,["<base64>"]]]\n`) and exposes the conversation id
/// as soon as it arrives. Re-opens the GET with AID=<last index>
/// when the server closes it, until [deadline].
class _ChannelStream {
  _ChannelStream(
      this._client, this._sid, this._gsessionid, this._cookieHeader)
      : rid = 1000 + Random.secure().nextInt(90000);

  final http.Client _client;
  final String _sid;
  final String _gsessionid;
  final String _cookieHeader;

  int rid;
  int lastMsgIndex = 0;
  bool _stopped = false;

  final _conversationIdCompleter = Completer<String>();
  Future<String> get conversationId => _conversationIdCompleter.future;

  void stop() {
    _stopped = true;
  }

  void nextRid() {
    rid++;
  }

  Future<void> run(DateTime deadline) async {
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      try {
        await _onePoll(deadline);
      } catch (_) {
        if (_stopped) return;
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_conversationIdCompleter.isCompleted) {
        // Keep the stream alive in the background so a server-side
        // rejection still surfaces as a closed stream; the poll loop
        // is the completion detector, not this reader.
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<void> _onePoll(DateTime deadline) async {
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
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent': TaskBackendClient._ua,
        'Origin': TaskBackendClient._origin,
        'Referer': '${TaskBackendClient._origin}/',
        if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
      });
    final streamed = await _client.send(req).timeout(
        const Duration(seconds: 65));
    final buffer = <int>[];
    // A long-poll the server holds open: close the stream after 65s
    // of silence so the loop re-opens it (AID=<last index>) instead
    // of hanging past the deadline.
    final timed = streamed.stream.timeout(
        const Duration(seconds: 65), onTimeout: (sink) => sink.close());
    await for (final chunk in timed) {
      if (_stopped) return;
      buffer.addAll(chunk);
      _scanBuffer(buffer);
      if (DateTime.now().isAfter(deadline)) return;
    }
    _scanBuffer(buffer, finalPass: true);
  }

  void _scanBuffer(List<int> buffer, {bool finalPass = false}) {
    // Chunks are "<decimal len>\n<payload>\n". Parse every complete
    // chunk; leave a trailing partial chunk in the buffer.
    var i = 0;
    while (i < buffer.length) {
      var j = i;
      while (j < buffer.length && buffer[j] != 0x0A) {
        j++;
      }
      if (j >= buffer.length) break;
      final lenText =
          String.fromCharCodes(buffer.sublist(i, j)).trim();
      final len = int.tryParse(lenText);
      if (len == null) break;
      if (j + 1 + len > buffer.length && !finalPass) break;
      final end = (j + 1 + len).clamp(0, buffer.length);
      _handleChunk(buffer.sublist(j + 1, end));
      i = (end + 1).clamp(0, buffer.length);
    }
    if (i > 0) buffer.removeRange(0, i);
  }

  void _handleChunk(List<int> payload) {
    try {
      final text = utf8.decode(payload);
      final m = RegExp(r'\[\[(\d+),\["([^"]*)"\]\]').firstMatch(text);
      if (m == null) return;
      final idx = int.tryParse(m.group(1)!) ?? 0;
      if (idx > lastMsgIndex) lastMsgIndex = idx;
      // Channel payloads are unpadded base64url; pad before decoding.
      var b64 = m.group(2)!.replaceAll('-', '+').replaceAll('_', '/');
      b64 += '=' * ((4 - b64.length % 4) % 4);
      final raw = base64Decode(b64);
      final ids = extractStreamIds(raw);
      if (!_conversationIdCompleter.isCompleted &&
          ids.conversations.isNotEmpty) {
        _conversationIdCompleter.complete(ids.conversations.first);
      }
    } catch (_) {
      // A malformed chunk never kills the stream.
    }
  }
}
