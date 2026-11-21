// Gemini Web session API — ported 1:1 from the extension's background.js
// (which itself was ported from the original lib/gemini_api.dart).
//
// HOW LOGIN WORKS IN THIS APP (read this before changing anything):
// The extension rode on Chrome's cookie jar: the user was signed into
// Google in the browser, and fetch(..., credentials:'include') sent the
// cookies. A standalone app has no browser jar, so this app keeps its
// OWN cookie jar per Gemini account (u/0..u/5):
//   1. The login screen (login_screen.dart) opens Google's sign-in
//      page in the app's own browser — the built-in Firefox engine
//      (GeckoView) on Android, the app's own Chrome / Edge window on
//      Windows. The user signs in with Google *inside Google's own
//      page* — the app never sees the password.
//   2. On success the browser hands the session cookies to the app,
//      which stores them in SessionStore (per account slot).
//   3. Every request below sends those cookies in the Cookie header and
//      replays the page's SNlM0e ("at") token, exactly like the extension.
//   4. Fallback: if a browser sign-in is blocked on a device, the user
//      can paste __Secure-1PSID / __Secure-1PSIDTS (or a cookies.txt)
//      in the login screen — same jar, same code path afterwards.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'gecko_signin.dart';
import 'models.dart';
import 'session_store.dart';
import 'studio_constants.dart';
import 'task_backend.dart';

class GeminiAttachment {
  final String uploadPath;
  final String mimeType;
  final String filename;
  final String? processFileUuid;
  final int authUser;
  final Uint8List sourceBytes;
  const GeminiAttachment({
    required this.uploadPath,
    required this.mimeType,
    required this.filename,
    this.processFileUuid,
    required this.authUser,
    required this.sourceBytes,
  });
}

class StreamGenerateResult {
  final List<String> urls;
  final String assistantText;

  /// Server error code from the stream envelope
  /// (`entry[5][2][0][1][0]`), when Gemini answered with an error
  /// instead of content: 1037 usage limit, 1050 model mismatch,
  /// 1052 request format invalid, 1060 IP temporarily blocked,
  /// 1013 temporary error.
  final int? errorCode;
  const StreamGenerateResult(this.urls, this.assistantText,
      {this.errorCode});
}

class HdFetchResult {
  final Uint8List bytes;
  final String mimeType;
  final String ext;
  final String finalHdUrl;
  const HdFetchResult(this.bytes, this.mimeType, this.ext, this.finalHdUrl);
}

class GeminiApi {
  GeminiApi({StatusSink? onStatus, http.Client? client, Duration? rpcTimeout})
      : onStatus = onStatus ?? ((_) {}),
        _client = client ?? http.Client(),
        _rpcTimeout = rpcTimeout ?? const Duration(minutes: 3);

  final StatusSink onStatus;
  final http.Client _client;

  /// v75: default timeout for the Gemini RPC. Normal server time
  /// is 20-60 s; 3 min leaves room for his slow net while a
  /// frozen network still fails loudly instead of hanging forever.
  final Duration _rpcTimeout;

  /// v75: every network await goes through here with a timeout.
  /// Without one, a frozen network (Doze / HiOS killing the radio
  /// when the screen locks) hung the await FOREVER — the
  /// foreground notification stayed up saying "generating" while
  /// nothing moved, and no retry ever fired because no error was
  /// thrown. Now the await fails loudly and the existing retries
  /// (and the UI error) actually run.
  Future<http.Response> _post(Uri url,
      {required Map<String, String> headers,
      required Object? body,
      Duration? timeout}) {
    final t = timeout ?? _rpcTimeout;
    return _client.post(url, headers: headers, body: body).timeout(t,
        onTimeout: () => throw TimeoutException(
            'Network request timed out after ${t.inMinutes} min — network thamte pare. Phone lock hole generation thamle battery setting / Phone Master check koro.'));
  }

  Future<http.Response> _get(Uri url,
      {required Map<String, String> headers, Duration? timeout}) {
    final t = timeout ?? const Duration(seconds: 60);
    return _client.get(url, headers: headers).timeout(t,
        onTimeout: () => throw TimeoutException(
            'Network request timed out after ${t.inSeconds} sec — network thamte pare. Phone lock hole generation thamle battery setting / Phone Master check koro.'));
  }
  // v123 — the cache is SHARED (static) across every GeminiApi
  // instance. The sign-in screen, the silent renewal and the
  // generation engine each build their own GeminiApi(); with a
  // per-instance cache a session proven in the browser (sign-in /
  // renewal) was invisible to the engine, so generation always
  // re-fetched over Dart HTTP — the exact fetch Google bot-checks.
  // Now one browser sign-in feeds every later getSession() call.
  static final Map<int, GeminiSession> _sessionCache = {};
  static bool _ignorePersistedForTest = false;

  @visibleForTesting
  static void clearSessionCacheForTest() {
    _sessionCache.clear();
    _ignorePersistedForTest = true;
  }
  int activeAuthUserIndex = 0;

  static const String uploadInitUrl =
      'https://push.clients6.google.com/upload/';
  static const String pushId = 'feeds/mcudyrk2a4khkz';
  static const String clientPctx = 'CgcSBWjK7pYx';
  static const String tenantId = 'bard-storage';
  static const String defaultBl = 'boq_gemini-web-uiserver_20261106.06_p0';

  /// Desktop Chrome UA — also used by the login WebView so the session
  /// the user creates matches what these requests look like.
  static const String chromeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// Android Chrome (mobile) UA — used by the Image Search browser in
  /// Mobile mode so Google Images and Pinterest serve their responsive
  /// mobile layouts, which are far easier to browse on a phone screen.
  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

  void _status(String state, int step, String message) =>
      onStatus(StatusEvent(state, step, message));

  Map<String, String> _pageHeaders(String cookieHeader) => {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': chromeUserAgent,
        'Origin': 'https://gemini.google.com',
        'Referer': 'https://gemini.google.com/',
        // v121 — the fallback /app fetch should look like the
        // browser's own navigation: a bare Dart fetch (no
        // Sec-Fetch-*, no Accept-Language) is what Google
        // bot-checked live 2026-11-21. The primary path no longer
        // fetches at all (in-browser session read); this only
        // hardens Test / paste / refresh fallbacks.
        'Accept-Language': 'en-US,en;q=0.9',
        'Upgrade-Insecure-Requests': '1',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-User': '?1',
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      };

  Map<String, String> _rpcHeaders(String cookieHeader,
          {String? genUuid}) =>
      {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
        'X-Same-Domain': '1',
        'User-Agent': chromeUserAgent,
        'Origin': 'https://gemini.google.com',
        'Referer': 'https://gemini.google.com/',
        if (genUuid != null) 'x-goog-ext-525005358-jspb': '["$genUuid",1]',
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      };

