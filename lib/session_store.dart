// Persists the Gemini cookie jar + account choices on this device only.
// Cookies are the user's own Google session cookies, captured from the
// app browser sign-in (or pasted by the user). They never leave the
// device except in requests to gemini.google.com itself — exactly like
// the Chrome extension, which used the browser's cookie jar.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SessionStore {
  static const _kCookiesByUser = 'cookiesByUserJson';
  static const _kDiscovered = 'discoveredGeminiAccountsJson';
  static const _kAccountMode = 'geminiAccountMode'; // "auto" or "0".."5"
  static const _kActiveInfo = 'activeGeminiAccountInfoJson';
  static const _kManualCookie = 'manualCookieHeader';
  static const _kAutoRenew = 'sessionAutoRenew';

  /// Whether the app may refresh saved Gemini sessions in the
  /// background (startup + every 15 minutes). Default ON: it keeps
  /// pasted / idle logins from expiring. When OFF, cookies are only
  /// read when the user generates — the signed-in browser renews
  /// its own session while it is used.
  static Future<bool> loadAutoRenew() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoRenew) ?? true;
  }

  static Future<void> saveAutoRenew(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoRenew, value);
  }

  /// Cookie header per authUser index, e.g. {0: "SID=...; __Secure-1PSID=..."}
  static Future<Map<int, String>> loadCookiesByUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCookiesByUser);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(int.tryParse(k) ?? 0, v.toString()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveCookieForUser(
      int authUser, String cookieHeader) async {
    final all = await loadCookiesByUser();
    if (cookieHeader.trim().isEmpty) {
      all.remove(authUser);
    } else {
      all[authUser] = cookieHeader.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kCookiesByUser,
      jsonEncode(all.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  static Future<String?> cookieForUser(int authUser) async {
    final all = await loadCookiesByUser();
    return all[authUser];
  }

  static Future<void> clearAllCookies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCookiesByUser);
    await prefs.remove(_kManualCookie);
    await prefs.remove(_kActiveInfo);
    await prefs.remove(_kDiscovered);
  }

  static Future<void> saveManualCookie(String cookieHeader) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kManualCookie, cookieHeader.trim());
    // A pasted cookie belongs to the default account slot u/0.
    await saveCookieForUser(0, cookieHeader);
  }

  static Future<String> loadManualCookie() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kManualCookie) ?? '';
  }

  static Future<List<GeminiAccount>> loadDiscoveredAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDiscovered);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => GeminiAccount.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveDiscoveredAccounts(
      List<GeminiAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kDiscovered, jsonEncode(accounts.map((e) => e.toJson()).toList()));
  }

  static Future<String> loadAccountMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kAccountMode) ?? 'auto';
  }

  static Future<void> saveAccountMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccountMode, mode);
  }

  static Future<void> saveActiveInfo(GeminiSession s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kActiveInfo,
      jsonEncode({'authUser': s.authUser, 'email': s.email, 'bl': s.bl}),
    );
  }

  static Future<Map<String, dynamic>?> loadActiveInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kActiveInfo);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  /// Parses anything a user might paste into a cookie header:
  ///  - a raw "name=value; name2=value2" header,
  ///  - two bare values (__Secure-1PSID and __Secure-1PSIDTS) on lines,
  ///  - a Netscape cookies.txt export.
  /// Returns a normalised "name=value; ..." header, or '' if nothing usable.
  static String normalisePastedCookies(String input) {
    final text = input.trim();
    if (text.isEmpty) return '';
    final pairs = <String, String>{};

    void addPair(String name, String value) {
      name = name.trim();
      value = value.trim();
      if (name.isEmpty || value.isEmpty) return;
      if (name.contains(' ') || name.contains('\t')) return;
      pairs[name] = value;
    }

    final isNetscape = text.contains('\t') &&
        (text.contains('google.com') || text.contains('#HttpOnly_'));
    if (isNetscape) {
      for (final line in text.split('\n')) {
        final l = line.trim();
        if (l.isEmpty) continue;
        var clean = l;
        if (clean.startsWith('#HttpOnly_')) {
          clean = clean.substring('#HttpOnly_'.length);
        }
        if (clean.startsWith('#')) continue;
        final parts = clean.split('\t');
        if (parts.length >= 7) {
          addPair(parts[5], parts.sublist(6).join('\t'));
        }
      }
    } else if (text.contains('=')) {
      // Header-style or "name: value" lines or bare two-value paste.
      final flat = text.replaceAll('\n', ';');
      for (final chunk in flat.split(';')) {
        final eq = chunk.indexOf('=');
        if (eq > 0) {
          addPair(chunk.substring(0, eq), chunk.substring(eq + 1));
        }
      }
      if (pairs.isEmpty) {
        // Bare values only, one per line: assume 1PSID then 1PSIDTS.
        final lines = text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty && !e.contains(' '))
            .toList();
        if (lines.isNotEmpty) addPair('__Secure-1PSID', lines[0]);
        if (lines.length > 1) addPair('__Secure-1PSIDTS', lines[1]);
      }
    } else {
      final lines = text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.contains(' '))
          .toList();
      if (lines.isNotEmpty) addPair('__Secure-1PSID', lines[0]);
      if (lines.length > 1) addPair('__Secure-1PSIDTS', lines[1]);
    }

    if (pairs.isEmpty) return '';
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static bool cookieHeaderLooksLoggedIn(String header) {
    return header.contains('__Secure-1PSID=') ||
        header.contains('SID=') ||
        header.contains('__Secure-3PSID=');
  }

  /// Merges the cookies from a `Set-Cookie` response header into a
  /// stored "name=value; ..." cookie header and returns the result.
  ///
  /// This is the app's cookie-renewal mechanism: Google rotates
  /// __Secure-1PSIDTS (and refreshes other session cookies) by sending
  /// Set-Cookie on gemini.google.com responses. A real browser jar
  /// absorbs those automatically and the login effectively never ages;
  /// this app's jar does the same merge by hand, so a saved login
  /// stays alive as long as it is used. Cookies the server deletes
  /// (empty value / 1970 expiry) are removed from the jar.
  static String absorbSetCookies(String cookieHeader, String? setCookie) {
    if (setCookie == null || setCookie.trim().isEmpty) return cookieHeader;
    final jar = <String, String>{};
    for (final part in cookieHeader.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        jar[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
      }
    }
    // The http package folds multiple Set-Cookie headers into one
    // comma-joined string, and Expires attributes themselves contain
    // commas ("Expires=Wed, 21 Oct 2015 ..."). Split only on a comma
    // that is followed by a fresh "name=" token.
    final cookies =
        setCookie.split(RegExp(r",\s*(?=[A-Za-z0-9!#$%&'*+.^_`|~-]+=)"));
    for (final raw in cookies) {
      final firstPair = raw.split(';').first.trim();
      final eq = firstPair.indexOf('=');
      if (eq <= 0) continue;
      final name = firstPair.substring(0, eq).trim();
      final value = firstPair.substring(eq + 1).trim();
      final lowered = raw.toLowerCase();
      final isDeletion = value.isEmpty ||
          lowered.contains('expires=thu, 01 jan 1970') ||
          lowered.contains('max-age=0');
      if (isDeletion) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}
