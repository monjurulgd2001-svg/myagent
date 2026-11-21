// Background generation keep-alive (v33, user order: generation
// must continue "screen off & onno apps a gelo tao background a
// cole" — with the screen off and other apps in front).
//
// On Android a native foreground service (GenerationService.kt)
// plus a partial wake lock hold the process while any long
// generation is in flight; Android shows a small ongoing
// notification while it runs. Reference-counted so nested users
// (designer batch loop -> engine generateSet -> stage work, or a
// basket loop -> per-picture prompts) share one service period.
// No-op on every other platform.
//
// v72 fix (user report: background generation does not work on
// his TECNO): the v33 battery-exemption ask fired ONCE per
// install and the "asked" flag was set BEFORE the ask — so if he
// denied it, or HiOS blocked the intent, it never asked again
// and Doze throttled the network the moment the screen locked.
// Now the exemption is checked on every first acquire per
// session and the UI shows a fix dialog + a banner while the
// phone is not exempt; HiOS also needs Auto-start + Phone
// Master background allow, which the stock exemption does not
// cover (see getManufacturer / openAppSettings).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ForegroundKeepAlive {
  static const MethodChannel _channel =
      MethodChannel('com.geminihd.studio/foreground');
  static int _count = 0;
  static bool _exemptionCheckedThisSession = false;

  /// Master switch (v77, in-app "Background generation" toggle,
  /// persisted in SharedPreferences, default ON). When OFF, acquire
  /// is a no-op everywhere — generation runs foreground-only and
  /// the exemption dialog never fires. The user asked for one
  /// button in the app instead of hunting through Settings; this
  /// is the single choke point that makes the button real.
  static bool enabled = true;

  /// Tests run on a host OS, so Platform.isAndroid is false
  /// there — flip this in a test to exercise the channel calls.
  @visibleForTesting
  static bool debugForceAndroid = false;

  static bool get _android {
    if (debugForceAndroid) return true;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Start (or extend) a keep-alive period with the given
  /// notification label. Pair every acquire with a release.
  /// No-op when the in-app background mode is OFF (v77).
  static Future<void> acquire(String label) async {
    if (!_android || !enabled) return;
    _count++;
    try {
      await _channel.invokeMethod('start', {'label': label});
    } catch (_) {}
    if (_count == 1) _maybeAskBatteryExemption();
  }

  /// End one keep-alive period; the service stops when the last
  /// holder releases. An unmatched release (nothing held) is a
  /// no-op — it must never stop a service another holder started.
  static Future<void> release() async {
    if (!_android) return;
    if (_count == 0) return;
    _count--;
    if (_count != 0) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Post a one-off completion notification (Android only) — the
  /// overnight queue uses it when it finishes while the user is
  /// away from the phone (v47).
  static Future<void> notifyDone(String title, String body) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('notifyDone', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  /// Is the app exempt from battery optimisation right now?
  /// Without the exemption Doze throttles the network when the
  /// screen locks, and the Gemini stream stalls.
  static Future<bool> isBatteryExempt() async {
    if (!_android) return true;
    try {
      return await _channel.invokeMethod<bool>('isBatteryExempt') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Open the system battery-exemption screen for this app.
  /// Returns false when the phone blocks that intent (some OEM
  /// skins do) — the caller should then offer the app settings
  /// page instead.
  static Future<bool> requestBatteryExemption() async {
    if (!_android) return false;
    _exemptionCheckedThisSession = true;
    try {
      return await _channel
              .invokeMethod<bool>('requestBatteryExemption') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Phone maker (TECNO / Infinix / itel / samsung ...) — the
  /// background-killer steps differ per maker.
  static Future<String> getManufacturer() async {
    if (!_android) return '';
    try {
      return await _channel.invokeMethod<String>('getManufacturer') ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// Open this app's system settings page (Auto-start lives
  /// here on HiOS/Transsion phones).
  static Future<bool> openAppSettings() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Open the Transsion Phone Master app, where HiOS keeps
  /// Auto-start management (v77). Returns false when Phone Master
  /// is not installed — the native side then opens the app
  /// settings page instead.
  static Future<bool> openPhoneMaster() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('openPhoneMaster') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Backstop, once per session on the first acquire: if the
  /// phone may kill the app, fire the system exemption screen.
  /// The in-app dialog (main.dart) is the main path — this only
  /// covers generations started from paths without the dialog.
  /// v72: no persisted "asked" flag any more — v33 set it before
  /// the ask, so a single deny/block silenced it forever.
  static Future<void> _maybeAskBatteryExemption() async {
    if (_exemptionCheckedThisSession) return;
    _exemptionCheckedThisSession = true;
    try {
      if (await isBatteryExempt()) return;
      await requestBatteryExemption();
    } catch (_) {}
  }
}
