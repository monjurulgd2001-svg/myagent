// v153 — Windows silent session renewal.
//
// _silentRenew (startup + every 15 min) renewed through the
// built-in browser FIRST on Android (GeckoSignIn.refreshSessionPage,
// v122) and fell back to the Dart HTTP fetch — but on Windows the
// browser half returned null (Gecko-only), so renewal rode the Dart
// fetch alone, which Google bot-checks (live 2026-11-21). Windows
// HAS the browser half: ChromiumStudioBrowser.harvestHeader visits
// Gemini in the app's own profile headlessly, Chrome renews the
// session itself, and the fresh jar comes back. This refreshes the
// saved jar for [slot] from the profile; the caller then runs its
// normal Dart scan/getSession against the fresh jar. Returns true
// when a logged-in jar was harvested and saved, false otherwise
// (never throws — a failed silent renewal must stay silent).
import 'package:flutter/foundation.dart';

import 'chromium_studio_browser.dart';
import 'session_store.dart';

class WindowsSessionRenewal {
  WindowsSessionRenewal._();

  /// Harvests the profile's fresh Google cookies and saves them
  /// to [slot]'s jar. [platformOverride] exists for tests (the
  /// host running flutter test is not Windows).
  static Future<bool> refreshSavedJar({
    int slot = 0,
    TargetPlatform? platformOverride,
  }) async {
    final platform = platformOverride ?? defaultTargetPlatform;
    if (platform != TargetPlatform.windows) return false;
    try {
      final header = await ChromiumStudioBrowser.harvestHeader();
      if (!SessionStore.cookieHeaderLooksLoggedIn(header)) return false;
      await SessionStore.saveCookieForUser(slot, header);
      return true;
    } catch (_) {
      return false;
    }
  }
}