  String _newUuid() {
    final r = Random.secure();
    String hex(int n) => List.generate(
            n, (_) => r.nextInt(16).toRadixString(16))
        .join()
        .toUpperCase();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + r.nextInt(4)).toRadixString(16).toUpperCase()}${hex(3)}-'
        '${hex(12)}';
  }

  /// The StreamGenerate request frame the CURRENT Gemini web
  /// client sends (verified against the maintained gemini-webapi
  /// client, November 2026): an 81-slot array — [0] message
  /// content, [1] language, [2] conversation metadata, [6] [1],
  /// [7] streaming flag, [10] 1, [17] [[0]], [27] 1, [30] [4],
  /// [41] [1], [59] the request uuid (mirrored in the
  /// x-goog-ext-525005358-jspb header), [61] [], [68] 1, [79] 1,
  /// [80] 1. The extension-era 12-slot frame is rejected by
  /// today's server, which is why image generation failed while
  /// sign-in (page fetch) still worked.
  ({List<dynamic> inner, String uuid}) _buildGenerateRequest(
      List<dynamic> messageContent) {
    final uuid = _newUuid();
    return (inner: buildGenerateFrame(messageContent, uuid), uuid: uuid);
  }

  /// The 81-slot frame of [_buildGenerateRequest] (static so the
  /// wire format itself is unit-tested).
  static List<dynamic> buildGenerateFrame(
      List<dynamic> messageContent, String uuid) {
    final inner = List<dynamic>.filled(81, null);
    inner[0] = messageContent;
    inner[1] = ['en'];
    inner[2] = ['', '', '', null, null, null, null, null, null, ''];
    inner[6] = [1];
    inner[7] = 1;
    inner[10] = 1;
    inner[11] = 0;
    inner[17] = [[0]];
    inner[18] = 0;
    inner[27] = 1;
    inner[30] = [4];
    inner[41] = [1];
    inner[53] = 0;
    inner[59] = uuid;
    inner[61] = <dynamic>[];
    inner[68] = 1;
    inner[79] = 1;
    inner[80] = 1;
    return inner;
  }

  /// StreamGenerate lives on the ROOT BardChatUi path in the
  /// current web client (the /u/<n>/ prefix belonged to the
  /// browser's shared cookie jar; this app's jar is already
  /// per-account, so the cookies pick the account).
  Uri _generateUri(GeminiSession s) {
    final params = <String, String>{
      'bl': s.bl,
      'hl': 'en',
      '_reqid': (100000 + Random().nextInt(900000)).toString(),
      'rt': 'c',
      if (s.fSid.isNotEmpty) 'f.sid': s.fSid,
    };
    return Uri.parse(
            'https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate')
        .replace(queryParameters: params);
  }

  // ---------------------------------------------------------------------
  // Session handling (extension: getGeminiSession / scanAvailableGeminiAccounts)
  // ---------------------------------------------------------------------

  Future<int> resolveTargetAuthUser({int? explicit}) async {
    if (explicit != null) {
      activeAuthUserIndex = explicit;
      return explicit;
    }
    final mode = await SessionStore.loadAccountMode();
    if (mode != 'auto') {
      final parsed = int.tryParse(mode);
      if (parsed != null && parsed >= 0) {
        activeAuthUserIndex = parsed;
        return parsed;
      }
    }
    return activeAuthUserIndex;
  }

  static String extractEmailFromHtml(String html) {
    final wiz = RegExp(r'"oPEP7c":"([^"]+@[^"]+)"').firstMatch(html);
    if (wiz != null) return wiz.group(1)!.trim();
    final generic = RegExp(
            r'([a-zA-Z0-9._%+-]+@(?:gmail\.com|googlemail\.com))',
            caseSensitive: false)
        .firstMatch(html);
    if (generic != null) return generic.group(1)!.trim().toLowerCase();
    return '';
  }

  /// v122 — true when a failure only means the CHECK was
  /// blocked (Google bot-checked the raw /app fetch), not that
  /// the session is dead. Refresh and Test must say "could not
  /// verify right now" for this case — never "not connected" —
  /// because the saved login is untouched and may be fine.
  static bool isBotBlocked(Object e) =>
      e.toString().contains('bot check');

  /// v118 — says WHAT the /app page actually was when it carries no
  /// SNlM0e, instead of the bare "token not found". The login page,
  /// a consent page, a bot check, and a stale/mixed jar all fail the
  /// same way in the old message; the fix for each is different, so
  /// the message has to name the one that happened. Only page
  /// markers and the signed-in email (never any cookie) are read.
  static String diagnoseSessionPage(String html) {
    final lower = html.toLowerCase();
    if (lower.contains('consent.google.com') ||
        lower.contains('before you continue')) {
      return 'Google showed a consent page instead of Gemini — the '
          'request was not treated as signed in. Sign in again in '
          'the built-in browser.';
    }
    if (lower.contains('unusual traffic') ||
        lower.contains('recaptcha') ||
        lower.contains('our systems have detected')) {
      return 'Google showed a bot check instead of Gemini — the '
          'request was blocked. Try again later, or sign in again in '
          'the built-in browser.';
    }
    if (lower.contains('accounts.google.com') &&
        (lower.contains('sign in') || lower.contains('signin'))) {
      return 'Google returned its sign-in page — the saved cookies '
          'are dead (signed out). Remove them and sign in again.';
    }
    final email = extractEmailFromHtml(html);
    if (email.isNotEmpty) {
      return 'The page IS signed in as $email but carries no session '
          'token — the cookies are stale or mixed from another '
          'session. Remove the saved cookies for this slot, sign in '
          'again with the right account, and try once more.';
    }
    final tokenMentioned = html.contains('SNlM0e');
    return 'The page came back (${html.length} chars)'
        '${tokenMentioned ? ' and mentions SNlM0e but not as a session token' : ' with no session token at all'}'
        ' — the login did not survive. Remove the saved cookies and '
        'sign in again.';
  }

  /// Cookie auto-renewal: Google rotates __Secure-1PSIDTS via
  /// Set-Cookie on its responses. A browser jar absorbs that silently;
  /// this app's jar does it here — the rotated cookies are merged into
  /// the stored jar for [authUser] and the up-to-date header returned.
  /// Without this, a saved login would die the day the originally
  /// captured 1PSIDTS expires; with it, the login stays saved and
  /// keeps renewing itself while the app is used.
  Future<String> _absorbRotatedCookies(
      int authUser, http.Response response, String currentHeader) async {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return currentHeader;
    final updated = SessionStore.absorbSetCookies(currentHeader, setCookie);
    if (updated != currentHeader) {
      await SessionStore.saveCookieForUser(authUser, updated);
    }
    return updated;
  }

  /// Fetches /u/<n>/app with the stored cookie jar and extracts the
  /// SNlM0e session token. This IS the login check: no token = not
  /// signed in (or the cookie expired).
  ///
  /// v118 — [verifyHeader]: verify this header WITHOUT saving it
  /// first. Sign-in / Test / Refresh prove a fresh jar with it and
  /// only then store it, so a bad harvest can no longer overwrite a
  /// working saved login. Rotation absorption is skipped on that
  /// path (the store is not touched until the jar proves good).
  Future<GeminiSession> getSession(
      {bool forceRefresh = false,
      int? explicitAuthUser,
      String? verifyHeader}) async {
    final authUser = await resolveTargetAuthUser(explicit: explicitAuthUser);
    var cookieHeader =
        verifyHeader ?? await SessionStore.cookieForUser(authUser) ?? '';
    var cached = _sessionCache[authUser];
    // v125 — hydrate last proven session from disk across app restarts
    // so image & animation generation keep working without hitting
    // Google's bot-checked Dart /app fetch.
    if (cached == null &&
        verifyHeader == null &&
        !_ignorePersistedForTest &&
        cookieHeader.isNotEmpty) {
      final persisted = await SessionStore.loadSessionSnapshot(authUser);
      if (persisted != null && persisted.at.isNotEmpty) {
        cached = GeminiSession(
          authUser: persisted.authUser,
          email: persisted.email,
          at: persisted.at,
          bl: persisted.bl.isEmpty ? defaultBl : persisted.bl,
          fSid: persisted.fSid,
          cookieHeader: cookieHeader,
          fetchedAtMs: persisted.fetchedAtMs,
          apiKeys: persisted.apiKeys,
          serverToken: persisted.serverToken,
        );
        _sessionCache[authUser] = cached;
      }
    }
    if (!forceRefresh &&
        cached != null &&
        cached.at.isNotEmpty &&
        cached.isFresh) {
      return cached;
    }

    if (cookieHeader.isEmpty) {
      throw Exception(
          'No Gemini login found for Account u/$authUser. Open the Gemini Login tab and sign in first.');
    }

    // v125 — on Android, try the built-in Firefox browser FIRST so
    // image & animation generation refresh SNlM0e + apiKeys +
    // serverToken without hitting Google's Dart HTTP bot-check.
    if (verifyHeader == null && GeckoSignIn.supported) {
      try {
        _status('authenticating', 1,
            'Refreshing Gemini session in built-in browser (Account u/$authUser)...');
        final refreshed =
            await GeckoSignIn.refreshSessionPage(cookieHeader: cookieHeader);
        if (refreshed != null &&
            (refreshed.page.authUser == null ||
                refreshed.page.authUser == authUser)) {
          final browserSession = sessionFromPageFields(
            authUser: authUser,
            cookieHeader: refreshed.header,
            at: refreshed.page.at,
            bl: refreshed.page.bl,
            fSid: refreshed.page.fSid,
            email: refreshed.page.email,
            serverToken: refreshed.page.serverToken,
            apiKeys: refreshed.page.apiKeys,
          );
          await SessionStore.saveCookieForUser(authUser, refreshed.header);
          await adoptSession(browserSession);
          return browserSession;
        }
      } catch (_) {
        // Browser path missed — fall through to Dart HTTP or cached
        // session fallback below.
      }
    }

    // v123 — a blocked fresh check must not kill a generation when
    // the app already holds a good session. The token stays valid
    // for days while the Google session is alive; only the CHECK
    // is blocked (bot check / dead network / slow page). So an
    // ordinary generation-time fetch (never a verify: forceRefresh
    // and verifyHeader calls are excluded) falls back to the last
    // good cached session instead of throwing. If that token is
    // truly dead, the RPC itself fails and the user re-signs in —
    // which works through the browser — instead of failing here on
    // a check Google blocked.
    try {
      _status('authenticating', 1,
          'Connecting to Gemini Account u/$authUser (fetching SNlM0e token)...');

      final appUri = Uri.parse(
          'https://gemini.google.com/u/$authUser/app?authuser=$authUser');
      final response =
          await _get(appUri, headers: _pageHeaders(cookieHeader));
      if (response.statusCode != 200) {
        throw Exception(
            'Failed to reach gemini.google.com/u/$authUser/app (HTTP ${response.statusCode}). Make sure you are signed into Google.');
      }
      // Renew the jar with any rotated cookies before building the
      // session, so the session (and all later RPCs) use the freshest
      // cookies and the saved login keeps itself alive. Skipped on a
      // verify-only call (v118): the store is untouched until the jar
      // proves good.
      if (verifyHeader == null) {
        cookieHeader =
            await _absorbRotatedCookies(authUser, response, cookieHeader);
      }

      final html = response.body;
      final session = _parseSessionHtml(html, authUser, cookieHeader);
      if (session == null) {
        throw Exception(
            'Could not find Gemini session token (SNlM0e) for Account u/$authUser. ${diagnoseSessionPage(html)}');
      }
      _sessionCache[authUser] = session;
      if (verifyHeader == null) {
        _ignorePersistedForTest = false;
        await SessionStore.saveSessionSnapshot(session);
      }
      await SessionStore.saveActiveInfo(session);
      return session;
    } catch (e) {
      if (!forceRefresh &&
          verifyHeader == null &&
          cached != null &&
          cached.at.isNotEmpty) {
        _status('authenticating', 1,
            'Fresh session check was blocked — using the last good session for Account u/$authUser.');
        return cached;
      }
      rethrow;
    }
  }

  GeminiSession? _parseSessionHtml(
      String html, int authUser, String cookieHeader) {
    final at = RegExp(r'"SNlM0e":"([^"]+)"').firstMatch(html)?.group(1);
    if (at == null || at.isEmpty) return null;
    final bl =
        RegExp(r'"cfb2h":"([^"]+)"').firstMatch(html)?.group(1) ?? defaultBl;
    final fSid = RegExp(r'"FdrFJe":"([^"]+)"').firstMatch(html)?.group(1) ?? '';
    final email = extractEmailFromHtml(html);
    // v92 — Task backend: the signaler API key (one of the AIza keys
    // in the page) and the X-Server-Token (page key "PI9WOb") are
    // read from the same HTML, exactly like SNlM0e — never hardcoded.
    final serverToken =
        RegExp(r'"PI9WOb":"([^"]+)"').firstMatch(html)?.group(1) ?? '';
    return GeminiSession(
      authUser: authUser,
      email: email.isEmpty ? 'Account u/$authUser' : email,
      at: at,
      bl: bl,
      fSid: fSid,
      cookieHeader: cookieHeader,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      apiKeys: extractApiKeys(html),
      serverToken: serverToken,
    );
  }

  /// v121 — builds the session from the fields the built-in
  /// browser read off its own loaded /app page (see
  /// GeckoSignIn.sessionPageFromResult). Same field set as
  /// _parseSessionHtml, minus the HTTP fetch — the page was
  /// already loaded by a real browser, so Google never gets a
  /// chance to bot-check it.
  static GeminiSession sessionFromPageFields({
    required int authUser,
    required String cookieHeader,
    required String at,
    String bl = '',
    String fSid = '',
    String email = '',
    String serverToken = '',
    List<String> apiKeys = const [],
  }) {
    return GeminiSession(
      authUser: authUser,
      email: email.isEmpty ? 'Account u/$authUser' : email,
      at: at,
      bl: bl.isEmpty ? defaultBl : bl,
      fSid: fSid,
      cookieHeader: cookieHeader,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      apiKeys: apiKeys,
      serverToken: serverToken,
    );
  }

  /// v121 — adopts a session proven outside getSession (the
  /// in-browser read): caches it and records it as the active
  /// session, exactly like a fetched one.
  Future<void> adoptSession(GeminiSession session) async {
    _ignorePersistedForTest = false;
    _sessionCache[session.authUser] = session;
    await SessionStore.saveSessionSnapshot(session);
    await SessionStore.saveActiveInfo(session);
  }

  /// Probes /u/0../u/5 in parallel and returns every distinct signed-in
  /// account found in the stored cookie jars.
  Future<List<GeminiAccount>> scanAccounts() async {
    final cookiesByUser = await SessionStore.loadCookiesByUser();
    final futures = List.generate(6, (u) async {
      final cookieHeader = cookiesByUser[u] ?? '';
      if (cookieHeader.isEmpty) return null;
      try {
        final uri = Uri.parse('https://gemini.google.com/u/$u/app?authuser=$u');
        final resp =
            await _get(uri, headers: _pageHeaders(cookieHeader));
        if (resp.statusCode != 200) return null;
        final freshHeader =
            await _absorbRotatedCookies(u, resp, cookieHeader);
        final session = _parseSessionHtml(resp.body, u, freshHeader);
        if (session == null) return null;
        _sessionCache[u] = session;
        return GeminiAccount(authUser: u, email: session.email, bl: session.bl);
      } catch (_) {
        return null;
      }
    });
    final raw =
        (await Future.wait(futures)).whereType<GeminiAccount>().toList();
    final seen = <String>{};
    final unique = <GeminiAccount>[];
    for (final acc in raw) {
      final key = acc.email.contains('@')
          ? acc.email.toLowerCase()
          : 'u/${acc.authUser}';
      if (seen.add(key)) unique.add(acc);
    }
    await SessionStore.saveDiscoveredAccounts(unique);
    return unique;
  }

  static bool isQuotaOrLimitFailure(int status, String assistantText) {
    if (status == 429 || status == 503) return true;
    final t = assistantText.toLowerCase();
    if (t.isEmpty) return false;
    const keywords = [
      'reached your limit',
      'rate limit',
      'quota',
      'too many requests',
      'try again later',
      'can not generate more',
      'cannot generate more',
      'limit for generating images',
      'create more images tomorrow',
      'high demand',
    ];
    return keywords.any(t.contains);
  }

  Future<GeminiSession?> trySwitchToNextAccount(int failedAuthUser) async {
    var accounts = await SessionStore.loadDiscoveredAccounts();
    if (accounts.length <= 1) {
      accounts = await scanAccounts();
    }
    final others = accounts.where((a) => a.authUser != failedAuthUser).toList();
    if (others.isEmpty) return null;
    final idx = accounts.indexWhere((a) => a.authUser == failedAuthUser);
    final next =
        idx >= 0 ? accounts[(idx + 1) % accounts.length] : others.first;
    if (next.authUser == failedAuthUser) return null;
    activeAuthUserIndex = next.authUser;
    final mode = await SessionStore.loadAccountMode();
    if (mode != 'auto') {
      await SessionStore.saveAccountMode(next.authUser.toString());
    }
    final newSession =
        await getSession(forceRefresh: true, explicitAuthUser: next.authUser);
    _status('authenticating', 1,
        'Account u/$failedAuthUser limit/quota reached — auto-switched to u/${newSession.authUser} (${newSession.email})!');
    return newSession;
  }

  // ---------------------------------------------------------------------
  // StreamGenerate RPC (text + image) — extension: parseStreamGenerateResponse
  // ---------------------------------------------------------------------

  void _extractImageUrls(dynamic node, Set<String> out) {
    if (node == null) return;
    if (node is String) {
      final re = RegExp(
          r'https://(?:lh3\.googleusercontent\.com|[a-zA-Z0-9\-]+\.fife\.usercontent\.google\.com)/[a-zA-Z0-9_\-/=%+]+');
      for (final m in re.allMatches(node)) {
        final url = m.group(0)!;
        if (!url.contains('/a/') && !url.contains('/a-/') && url.length > 48) {
          out.add(url);
        }
      }
      final trimmed = node.trim();
      if ((trimmed.startsWith('[') && trimmed.endsWith(']')) ||
          (trimmed.startsWith('{') && trimmed.endsWith('}'))) {
        try {
          _extractImageUrls(jsonDecode(trimmed), out);
        } catch (_) {}
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        _extractImageUrls(item, out);
      }
      return;
    }
    if (node is Map) {
      for (final v in node.values) {
        _extractImageUrls(v, out);
      }
    }
  }

  static int? _nestedInt(dynamic node, List<int> path) {
    dynamic cur = node;
    for (final i in path) {
      if (cur is List && i >= 0 && i < cur.length) {
        cur = cur[i];
      } else {
        return null;
      }
    }
    return cur is num ? cur.toInt() : null;
  }

  StreamGenerateResult parseStreamGenerateResponse(String rawText,
      {List<String> excludeUrls = const []}) {
    final candidateUrls = <String>{};
    final fallbackUrls = <String>{};
    var assistantText = '';
    int? errorCode;

    final excludeBase = excludeUrls
        .map((u) =>
            _urlBaseKey(u.replaceAll(RegExp(r'''["'\\]+$'''), '')))
        .toSet();

    for (final line in rawText.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('[')) continue;
      try {
        final outer = jsonDecode(trimmed);
        _extractImageUrls(outer, fallbackUrls);
        if (outer is List) {
          for (final entry in outer) {
            // Server error envelope: entry[5][2][0][1][0] is the
            // numeric error code (1037 usage limit, 1052 format
            // invalid, 1060 IP blocked, ...).
            errorCode ??= _nestedInt(entry, const [5, 2, 0, 1, 0]);
            if (entry is List &&
                entry.length > 2 &&
                entry[0] == 'wrb.fr' &&
                entry[2] is String) {
              try {
                final inner = jsonDecode(entry[2] as String);
                if (inner is List && inner.length > 4 && inner[4] is List) {
                  _extractImageUrls(inner[4], candidateUrls);
                  final first =
                      (inner[4] as List).isNotEmpty ? inner[4][0] : null;
                  if (first is List &&
                      first.length > 1 &&
                      first[1] is List &&
                      (first[1] as List).isNotEmpty &&
                      first[1][0] is String) {
                    final candidateText = first[1][0] as String;
                    if (candidateText.trim().length >=
                        assistantText.trim().length) {
                      assistantText = candidateText;
                    }
                  }
                }
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }

    final unescaped = rawText
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\/', '/');
    final directRe = RegExp(
        r'https://(?:lh3\.googleusercontent\.com|[a-zA-Z0-9\-]+\.fife\.usercontent\.google\.com)/(?:gg-dl|rd-gg-dl|gg)/[a-zA-Z0-9_\-/=%+]+');
    for (final m in directRe.allMatches(unescaped)) {
      fallbackUrls.add(m.group(0)!);
    }

    final source = candidateUrls.isNotEmpty ? candidateUrls : fallbackUrls;
    final baseMap = <String, String>{};
    for (final url in source) {
      // Keep the URL EXACTLY as Gemini issued it — size suffix AND
      // query string included. The extension-era parser returned the
      // suffix-stripped base key instead, which silently destroyed
      // the one form the CDN had actually signed: every later
      // reconstruction (=s0, =s2048-rj, bare) was refused with
      // HTTP 403 on device (2026-11-09, v19/v20 builds). Dedup and
      // exclusion still key on the stripped base, but the VALUES —
      // the full issued URLs — are what callers now receive.
      final clean = url.replaceAll(RegExp(r'''["'\\]+$'''), '');
      final baseKey = _urlBaseKey(clean);
      if (!excludeBase.contains(baseKey)) baseMap[baseKey] = clean;
    }
    return StreamGenerateResult(baseMap.values.toList(), assistantText,
        errorCode: errorCode);
  }

  /// The dedup/exclusion key of an image URL: query string and
  /// trailing `=size` suffix removed.
  static String _urlBaseKey(String url) => url
      .split('?')
      .first
      .replaceAll(RegExp(r'=[a-zA-Z0-9\-_]+$'), '');

  Uri _rpcUri(GeminiSession s, String rpcName) {
    final params = <String, String>{
      'bl': s.bl,
      'hl': 'en',
      '_reqid': (100000 + Random().nextInt(900000)).toString(),
      'rt': 'c',
      'authuser': '${s.authUser}',
      if (s.fSid.isNotEmpty) 'f.sid': s.fSid,
    };
    return Uri.parse(
            'https://gemini.google.com/u/${s.authUser}/_/BardChatUi/data/assistant.lamda.BardFrontendService/$rpcName')
        .replace(queryParameters: params);
  }

  /// Extension: askGeminiText — pure text completion, fresh chat.
  Future<String> askGeminiText(String promptText,
      {GeminiSession? session, int attempts = 3}) async {
    var active = session ?? await getSession();
    var lastErr = 'Empty response from Gemini';
    for (var i = 0; i < attempts; i++) {
      try {
        final req = _buildGenerateRequest(
            [promptText, 0, null, null, null, null, 0]);
        final body = {
          'f.req': jsonEncode([null, jsonEncode(req.inner)]),
          'at': active.at
        };
        var response = await _post(_generateUri(active),
            headers: _rpcHeaders(active.cookieHeader, genUuid: req.uuid),
            body: body);
        if (response.statusCode == 401 ||
            response.statusCode == 403 ||
            response.statusCode == 400) {
          active = await getSession(
              forceRefresh: true, explicitAuthUser: active.authUser);
          body['at'] = active.at;
          response = await _post(_generateUri(active),
              headers:
                  _rpcHeaders(active.cookieHeader, genUuid: req.uuid),
              body: body);
        }
        await _absorbRotatedCookies(
            active.authUser, response, active.cookieHeader);
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }
        final parsed = parseStreamGenerateResponse(response.body);
        if (parsed.assistantText.trim().isNotEmpty) {
          return parsed.assistantText.trim();
        }
      } catch (e) {
        lastErr = e.toString();
      }
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 1500 * (i + 1)));
      }
    }
    throw Exception('Gemini text completion failed: $lastErr');
  }

  // ---------------------------------------------------------------------
  // Image → Prompt similarity system. The similarity target decides
  // which picture aspects stay the same in the new image and which
  // ones change; the Gemini instruction is built around it.
  // ---------------------------------------------------------------------

  /// The 11 picture aspects the similarity target arbitrates between,
  /// in the order they lock in as similarity rises: the first two stay
  /// the same even for the freshest take; the last ones only stay when
  /// the new image is meant to be a near copy.
  static const List<String> kSimilarityAspects = [
    'Subject type',
    'Style & medium',
    'Subject design',
    'Setting / location',
    'Colour palette',
    'Lighting',
    'Background details',
    'Pose & orientation',
    'Camera & framing',
    'Time & weather',
    'Small props & details',
  ];

  /// Preset chips, freshest to closest: name -> similarity percent.
  static const Map<String, int> kSimilarityPresets = {
    'Fresh 30%': 30,
    'Inspired 45%': 45,
    'Balanced 60%': 60,
    'Close 75%': 75,
    'Near copy 90%': 90,
  };

  static String similarityLabel(int pct) {
    if (pct <= 25) return 'Fresh new picture';
    if (pct <= 37) return 'Fresh';
    if (pct <= 52) return 'Inspired';
    if (pct <= 67) return 'Balanced';
    if (pct <= 82) return 'Close';
    return 'Near copy';
  }

  static int _staysCount(int pct) =>
      (2 + (pct.clamp(20, 90) - 20) * 9 / 70).round();

  static List<String> staysForSimilarity(int pct) =>
      kSimilarityAspects.sublist(0, _staysCount(pct));

  static List<String> changesForSimilarity(int pct) =>
      kSimilarityAspects.sublist(_staysCount(pct));

  /// The full Gemini instruction for image-to-prompt: the senior
  /// prompt-engineer template, with the SIMILARITY TARGET block
  /// (percent + stays/changes lists) filled in for [similarity].
  static String buildImageToPromptInstruction({
    required int similarity,
    String styleNote = '',
    String extraInstruction = '',
  }) {
    final stays = staysForSimilarity(similarity);
    final changes = changesForSimilarity(similarity);
    final b = StringBuffer()
      ..write('You are a senior prompt engineer and art director for '
          'state-of-the-art text-to-image models (Midjourney v7, FLUX, '
          'Imagen 4, GPT-Image, nano-banana). Analyse the attached '
          'reference image with a professional eye, then write ONE '
          'production-ready text-to-image prompt for a new image that '
          'follows the SIMILARITY TARGET given below exactly - it '
          'decides what stays identical and what changes.\n\n')
      ..write('SIMILARITY TARGET: $similarity% '
          '(${similarityLabel(similarity)}). Format: vertical 9:16 '
          'phone wallpaper. STAYS THE SAME: ${stays.join('; ')}. '
          'WILL CHANGE: ${changes.isEmpty ? 'nothing — keep every layer as close to the reference as the rules allow' : changes.join('; ')}.\n\n')
      ..write('Analyse these layers and fold every one of them into '
          'the prompt (as kept or as changed, according to the target):\n'
          '1. Subject - what it is, count, variety / identity, pose, '
          'expression, clothing, colours, materials, distinctive details.\n'
          '2. Setting - environment, foreground and background elements, '
          'time of day, season, weather.\n'
          '3. Composition - shot type, framing, camera angle, subject '
          'placement, depth layers, orientation.\n'
          '4. Camera and lens - focal length feel, depth of field, '
          'bokeh, motion.\n'
          '5. Lighting - key light direction and quality, shadows, '
          'reflections, atmosphere.\n'
          '6. Colour - dominant palette with precise colour names, '
          'contrast, saturation, grading.\n'
          '7. Style and medium - photograph, 3D render, painting, anime, '
          'illustration..., plus the render look.\n'
          '8. Texture and detail - surfaces, materials, grain, sharpness.\n'
          '9. Mood - the emotion in a few precise adjectives.\n\n')
      ..write('Rules: never copy logos, text, watermarks, signatures or '
          'recognisable trademark characters; do not name real people, '
          'brands, copyrighted characters or living artists (describe a '
          'generic look instead); never add text. No "this image shows", '
          'no lists, no line breaks, no hashtags, no commentary. Prefer '
          'concrete, vivid nouns and adjectives. Write one flowing '
          'paragraph of 120-200 words, most important elements first, '
          'ending with quality cues (for example "ultra detailed, sharp '
          'focus, high dynamic range"). Return it exactly in this format:\n'
          '[PROMPT]\n<the prompt>\n[/PROMPT]');
    if (styleNote.trim().isNotEmpty) {
      b.write('\nAlso follow this style note: ${styleNote.trim()}');
    }
    if (extraInstruction.trim().isNotEmpty) {
      b.write('\n${extraInstruction.trim()}');
    }
    return b.toString();
  }

  /// Word-set Jaccard similarity between two prompts (0..1) — used by
  /// the "avoid repeating earlier prompts" check.
  static double promptSimilarity(String a, String b) {
    Set<String> words(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toSet();
    final wa = words(a);
    final wb = words(b);
    if (wa.isEmpty || wb.isEmpty) return 0;
    final union = wa.union(wb).length;
    if (union == 0) return 0;
    return wa.intersection(wb).length / union;
  }

  /// Image → Prompt: upload an image to the signed-in Gemini web
  /// session and ask for a single detailed text-to-image prompt that
  /// describes it (used by the integrated Image Search flow). Same
  /// upload + attachment payload machinery as img2img generation, but
  /// the wanted result is the assistant TEXT, not an image URL.
  /// v48: the instruction behind the designer's "Polish prompt"
  /// button. The user's rough idea goes in; one enriched,
  /// production-ready wallpaper prompt comes out. The concept
  /// itself must survive untouched - polish adds craft, never a
  /// new subject, and never set behaviour (the engine adds stage
  /// directions itself, so time-of-day changes or image counts
  /// would corrupt the set flow).
  /// v50: originality + forbidden-elements rules strengthened on
  /// the user's order - the polished prompt must describe a fresh,
  /// creative, never-common concept with no copyrighted element
  /// and none of the banned in-image artefacts (text, numbers,
  /// %, battery/clock/UI, watermark, signature, logo, blur).
  static String buildPolishInstruction(String prompt) {
    return 'You are a senior prompt engineer for text-to-image models. '
        'Rewrite the wallpaper idea below into ONE polished, production-ready image prompt.\n\n'
        'IDEA: ${prompt.trim()}\n\n'
        'Rules:\n'
        '- Keep the exact same subject and concept. Do not add new subjects, characters or objects that change the scene, and never remove the main subject.\n'
        '- Make it a fully original, new-concept design: reimagine the same subject with creative, unexpected composition, viewpoint, colour palette and lighting. Never a common, generic or copy-like version of the subject, never similar to popular or existing designs, and never a copyrighted element, character, artwork or style copied from anyone.\n'
        '- Enrich it with: specific subject details, the environment/setting, composition suited to a vertical 9:16 phone wallpaper (main subject clear of the top clock area), lighting direction and quality, a named colour palette, art style/medium, surface texture and fine detail, and the mood.\n'
        '- Write ONE flowing paragraph of 60-110 words, most important elements first, ending with quality cues like "ultra detailed, sharp focus, cinematic colour grade".\n'
        '- No text, letters, numbers, percentage signs (%), battery icons, UI widgets, clocks or clock faces, watermarks, signatures, logos or brand marks in the image. No real people, brands or copyrighted characters. No blurry, soft or out-of-focus details - everything tack-sharp and fully detailed.\n'
        '- Do NOT mention multiple images, sets, collections, time-of-day changes or battery levels - the prompt describes a single wallpaper scene.\n'
        '- Output ONLY the polished prompt: no label, no quotes, no explanation, no list.';
  }

  /// v88: the video twin of buildPolishInstruction. The Animation
  /// section's Polish button rewrites a rough animation idea into
  /// ONE polished, production-ready video prompt — same subject,
  /// original concept, no copyrighted element — plus motion and
  /// loop behaviour (a video prompt describes movement, not just
  /// a still). Shorter than the image polish (40-80 words): the
  /// driver sends one prompt and the video tool reads it once.
  static String buildVideoPolishInstruction(String prompt) {
    return 'You are a senior prompt engineer for text-to-video models. '
        'Rewrite the animation idea below into ONE polished, production-ready video prompt.\\n\\n'
        'IDEA: ${prompt.trim()}\\n\\n'
        'Rules:\\n'
        '- Keep the exact same subject and concept. Do not add new subjects, characters or objects that change the scene, and never remove the main subject.\\n'
        '- Make it a fully original, new-concept animation: reimagine the same subject with creative, unexpected composition, viewpoint, colour palette and lighting. Never a common, generic or copy-like version of the subject, never similar to popular or existing videos, and never a copyrighted element, character, artwork or style copied from anyone.\\n'
        '- Enrich it with: specific subject details, the environment/setting, composition suited to a vertical 9:16 phone live wallpaper (main subject centred, clear of the top clock area), lighting direction and quality, a named colour palette, art style/medium, surface texture and fine detail, the mood, and the MOTION itself — how the subject and camera move, and how the loop closes so the end meets the start seamlessly.\\n'
        '- Write ONE flowing paragraph of 40-80 words, most important elements first, ending with quality cues like "ultra detailed, sharp focus, cinematic colour grade, smooth seamless motion".\\n'
        '- No text, letters, numbers, watermarks, signatures, logos or brand marks in the video. No real people, brands or copyrighted characters. No blurry, soft or out-of-focus details - everything tack-sharp and fully detailed.\\n'
        '- Do NOT mention multiple videos, sets or collections - the prompt describes a single live-wallpaper animation.\\n'
        '- Output ONLY the polished prompt: no label, no quotes, no explanation, no list.';
  }

  /// v82: Auto Cinematic Scene — the instruction behind the
  /// automatic scene expansion for 24h/battery sets. The user's
  /// idea (even two words) goes in; one rich cinematic scene
  /// description comes out, and the engine uses it as the base
  /// scene for every stage. The concept itself must survive
  /// untouched — expansion adds craft, never a new subject — and
  /// it must stay NEUTRAL: no time-of-day bias (the 24h stages
  /// add the light) and no charge bias (the battery stages add
  /// the energy), or the anchor would fight the stages.
  static String buildSceneExpansionInstruction(
      String prompt, String workflowMode) {
    final setLine = workflowMode == 'set_battery'
        ? 'It will become a battery-level set (0% to 100% plus charging), so describe a scene with ONE clear glow or energy element whose brightness can rise and fall — but do NOT describe any charge level, brightness amount or charging state yourself.'
        : 'It will become a 24-hour set (morning, midday, evening, night), so describe a scene that reads beautifully in any light — but do NOT describe any time of day, sunrise, sunset or night yourself.';
    return 'You are a senior prompt engineer for text-to-image models. '
        'Expand the wallpaper idea below into ONE rich, cinematic scene description for a premium phone wallpaper.\n\n'
        'IDEA: ${prompt.trim()}\n\n'
        '$setLine\n\n'
        'Rules:\n'
        '- Keep the exact same subject and concept. Do not add new subjects, characters or objects that change the scene, and never remove the main subject.\n'
        '- Make it fully original and cinematic: a specific environment/setting, a clear centered hero subject with room around it, composition suited to a vertical 9:16 phone wallpaper (main subject centered, clear of the top clock area), a named colour palette, art style/medium, surface texture, fine detail, atmosphere and mood.\n'
        '- Write ONE flowing paragraph of 40-70 words, most important elements first, ending with quality cues like "ultra detailed, sharp focus, cinematic colour grade".\n'
        '- No text, letters, numbers, percentage signs (%), battery icons, UI widgets, clocks or clock faces, watermarks, signatures, logos or brand marks in the image. No real people, brands or copyrighted characters. No blurry, soft or out-of-focus details.\n'
        '- Do NOT mention multiple images, sets or collections — the description is a single scene.\n'
        '- Output ONLY the scene description: no label, no quotes, no explanation, no list.';
  }

  Future<String> generatePromptFromImage(
    Uint8List bytes,
    String filename, {
    String mimeType = 'image/jpeg',
    String styleNote = '',
    int similarity = 20,
    String extraInstruction = '',
    GeminiSession? session,
  }) async {
    var active = session ?? await getSession();
    var attachment =
        await uploadImageForImg2Img(bytes, filename, active, mimeType: mimeType);

    final promptText = buildImageToPromptInstruction(
      similarity: similarity,
      styleNote: styleNote,
      extraInstruction: extraInstruction,
    );

    var variants = _attachmentContentVariants(promptText, attachment, null);
    var switchedOnce = false;
    var lastErr = 'Empty response from Gemini';

    var vIdx = 0;
    while (vIdx < variants.length) {
      final req =
          _buildGenerateRequest(variants[vIdx] as List<dynamic>);
      final body = {
        'f.req': jsonEncode([null, jsonEncode(req.inner)]),
        'at': active.at,
      };
      var response = await _post(_generateUri(active),
          headers: _rpcHeaders(active.cookieHeader, genUuid: req.uuid),
          body: body);

      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 400) {
        active = await getSession(
            forceRefresh: true, explicitAuthUser: active.authUser);
        if (attachment.authUser != active.authUser) {
          attachment = await uploadImageForImg2Img(bytes, filename, active,
              mimeType: mimeType);
          variants =
              _attachmentContentVariants(promptText, attachment, null);
          vIdx = 0;
          continue;
        }
        body['at'] = active.at;
        response = await _post(_generateUri(active),
            headers: _rpcHeaders(active.cookieHeader, genUuid: req.uuid),
            body: body);
      }

      if ((response.statusCode == 429 || response.statusCode == 503) &&
          !switchedOnce) {
        final failover = await trySwitchToNextAccount(active.authUser);
        if (failover != null) {
          switchedOnce = true;
          active = failover;
          attachment = await uploadImageForImg2Img(bytes, filename, active,
              mimeType: mimeType);
          variants = _attachmentContentVariants(promptText, attachment, null);
          vIdx = 0;
          continue;
        }
      }

      await _absorbRotatedCookies(
          active.authUser, response, active.cookieHeader);
      if (response.statusCode != 200) {
        lastErr = 'HTTP ${response.statusCode}';
        vIdx++;
        continue;
      }

      final parsed = parseStreamGenerateResponse(response.body);
      final text = cleanGeneratedPrompt(parsed.assistantText);
      if (text.isNotEmpty) return text;
      lastErr = parsed.errorCode == 1037
          ? 'Gemini usage limit reached for this account (error 1037)'
          : parsed.errorCode != null
              ? 'Gemini returned error ${parsed.errorCode}'
              : 'Gemini returned no prompt text';
      vIdx++;
    }
    throw Exception('Image-to-prompt failed: $lastErr');
  }

  /// Originality AI review: upload BOTH pictures (reference first,
  /// new image second) to the signed-in Gemini session and ask for
  /// an art-director copy-risk judgement. Returns the raw reply.
  Future<String> reviewOriginality(
    Uint8List refBytes,
    String refName,
    Uint8List genBytes,
    String genName,
  ) async {
    String mimeOf(String name) => name.toLowerCase().endsWith('.png')
        ? 'image/png'
        : name.toLowerCase().endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg';
    const instruction = 'You are a senior art director reviewing a '
        'wallpaper for copyright originality. Two images are attached: '
        'the FIRST is the reference picture, the SECOND is a newly '
        'generated picture whose prompt was inspired by the reference. '
        'Judge how much the second image copies the first in subject, '
        'composition, shapes, colours and mood. Start your reply with '
        'exactly one line: RISK: LOW, RISK: MEDIUM or RISK: HIGH. '
        'Then write 2-4 short sentences: what is shared, what is '
        'different, and whether the new image is safe to publish '
        'commercially as an original wallpaper.';
    var active = await getSession();
    var attRef = await uploadImageForImg2Img(refBytes, refName, active,
        mimeType: mimeOf(refName));
    var attGen = await uploadImageForImg2Img(genBytes, genName, active,
        mimeType: mimeOf(genName));

    List<dynamic> content() => [
          instruction,
          0,
          null,
          [
            [
              [attRef.uploadPath],
              attRef.filename
            ],
            [
              [attGen.uploadPath],
              attGen.filename
            ],
          ],
          null,
          null,
          0
        ];

    var retried = false;
    while (true) {
      final req = _buildGenerateRequest(content());
      final body = {
        'f.req': jsonEncode([null, jsonEncode(req.inner)]),
        'at': active.at,
      };
      final response = await _post(_generateUri(active),
          headers: _rpcHeaders(active.cookieHeader, genUuid: req.uuid),
          body: body);
      await _absorbRotatedCookies(
          active.authUser, response, active.cookieHeader);
      if ((response.statusCode == 401 ||
              response.statusCode == 403 ||
              response.statusCode == 400) &&
          !retried) {
        retried = true;
        active = await getSession(
            forceRefresh: true, explicitAuthUser: active.authUser);
        attRef = await uploadImageForImg2Img(refBytes, refName, active,
            mimeType: mimeOf(refName));
        attGen = await uploadImageForImg2Img(genBytes, genName, active,
            mimeType: mimeOf(genName));
        continue;
      }
      if (response.statusCode != 200) {
        throw Exception(
            'AI review failed (HTTP ${response.statusCode})');
      }
      final parsed = parseStreamGenerateResponse(response.body);
      final text = parsed.assistantText.trim();
      if (text.isNotEmpty) return text;
      throw Exception(parsed.errorCode == 1037
          ? 'Gemini usage limit reached for this account (error 1037)'
          : 'Gemini returned no review text');
    }
  }

  /// Tidy a raw Gemini reply into a bare prompt: extracts the
  /// [PROMPT]...[/PROMPT] block when the reply uses that format,
  /// otherwise trims whitespace, surrounding quotes / markdown fences
  /// and a leading "Prompt:" label.
  static String cleanGeneratedPrompt(String raw) {
    var t = raw.trim();
    final blockStart = t.indexOf('[PROMPT]');
    final blockEnd = t.indexOf('[/PROMPT]');
    if (blockStart >= 0 && blockEnd > blockStart) {
      t = t
          .substring(blockStart + '[PROMPT]'.length, blockEnd)
          .replaceAll(RegExp(r'\s*\n\s*'), ' ')
          .trim();
      return t;
    }
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
      t = t.trim();
    }
    t = t.replaceFirst(
        RegExp(r'^(prompt|here is[^\n:]*)\s*:\s*', caseSensitive: false), '');
    // Take the first non-empty paragraph (the prompt itself).
    final para = t
        .split(RegExp(r'\n\s*\n'))
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    t = para.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    if (t.length >= 2 &&
        ((t.startsWith('"') && t.endsWith('"')) ||
            (t.startsWith("'") && t.endsWith("'")))) {
      t = t.substring(1, t.length - 1).trim();
    }
    return t;
  }

  // ---------------------------------------------------------------------
  // Balanced JSON extraction (extension: extractBalancedJsonBlocks etc.)
  // ---------------------------------------------------------------------

  List<String> extractBalancedJsonBlocks(String text) {
    final blocks = <String>[];
    var depth = 0;
    var start = -1;
    String? quote;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quote != null) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (c == '}') {
        if (depth > 0) {
          depth--;
          if (depth == 0 && start >= 0) {
            blocks.add(text.substring(start, i + 1));
            start = -1;
          }
        }
      }
    }
    blocks.sort((a, b) => b.length.compareTo(a.length));
    return blocks;
  }

  Map<String, dynamic>? _decodeJsonMap(String str) {
    final t = str.trim();
    if (t.isEmpty) return null;
    const knownKeys = {
      'title',
      'tags',
      'category',
      'description',
      'arc',
      'anchor',
      'palette',
      'stages',
      'direction',
      'label'
    };
    Map<String, dynamic>? asMap(dynamic v) {
      if (v == null) return null;
      if (v is List) {
        for (final item in v) {
          final m = asMap(item);
          if (m != null) return m;
        }
        return null;
      }
      if (v is Map) return Map<String, dynamic>.from(v);
      return null;
    }

    Map<String, dynamic>? unwrap(Map<String, dynamic> m) {
      final keys = m.keys.toList();
      if (keys.length == 1 &&
          !knownKeys.contains(keys[0]) &&
          m[keys[0]] is Map) {
        return Map<String, dynamic>.from(m[keys[0]] as Map);
      }
      return m;
    }

    for (final candidate in [t, t.replaceAll(RegExp(r',\s*([}\]])'), r'$1')]) {
      try {
        final m = asMap(jsonDecode(candidate));
        if (m != null) return unwrap(m);
      } catch (_) {}
    }
    return null;
  }

  Map<String, dynamic>? extractJsonMapFromReply(String text) {
    final cleaned = text.replaceAll(RegExp(r'```(?:\w+)?'), '').trim();
    final direct = _decodeJsonMap(cleaned);
    if (direct != null) return direct;
    for (final block in extractBalancedJsonBlocks(cleaned)) {
      final m = _decodeJsonMap(block);
      if (m != null) return m;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // AI metadata + AI Set Director
  // ---------------------------------------------------------------------

  /// v45 (user order): a listing description must never mention the
  /// set type or set behaviour - no "24-hour set", no battery label,
  /// for ANY set type. The instruction asks for a scene-only
  /// description; this is the deterministic backstop: sentences that
  /// mention the set are dropped, and if every sentence does, only
  /// the banned phrases are stripped. Word boundaries keep innocent
  /// words like "sunset" safe.
  static final RegExp _setTypeMention = RegExp(
      r'(\b24\s*-?\s*h(our)?s?\b|\b\d+\s*-\s*hours?\b|\bbattery\b'
      r'|\bdual\s+set\b|\block\s+and\s+home\b|\bhome\s+and\s+lock\b'
      r'|\btime[\s-]of[\s-]day\b|\bset\b'
      r'|\bcollection of (wallpapers|images|designs)\b'
      r'|\b(two|three|four|five|six|seven|eight|\d+)\s+'
      r'(wallpapers|variants|stages|versions|backgrounds)\b)',
      caseSensitive: false);

  static String stripSetTypeMentions(String input) {
    final text = input.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return text;
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final kept =
        sentences.where((x) => !_setTypeMention.hasMatch(x)).toList();
    if (kept.isNotEmpty) return kept.join(' ').trim();
    var stripped = text.replaceAll(_setTypeMention, ' ');
    stripped = stripped
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s+([.,!?])'), r'$1')
        .trim();
    return stripped.length >= 12 ? stripped : '';
  }

  Future<SetMetadata> generateSetMetadata({
    required String workflowMode,
    required String prompt,
    required String file,
    GeminiSession? session,
  }) async {
    final setTypeStr = workflowMode == 'set_24h'
        ? '24-HOUR'
        : workflowMode == 'set_dual'
            ? 'DUAL'
            : workflowMode == 'set_battery'
                ? 'BATTERY'
                : 'SINGLE';
    var concept = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (concept.length > 40) concept = concept.substring(0, 40);
    if (concept.isEmpty) concept = 'wallpaper';

    final systemPrompt =
        'You write Zedge wallpaper listing metadata. Reply with ONE JSON object only, no markdown, no commentary.\n'
        'Schema: {"title": string (max 30 characters, Title Case, catchy, no emoji, no quotes), '
        '"tags": array of 8 to 12 single lowercase words (no spaces, no hyphens, no duplicates, no brand or franchise names), '
        '"category": one of ${jsonEncode(kZedgeCategories)}, '
        '"description": string (1-2 sentences, max 200 characters, natural, no hashtags, no emoji)}.\n'
        'Set types (context for the title and tags ONLY): 24-HOUR = 4 time-of-day wallpapers; DUAL = lock + home screen pair; BATTERY = 6 charge-level wallpapers; SINGLE = one wallpaper. '
        'DESCRIPTION RULE: write the description as if it were for ONE single wallpaper - only the artwork itself: the scene, subject, mood and colours. NEVER mention the set type or set behaviour: no 24-hour or 24H, no battery or charge levels, no dual or lock-and-home pairing, no image counts, no time-of-day changes, and never the words set, collection or pack. Never mention copyrighted characters, brands, humans or text. '
        'Do not describe the image in sentences - output only the JSON object.';
    const varietyNote =
        'Write like a normal human uploader, not a template: vary the title structure naturally (sometimes the subject, sometimes the mood, sometimes a short phrase), '
        'never start the description the same way twice, and pick tags that fit this specific image - specific over generic - shuffling their order every time.';
    const webJsonNote =
        'OUTPUT RULE: reply with the raw JSON object ONLY. No markdown, no code fences, no commentary, no explanation before or after it.';
    final fullPrompt = '$systemPrompt\n\n$varietyNote\n\n'
        'Set type: $setTypeStr\nConcept name: $concept\nImage prompt: $prompt\n\n'
        'Return the JSON object now.\n\n$webJsonNote';

    Map<String, dynamic>? metaMap;
    var lastReply = '';
    for (var attempt = 0; attempt < 3; attempt++) {
      final replyText =
          await askGeminiText(fullPrompt, session: session, attempts: 2);
      lastReply = replyText;
      metaMap = extractJsonMapFromReply(replyText);
      if (metaMap != null &&
          (metaMap['title'] != null || metaMap['tags'] != null)) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    if (metaMap == null) {
      throw Exception(
          'Gemini did not return valid metadata JSON. Reply: ${lastReply.length > 120 ? lastReply.substring(0, 120) : lastReply}');
    }

    final tags = <String>[];
    final rawTags = metaMap['tags'];
    if (rawTags is List) {
      for (final rawTag in rawTags) {
        final clean = rawTag
            .toString()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (clean.isNotEmpty && !tags.contains(clean)) tags.add(clean);
        if (tags.length == 12) break;
      }
    }
    var category = (metaMap['category']?.toString() ?? '').toUpperCase().trim();
    if (!kZedgeCategories.contains(category)) category = 'DESIGNS';
    var title = (metaMap['title']?.toString() ?? '')
        .replaceAll(RegExp(r'''["']'''), '')
        .trim();
    if (title.length > 30) title = title.substring(0, 30);
    var description = (metaMap['description']?.toString() ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    description = stripSetTypeMentions(description);
    if (description.length > 200) description = description.substring(0, 200);

    return SetMetadata(
      file: file,
      title: title,
      tags: tags,
      category: category,
      description: description,
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// v87 — AI listing metadata for one finished animation video:
  /// the same JSON shape as [generateSetMetadata] (title / tags /
  /// category / description), asked from the user's own Gemini
  /// session — no API key. The description covers the animation
  /// itself (subject, motion, mood, loop), never set behaviour.
  Future<SetMetadata> generateVideoMetadata({
    required String prompt,
    required String file,
    GeminiSession? session,
  }) async {
    var concept = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (concept.length > 40) concept = concept.substring(0, 40);
    if (concept.isEmpty) concept = 'charging animation';

    final systemPrompt =
        'You write Zedge live wallpaper (animated video) listing metadata. Reply with ONE JSON object only, no markdown, no commentary.\n'
        'Schema: {"title": string (max 30 characters, Title Case, catchy, no emoji, no quotes), '
        '"tags": array of 8 to 12 single lowercase words (no spaces, no hyphens, no duplicates, no brand or franchise names), '
        '"category": one of ${jsonEncode(kZedgeCategories)}, '
        '"description": string (1-2 sentences, max 200 characters, natural, no hashtags, no emoji)}.\n'
        'The listing is ONE animated live wallpaper video (9:16 vertical, seamless loop). '
        'DESCRIPTION RULE: describe the animation itself only — the scene, subject, motion and colours. NEVER mention sets, collections or packs, image counts, or how the video was made. Never mention copyrighted characters, brands, humans or text. '
        'Do not describe the image in sentences - output only the JSON object.';
    const varietyNote =
        'Write like a normal human uploader, not a template: vary the title structure naturally (sometimes the subject, sometimes the mood, sometimes a short phrase), '
        'never start the description the same way twice, and pick tags that fit this specific video - specific over generic - shuffling their order every time.';
    const webJsonNote =
        'OUTPUT RULE: reply with the raw JSON object ONLY. No markdown, no code fences, no commentary, no explanation before or after it.';
    final fullPrompt = '$systemPrompt\n\n$varietyNote\n\n'
        'Type: ANIMATION (one live wallpaper video)\nConcept name: $concept\nVideo prompt: $prompt\n\n'
        'Return the JSON object now.\n\n$webJsonNote';

    Map<String, dynamic>? metaMap;
    var lastReply = '';
    for (var attempt = 0; attempt < 3; attempt++) {
      final replyText =
          await askGeminiText(fullPrompt, session: session, attempts: 2);
      lastReply = replyText;
      metaMap = extractJsonMapFromReply(replyText);
      if (metaMap != null &&
          (metaMap['title'] != null || metaMap['tags'] != null)) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    if (metaMap == null) {
      throw Exception(
          'Gemini did not return valid metadata JSON. Reply: ${lastReply.length > 120 ? lastReply.substring(0, 120) : lastReply}');
    }

    final tags = <String>[];
    final rawTags = metaMap['tags'];
    if (rawTags is List) {
      for (final rawTag in rawTags) {
        final clean = rawTag
            .toString()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (clean.isNotEmpty && !tags.contains(clean)) tags.add(clean);
        if (tags.length == 12) break;
      }
    }
    var category = (metaMap['category']?.toString() ?? '').toUpperCase().trim();
    if (!kZedgeCategories.contains(category)) category = 'DESIGNS';
    var title = (metaMap['title']?.toString() ?? '')
        .replaceAll(RegExp(r'''["']'''), '')
        .trim();
    if (title.length > 30) title = title.substring(0, 30);
    var description = (metaMap['description']?.toString() ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    description = stripSetTypeMentions(description);
    if (description.length > 200) description = description.substring(0, 200);

    return SetMetadata(
      file: file,
      title: title,
      tags: tags,
      category: category,
      description: description,
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<DirectorPlan> directSetWithGemini({
    required String workflowMode,
    required List<String> variantLabels,
    required String prompt,
    GeminiSession? session,
  }) async {
    final stageCount = variantLabels.length;
    final typeUpper = workflowMode == 'set_battery'
        ? 'BATTERY'
        : workflowMode == 'set_24h'
            ? '24-HOUR'
            : workflowMode == 'set_dual'
                ? 'DUAL'
                : 'SINGLE';
    var perTypeRules = '';
    if (typeUpper == 'BATTERY') {
      perTypeRules = 'BATTERY set ($stageCount charge levels, 0% to 100%):\n'
          '- The glow HUE is locked by the concept and must be identical in every stage. Only the AMOUNT of light changes.\n'
          '- Every direction MUST state, as absolute values: the share of the frame that is lit (about 5, 20, 40, 60, 80 then 100 percent), the brightness of the glow core, the bloom radius, and how much of the frame is still in shadow.\n'
          '- Spread the ladder evenly and make the top half obvious: 60% must read as clearly dimmer than 80%, and 80% clearly dimmer than 100%. Use different physical light behaviour per stage (halo size, light rays, reflections, volumetric beams, lens flare, blown-out core, haze) so the upper levels can never look the same.\n'
          '- 0% is almost black, 100% has no dark area left anywhere in the frame.\n'
          '- The main subject stays centered in the frame in every stage, in the same relative position — only the energy and light change, never the subject size, pose or layout.\n'
          '- The final Charging stage is a UNIQUE version, not just 100%: same scene at full brightness plus a power motif — glowing energy flowing into the subject as if it is charging.';
    } else if (typeUpper == '24-HOUR') {
      perTypeRules = '24-HOUR set ($stageCount times of day):\n'
          '- Every direction MUST state: the clock hour, the key-light direction and elevation in degrees, the color temperature in Kelvin, the shadow length and direction, and the amount of atmosphere (mist, haze, clarity).\n'
          '- Dawn is low warm light with long shadows, midday is near-overhead neutral light with short hard shadows, evening is low raking warm light with long shadows the opposite way, night has no sun at all, cool light and mostly deep shadow.\n'
          '- Shadow direction must visibly flip between morning and evening.\n'
          '- The main subject stays centered in the frame in every stage, in the same relative position — only the light, color and atmosphere change, never the subject, objects or layout.';
    } else if (typeUpper == 'DUAL') {
      perTypeRules = 'DUAL set ($stageCount screens):\n'
          '- Lock and Home must differ in FRAMING, not in lighting. Keep the lighting and palette the same.\n'
          '- Every direction MUST state: how much of the frame height the hero fills (about 80 percent for Lock, about 30 percent for Home), the depth of field (shallow and blurred background for Lock, deep focus for Home), and where the calm empty space sits.\n'
          '- Home must leave a quiet low-detail area in the upper half for clock, icons and widgets.';
    }

    final directorPrompt =
        'You are a professional art director for premium mobile wallpaper sets sold on wallpaper marketplaces. Reply with ONE JSON object only, no markdown, no commentary.\n'
        'Schema: {"arc": string (short evocative arc name, e.g. "Bloom cycle"), '
        '"anchor": string (one neutral base-scene description fragment, no strong time-of-day or energy bias — it is the reference image every stage is re-lit from, so it must be a clean, mid-dark, unbiased rendering of the concept), '
        '"palette": array of 1-3 lowercase color words actually present in the concept, '
        '"stages": array with EXACTLY $stageCount objects, one per variant label in the given order, each {"label": string (the exact label), "direction": string (1-3 sentences describing ONLY what this stage looks like: lighting, state, atmosphere, framing — the subject, objects, background and art style stay identical)}}.\n'
        'Hard rules:\n'
        '- Never describe text, letters, numbers, symbols, icons, logos or watermarks in the image.\n'
        '- Each direction is an ABSOLUTE description of that stage, never a relative one.\n'
        '- Never reuse the same adjective, light behaviour or mood in two stages.\n'
        '- Never add, remove, resize or rearrange the subject, objects or background unless the set type explicitly asks for a framing change.\n'
        '$perTypeRules\n\n'
        'Set type: $typeUpper\n'
        'Variant labels in order: ${variantLabels.map((l) => '"$l"').join(', ')}\n'
        'User prompt: $prompt\n\n'
        'Return the JSON object now.\n'
        'OUTPUT RULE: reply with the raw JSON object ONLY. No markdown, no code fences, no commentary.';

    final replyText =
        await askGeminiText(directorPrompt, session: session, attempts: 2);
    final meta = extractJsonMapFromReply(replyText);
    if (meta == null ||
        meta['stages'] is! List ||
        (meta['stages'] as List).length < stageCount) {
      throw Exception('AI Set Director returned an incomplete stage plan.');
    }
    final stagesRaw = meta['stages'] as List;
    final directions = <String>[];
    for (var i = 0; i < stageCount; i++) {
      final s = stagesRaw[i];
      final dir = s is Map ? s['direction']?.toString().trim() ?? '' : '';
      if (dir.isEmpty) throw Exception('Empty stage direction in AI plan.');
      directions.add(dir);
    }
    final palette = <String>[];
    final rawPalette = meta['palette'];
    if (rawPalette is List) {
      for (final c in rawPalette) {
        final w = c.toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
        if (w.isNotEmpty && !palette.contains(w)) palette.add(w);
        if (palette.length == 3) break;
      }
    }
    return DirectorPlan(
      arc: meta['arc']?.toString() ?? 'AI Directed Arc',
      anchorDirection: (meta['anchor']?.toString() ?? '').trim(),
      palette: palette,
      stageDirections: directions,
    );
  }

  // ---------------------------------------------------------------------
  // HD image fetch + resumable upload (img2img) + StreamGenerate for images
  // ---------------------------------------------------------------------

  /// Download candidates for a generated image URL, best first.
  ///
  /// History, learned the hard way on device: the extension-era
  /// '=s0' rewrite died first (v19 screenshot, HTTP 403), then the
  /// v20 ladder (=s2048-rj / bare / =s0) ALL returned 403 — because
  /// the parser had already stripped the issued suffix before the
  /// fetch ever saw the URL, so the one signed form was never
  /// tried. Gemini's display URLs (/gg/) and download URLs
  /// (/gg-dl/) are different signed schemes and suffix rewriting
  /// cannot turn one into the other (packet-capture verified by
  /// the banana-pick project, November 2026). So the ladder is:
  ///   1. the URL exactly as Gemini issued it (suffix + query),
  ///   2. the '=d-I?alr=yes' download form — the shape the signed
  ///      gg-dl URL returned by Gemini's own c8o8Fe download RPC
  ///      carries,
  ///   3. '=s2048-rj' (gemini-webapi's documented fallback),
  ///   4. '=s1024-rj' (the standard issued preview size),
  ///   5. the bare token URL,
  ///   6. the legacy '=s0'.
  static List<String> downloadCandidates(String issuedUrl) {
    final issued = issuedUrl.trim();
    final base = _urlBaseKey(issued);
    final out = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }

    add(issued);
    add('$base=d-I?alr=yes');
    add('$base=s2048-rj');
    add('$base=s1024-rj');
    add(base);
    add('$base=s0');
    return out;
  }

  static String _candidateLabel(String url, String issuedUrl) {
    if (url == issuedUrl) return 'as-issued';
    if (url.contains('=d-I')) return '=d-I';
    final m = RegExp(r'(=[a-zA-Z0-9\-_]+)$').firstMatch(url.split('?').first);
    return m != null ? m.group(1)! : 'bare';
  }

  /// Which signed scheme a Gemini image URL belongs to, for error
  /// messages: gg (display), gg-dl / rd-gg-dl (download), other.
  static String _urlScheme(String url) {
    if (url.contains('/rd-gg-dl/')) return 'rd-gg-dl';
    if (url.contains('/gg-dl/')) return 'gg-dl';
    if (url.contains('/gg/')) return 'gg';
    return 'other';
  }

  /// Downloads a generated image, walking the candidate forms
  /// until one serves the picture. First pass sends the account's
  /// session cookies; if every form is refused, a second pass
  /// retries the leading forms WITHOUT cookies — these CDN URLs
  /// are bearer tokens, and a stale cookie can poison an otherwise
  /// valid one. The thrown message names the URL scheme plus the
  /// first form tried and how many more failed (the full per-form
  /// detail goes to the debug log), so a future break stays
  /// diagnosable without filling the dialog.
  Future<HdFetchResult> fetchHdBlob(
      String issuedUrl, GeminiSession session) async {
    final candidates = downloadCandidates(issuedUrl);
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        return await _fetchImage(candidate, session, withCookies: true);
      } catch (e) {
        failures.add('${_candidateLabel(candidate, issuedUrl)}: $e');
      }
    }
    for (final candidate in candidates.take(3)) {
      try {
        return await _fetchImage(candidate, session, withCookies: false);
      } catch (e) {
        failures.add(
            '${_candidateLabel(candidate, issuedUrl)} (no-cookie): $e');
      }
    }
    // v79: the full per-form detail goes to the debug log only — the
    // thrown message stays short enough to read in a dialog. His
    // 2026-11-14 screenshot showed all 9 forms joined into one
    // wall of Google HTML soup, unreadable.
    debugPrint(
        'fetchHdBlob failed [${_urlScheme(issuedUrl)}]: ${failures.join('; ')}');
    final all403 = failures.isNotEmpty &&
        failures.every((f) => f.contains('HTTP 403'));
    final first = failures.isNotEmpty ? failures.first : 'unknown error';
    throw Exception(
        'Gemini image download failed [${_urlScheme(issuedUrl)}] '
        '($first${failures.length > 1 ? '; ... (+${failures.length - 1} aro form)' : ''})'
        '${all403 ? ' — shob form 403: link-er meyad sesh ba session bodle geche' : ''}');
  }

  /// Google's error pages are HTML; pull a short plain-text
  /// snippet out of one so a screenshot shows WHY it refused.
  static String _errorSnippet(String body) {
    final text = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '';
    return text.length > 80 ? text.substring(0, 80) : text;
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return true; // JPEG
    }
    if (b.length >= 4 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return true; // PNG
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true; // WebP
    }
    return false;
  }

  /// One download attempt: GET [startUrl] (UA + Referer, plus the
  /// session cookies unless [withCookies] is false). A text/plain
  /// body holding a URL is a download hand-off — the signed
  /// gg-dl chain serves two of those — follow it verbatim, a few
  /// times.
  Future<HdFetchResult> _fetchImage(String startUrl, GeminiSession session,
      {required bool withCookies}) async {
    var currentUrl = startUrl;
    for (var hop = 0; hop < 4; hop++) {
      final resp = await _get(Uri.parse(currentUrl), headers: {
        'User-Agent': chromeUserAgent,
        'Referer': 'https://gemini.google.com/',
        if (withCookies && session.cookieHeader.isNotEmpty)
          'Cookie': session.cookieHeader,
      }, timeout: const Duration(minutes: 10));
      if (resp.statusCode != 200) {
        final snippet = _errorSnippet(resp.body);
        throw Exception(
            'HTTP ${resp.statusCode}${snippet.isEmpty ? '' : ' — $snippet'}');
      }
      final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('text/plain')) {
        final textBody = resp.body.trim();
        if (textBody.startsWith('https://')) {
          currentUrl = textBody;
          continue;
        }
        throw Exception('unexpected text/plain body');
      }
      if (!contentType.contains('image/') &&
          !contentType.contains('octet-stream') &&
          !_looksLikeImage(resp.bodyBytes)) {
        throw Exception('unexpected content-type "$contentType"');
      }
      final bytes = resp.bodyBytes;
      final isPng = bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50;
      final isWebp = bytes.length >= 12 && bytes[8] == 0x57 && bytes[9] == 0x45;
      final mimeType = (contentType.contains('png') || isPng)
          ? 'image/png'
          : (contentType.contains('webp') || isWebp)
              ? 'image/webp'
              : 'image/jpeg';
      final ext = mimeType == 'image/png'
          ? 'png'
          : mimeType == 'image/webp'
              ? 'webp'
              : 'jpg';
      return HdFetchResult(resp.bodyBytes, mimeType, ext, currentUrl);
    }
    throw Exception('too many download hops');
  }

  Future<GeminiAttachment> uploadImageForImg2Img(
    Uint8List bytes,
    String filename,
    GeminiSession session, {
    String mimeType = 'image/jpeg',
    int stepNum = 2,
  }) async {
    final u = session.authUser;
    _status('img2img_uploading', stepNum,
        'Uploading anchor reference image to Gemini u/$u (${(bytes.length / 1024).round()} KB)...');

    final initUri = Uri.parse('$uploadInitUrl?authuser=$u');
    final startResp = await _post(initUri,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'Push-Id': pushId,
          'X-Client-Pctx': clientPctx,
          'X-Goog-AuthUser': '$u',
          'X-Goog-Upload-Command': 'start',
          'X-Goog-Upload-Header-Content-Length': '${bytes.length}',
          'X-Goog-Upload-Protocol': 'resumable',
          'X-Tenant-Id': tenantId,
          'User-Agent': chromeUserAgent,
          if (session.cookieHeader.isNotEmpty) 'Cookie': session.cookieHeader,
        },
        body: 'File name: $filename',
        timeout: const Duration(minutes: 10));
    if (startResp.statusCode != 200) {
      throw Exception(
          'Gemini resumable upload init failed (HTTP ${startResp.statusCode})');
    }
    final uploadUrl = startResp.headers['x-goog-upload-url'] ??
        startResp.headers['x-goog-upload-control-url'];
    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception(
          'Gemini upload init did not return x-goog-upload-url header.');
    }

    final finalizeResp = await _post(Uri.parse(uploadUrl),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
          'Push-Id': pushId,
          'X-Client-Pctx': clientPctx,
          'X-Goog-Upload-Command': 'upload, finalize',
          'X-Goog-Upload-Offset': '0',
          'X-Tenant-Id': tenantId,
          'User-Agent': chromeUserAgent,
          if (session.cookieHeader.isNotEmpty) 'Cookie': session.cookieHeader,
        },
        body: bytes, timeout: const Duration(minutes: 10));
    if (finalizeResp.statusCode != 200) {
      throw Exception(
          'Gemini image binary upload failed (HTTP ${finalizeResp.statusCode})');
    }
    final uploadPath = finalizeResp.body.trim();
    if (!uploadPath.startsWith('/contrib_service/')) {
      throw Exception(
          'Unexpected upload path returned by bard-storage: "${uploadPath.length > 100 ? uploadPath.substring(0, 100) : uploadPath}"');
    }

    String? processFileUuid;
    try {
      final processInner = jsonEncode([
        [
          [uploadPath, null, 1, mimeType],
          filename,
          null,
          null,
          null,
          null,
          null,
          null,
          [0]
        ],
        null,
        1,
        ['en']
      ]);
      final formBody = {
        'f.req': jsonEncode([null, processInner]),
        'at': session.at,
      };
      final procResp = await _post(_rpcUri(session, 'ProcessFile'),
          headers: _rpcHeaders(session.cookieHeader), body: formBody, timeout: const Duration(minutes: 10));
      await _absorbRotatedCookies(
          session.authUser, procResp, session.cookieHeader);
      if (procResp.statusCode == 200) {
        final m = RegExp(
                r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                caseSensitive: false)
            .firstMatch(procResp.body);
        if (m != null) processFileUuid = m.group(0);
      }
    } catch (_) {}

    return GeminiAttachment(
      uploadPath: uploadPath,
      mimeType: mimeType,
      filename: filename,
      processFileUuid: processFileUuid,
      authUser: u,
      sourceBytes: bytes,
    );
  }

  /// Message-content variants for an attachment request (the
  /// caller wraps each in the current 81-slot frame via
  /// [_buildGenerateRequest]). First: the file-reference structure
  /// the current web client sends — `[[[path], filename]]`. Then
  /// the extension-era descriptor forms as fallbacks.
  List<dynamic> _attachmentContentVariants(
      String prompt, GeminiAttachment att, String? aspectRatioHint) {
    final variants = <dynamic>[];
    variants.add([
      prompt,
      0,
      null,
      [
        [
          [att.uploadPath],
          att.filename
        ]
      ],
      null,
      null,
      0
    ]);
    final aspectField10 = aspectRatioHint != null
        ? [
            null,
            null,
            null,
            null,
            null,
            null,
            [
              null,
              [null, aspectRatioHint]
            ]
          ]
        : null;
    final desc1 = att.processFileUuid != null
        ? [att.uploadPath, 1, null, att.mimeType, att.processFileUuid]
        : [att.uploadPath, 1, null, att.mimeType];
    final att1 = [
      desc1,
      att.filename,
      null,
      null,
      null,
      null,
      null,
      null,
      [0]
    ];
    variants.add(aspectField10 != null
        ? [
            prompt,
            0,
            null,
            [att1],
            null,
            null,
            0,
            null,
            null,
            aspectField10
          ]
        : [
            prompt,
            0,
            null,
            [att1],
            null,
            null,
            0
          ]);
    final desc2 = [att.uploadPath, null, 1, att.mimeType];
    final att2 = [
      desc2,
      att.filename,
      null,
      null,
      null,
      null,
      null,
      null,
      [0]
    ];
    variants.add([
      prompt,
      0,
      null,
      [att2],
      null,
      null,
      0
    ]);
    return variants;
  }

  /// Extension: callGeminiStreamGenerate — image generation with the same
  /// payload variants, token-refresh retry and quota auto-switch behaviour.
  Future<StreamGenerateResult> callStreamGenerate({
    required String prompt,
    GeminiSession? session,
    GeminiAttachment? attachment,
    String? aspectRatioHint,
    List<String> excludeUrls = const [],
  }) async {
    final payloadVariants = attachment != null
        ? _attachmentContentVariants(prompt, attachment, aspectRatioHint)
        : <dynamic>[
            [prompt, 0, null, null, null, null, 0]
          ];

    var lastParsed = const StreamGenerateResult([], '');
    var activeSession = session ?? await getSession();
    var currentAttachment = attachment;
    var switchedOnce = false;

    var vIdx = 0;
    while (vIdx < payloadVariants.length) {
      if (currentAttachment != null &&
          currentAttachment.authUser != activeSession.authUser) {
        currentAttachment = await uploadImageForImg2Img(
          currentAttachment.sourceBytes,
          currentAttachment.filename,
          activeSession,
          mimeType: currentAttachment.mimeType,
        );
        // Rebuild variants against the re-uploaded attachment.
        payloadVariants
          ..clear()
          ..addAll(_attachmentContentVariants(
              prompt, currentAttachment, aspectRatioHint));
        vIdx = 0;
      }

      final req =
          _buildGenerateRequest(payloadVariants[vIdx] as List<dynamic>);
      final u = activeSession.authUser;
      final body = {
        'f.req': jsonEncode([null, jsonEncode(req.inner)]),
        'at': activeSession.at,
      };
      var response = await _post(_generateUri(activeSession),
          headers:
              _rpcHeaders(activeSession.cookieHeader, genUuid: req.uuid),
          body: body);

      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 400) {
        activeSession =
            await getSession(forceRefresh: true, explicitAuthUser: u);
        body['at'] = activeSession.at;
        response = await _post(_generateUri(activeSession),
            headers: _rpcHeaders(activeSession.cookieHeader,
                genUuid: req.uuid),
            body: body);
      }

      if ((response.statusCode == 429 || response.statusCode == 503) &&
          !switchedOnce) {
        final failover = await trySwitchToNextAccount(u);
        if (failover != null) {
          switchedOnce = true;
          activeSession = failover;
          continue; // retry same variant on the new account
        }
      }

      await _absorbRotatedCookies(
          u, response, activeSession.cookieHeader);
      if (response.statusCode != 200) {
        if (vIdx == payloadVariants.length - 1) {
          throw Exception(
              'StreamGenerate RPC failed on u/$u with HTTP ${response.statusCode}');
        }
        vIdx++;
        continue;
      }

      final parsed =
          parseStreamGenerateResponse(response.body, excludeUrls: excludeUrls);
      lastParsed = parsed;
      if (parsed.urls.isNotEmpty) return parsed;

      // Classified server errors from the stream envelope.
      final code = parsed.errorCode;
      if (code != null) {
        if (code == 1052) {
          throw Exception('Gemini rejected the request format '
              '(error 1052) on u/$u — Google changed the web '
              'protocol again; this build needs an update.');
        }
        if (code == 1060) {
          throw Exception('Google has temporarily blocked this IP '
              'address (error 1060). Try another network, or wait '
              'a while and retry.');
        }
        if (code == 1050) {
          throw Exception('Gemini model mismatch (error 1050) on '
              'u/$u. Sign in again from the Login tab and retry.');
        }
        if (code == 1013 && vIdx < payloadVariants.length - 1) {
          vIdx++;
          continue; // temporary server error: next variant
        }
        // 1037 (usage limit) and anything else fall through to the
        // account-failover logic below.
      }

      if (!switchedOnce &&
          (isQuotaOrLimitFailure(200, parsed.assistantText) ||
              parsed.errorCode == 1037 ||
              vIdx == payloadVariants.length - 1)) {
        final failover = await trySwitchToNextAccount(u);
        if (failover != null) {
          switchedOnce = true;
          activeSession = failover;
          vIdx = 0;
          continue;
        }
      }
      vIdx++;
    }
    return lastParsed;
  }
}
