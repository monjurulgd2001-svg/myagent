// External browser launching for the Image Search screen.
//
// Browsing there happens in a DEDICATED external browser process —
// never in an embedded frame inside this app:
//  * Android: an ACTION_VIEW intent aimed at Chrome first, then
//    Firefox, then the system default browser (Kotlin channel in
//    MainActivity).
//  * Windows: the installed Chrome / Firefox / Edge executable,
//    falling back to the default browser via the shell.
//
// The app cannot see inside that browser (no page access, no
// cookies — the OS keeps apps apart). Images come back through the
// bridge on the search panel: the user copies an image link in the
// browser and pastes it into the app, or picks from the device
// gallery; prompts are generated from those, in-app.
import 'dart:io';

import 'package:flutter/services.dart';

class ExternalBrowser {
  static const MethodChannel _channel =
      MethodChannel('com.geminihd.studio/browser');

  /// Open [url] in the external browser. Returns false when no
  /// browser could be launched.
  static Future<bool> open(String url) async {
    if (url.isEmpty) return false;
    if (Platform.isWindows) return _openWindows(url);
    try {
      final ok =
          await _channel.invokeMethod<bool>('openExternal', {'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _openWindows(String url) async {
    final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = <String>[
      '$pf\\Google\\Chrome\\Application\\chrome.exe',
      '$local\\Google\\Chrome\\Application\\chrome.exe',
      '$pf\\Mozilla Firefox\\firefox.exe',
      '$pf86\\Mozilla Firefox\\firefox.exe',
      '$pf86\\Microsoft\\Edge\\Application\\msedge.exe',
      '$pf\\Microsoft\\Edge\\Application\\msedge.exe',
    ];
    for (final exe in candidates) {
      try {
        if (await File(exe).exists()) {
          await Process.start(exe, [url], mode: ProcessStartMode.detached);
          return true;
        }
      } catch (_) {}
    }
    try {
      await Process.start('cmd', ['/c', 'start', '', url],
          mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }
}
