import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'session_store.dart';

/// v121 — the fields the built-in browser read from the Gemini
/// page it loaded (SNlM0e token + account fields). Only the
/// extracted fields cross the native bridge, never page HTML.
///
/// v122 — [authUser] is the account slot the page belonged to,
/// parsed from its /u/<n>/ URL (null when the URL carries none —
/// a plain /app load serves the profile's default account).
typedef GeckoSessionPage = ({
  String at,
  String bl,
  String fSid,
  String email,
  String serverToken,
  List<String> apiKeys,
  String url,
  int? authUser,
});

/// Android only: the built-in Firefox engine (GeckoView) sign-in.
///
/// Google blocks sign-in inside Android WebView, but GeckoView is a
/// real browser engine (the one inside Firefox for Android). The user
/// signs in once on the full-screen sign-in screen; its private
/// profile keeps the Google session, and a tiny built-in extension
/// hands the Gemini session cookies back to the app — so connecting
/// is automatic again, no pasting. The native side lives in
/// android/.../GeckoBridge.kt + GeckoSignInActivity.kt (pattern
/// adapted from the AI Image Studio source the user provided).
///
/// On every other platform [supported] is false and the Login screen
/// keeps the external-browser + paste flow.
class GeckoSignIn {
  GeckoSignIn._();

  static const _ch = MethodChannel('com.geminihd.studio/gecko');

  static bool get supported => Platform.isAndroid;

  /// The Google session cookie names a Gemini web session consists
  /// of — the same allow-list the built-in extension filters by.
  static const sessionCookieNames = {
    'SID', 'HSID', 'SSID', 'APISID', 'SAPISID', 'SIDCC', 'NID', 'AEC',
    '__Secure-1PSID', '__Secure-3PSID',
    '__Secure-1PSIDTS', '__Secure-3PSIDTS',
    '__Secure-1PSIDCC', '__Secure-3PSIDCC',
    '__Secure-1PAPISID', '__Secure-3PAPISID',
  };

  /// Opens the sign-in screen on [url]; completes when it closes.
  /// Returns the sign-in result payload: {"cookies": [...],
  /// "session": {...}} since v121 (the "session" half is the
  /// token the browser read off its own loaded page — null when
  /// the page read missed), or null when the profile is not
  /// signed in. Older builds returned the bare cookie array.
  static Future<String?> signIn(String url) =>
      _ch.invokeMethod<String>('signIn', {'url': url});

  /// Loads Gemini invisibly in the signed-in profile so the engine
  /// renews the Google session itself, then returns the fresh
  /// sign-in result payload (same shape as [signIn]; null =
  /// profile not signed in).
  static Future<String?> refresh() async {
    // v123 — the Kotlin side may wait up to 150s for the slow
    // headless page to parse (plus its own reads), so the Dart
    // timeout must cover it; 60s cut the answer off mid-load on a
    // slow network (live 2026-11-21: 2.4 KB/s).
    try {
      return await _ch
          .invokeMethod<String>('refresh')
          .timeout(const Duration(seconds: 180));
    } on TimeoutException {
      return null;
    }
  }

  /// Pure: converts the extension's cookie JSON array
  /// (`[{"name": ..., "value": ...}, ...]`) into a Cookie header
  /// string, keeping only the Gemini session cookie names. '' when
  /// the input holds no usable session cookies.
  ///
  /// v121 — the native side returns {"cookies": [...], "session":
  /// {...}}; a bare cookie array (older results) is accepted too.
  static String headerFromCookiesJson(String? json) {
    if (json == null || json.trim().isEmpty) return '';
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return '';
    }
    if (decoded is Map) decoded = decoded['cookies'];
    if (decoded is! List) return '';
    final pairs = <String>[];
    for (final c in decoded) {
      if (c is! Map) continue;
      final name = (c['name'] ?? '').toString();
      final value = (c['value'] ?? '').toString();
      if (value.isEmpty || !sessionCookieNames.contains(name)) continue;
      pairs.add('$name=$value');
    }
    return pairs.join('; ');
  }

  /// Pure: pulls the in-browser session page out of a sign-in /
  /// refresh result payload. Null when the payload is a bare
  /// cookie array, when the "session" half is missing, or when it
  /// carries no token — the caller then falls back to the Dart
  /// HTTP verify.
  static GeckoSessionPage? sessionPageFromResult(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final s = decoded['session'];
    if (s is! Map) return null;
    final at = (s['at'] ?? '').toString();
    if (at.isEmpty) return null;
    final apiKeys = <String>[];
    final rawKeys = s['apiKeys'];
    if (rawKeys is List) {
      for (final k in rawKeys) {
        final v = k.toString();
        if (v.isNotEmpty) apiKeys.add(v);
      }
    }
    final url = (s['url'] ?? '').toString();
    final slotMatch = RegExp(r'/u/(\d+)/').firstMatch(url);
    final authUser =
        slotMatch == null ? null : int.tryParse(slotMatch.group(1)!);
    return (
      at: at,
      bl: (s['bl'] ?? '').toString(),
      fSid: (s['fSid'] ?? '').toString(),
      email: (s['email'] ?? '').toString(),
      serverToken: (s['serverToken'] ?? '').toString(),
      apiKeys: apiKeys,
      url: url,
      authUser: authUser,
    );
  }

  /// v122 — the headless-browser renewal, shared by the Login
  /// Test button and the home screen's silent renewal / session
  /// check: asks the built-in browser for its fresh cookies +
  /// the session page it read off its own loaded Gemini page.
  /// Null when the profile holds no signed-in session or the page
  /// read missed — the caller falls back to the Dart HTTP path.
  static Future<({String header, GeckoSessionPage page})?>
      refreshSessionPage() async {
    final raw = await refresh();
    final header = headerFromCookiesJson(raw);
    if (!SessionStore.cookieHeaderLooksLoggedIn(header)) return null;
    final page = sessionPageFromResult(raw);
    if (page == null) return null;
    return (header: header, page: page);
  }
}
