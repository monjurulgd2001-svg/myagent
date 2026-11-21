import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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
  /// Returns the session-cookie JSON array, or null when the profile
  /// is not signed in.
  static Future<String?> signIn(String url) =>
      _ch.invokeMethod<String>('signIn', {'url': url});

  /// Loads Gemini invisibly in the signed-in profile so the engine
  /// renews the Google session itself, then returns the fresh
  /// session-cookie JSON (null = profile not signed in).
  static Future<String?> refresh() async {
    try {
      return await _ch
          .invokeMethod<String>('refresh')
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      return null;
    }
  }

  /// Pure: converts the extension's cookie JSON array
  /// (`[{"name": ..., "value": ...}, ...]`) into a Cookie header
  /// string, keeping only the Gemini session cookie names. '' when
  /// the input holds no usable session cookies.
  static String headerFromCookiesJson(String? json) {
    if (json == null || json.trim().isEmpty) return '';
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return '';
    }
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
}
