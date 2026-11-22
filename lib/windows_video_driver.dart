// v153 — Windows animation driver: the desktop twin of the Android
// headless Gecko driver (GeckoBrowser.startVideoHeadless).
//
// Android runs the video driver as a WebExtension content script in
// an invisible GeckoSession. Windows has no extension host, so this
// driver runs the SAME logic (windows_video_driver_script.dart — the
// Android content.js driver with only its transport changed) in a
// headless Chrome / Edge / Brave window, driven over CDP:
//
//  * its own profile dir (chromium-profile-video, next to the app's
//    chromium-profile) — so it never fights the visible image-search
//    browser for the profile lock, and no window ever shows;
//  * the saved Gemini login is seeded into that profile with
//    Network.setCookie (the same jar the Android driver gets from
//    GeckoView via syncCookies) — no password, no sign-in window;
//  * the driver script is injected with
//    Page.addScriptToEvaluateOnNewDocument + Runtime.evaluate (the
//    same pair ChromiumBrowser uses for the picture overlay);
//  * jobs start via window.__ghsVideoStart(jobJson), events come
//    back through window.__ghsVideoTake() polled every second — the
//    same {q: [...]} shape GeckoBrowser.parseRequests already reads,
//    so the engine consumes Windows events exactly like Android's.
//  * cancel calls window.__ghsVideoCancel(jobId), then closes the
//    headless browser (a cancelled job must never start later).
//
// A job that starts returns true (v150 posted-semantics). A
// definitive startup failure (no Chromium installed, no saved
// login, the Gemini page never becoming ready, the script never
// installing) THROWS WindowsVideoDriverException with the reason —
// the engine's _startDriver catch then fails the job fast with that
// reason, instead of sitting out the 3-minute handover deadline
// for a job that can never start (there is no "queued, may connect
// later" state on Windows like Kotlin's waitingForPort).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cdp.dart';
import 'chromium_browser.dart';
import 'gecko_browser.dart';
import 'session_store.dart';
import 'windows_video_driver_script.dart';

class WindowsVideoDriverException implements Exception {
  final String message;
  WindowsVideoDriverException(this.message);
  @override
  String toString() => message;
}

class WindowsVideoDriver {
  WindowsVideoDriver._();

  static WindowsVideoDriver? _instance;
  static WindowsVideoDriver get instance =>
      _instance ??= WindowsVideoDriver._();

  /// The shipped desktop build is Windows; the CDP machinery also
  /// runs on Linux/macOS, but the driver profile + cookie seeding
  /// below are written for the Windows build only.
  static bool get supported => Platform.isWindows;

  final _requests = StreamController<GeckoBrowserRequest>.broadcast();
  Stream<GeckoBrowserRequest> get requests => _requests.stream;

  Process? _proc;
  CdpConnection? _cdp;
  String? _sessionId;
  Timer? _poll;
  bool _polling = false;
  bool _jobRunning = false;
  String _currentJobId = '';

  /// Pure: turns one `__ghsVideoTake()` return value into the
  /// engine's requests. Malformed payloads yield nothing, never a
  /// throw — a bad poll must not kill the driver.
  static List<GeckoBrowserRequest> parseOutbox(String? takeResult) {
    if (takeResult == null || takeResult.isEmpty) return const [];
    try {
      return GeckoBrowser.parseRequests(takeResult);
    } catch (_) {
      return const [];
    }
  }

  /// Pure: splits a saved `Cookie` header (`a=b; c=d`) into
  /// name/value pairs for Network.setCookie. Values keep everything
  /// after the FIRST '=' (base64-ish values contain '=').
  static List<({String name, String value})> parseCookieHeader(
      String header) {
    final out = <({String name, String value})>[];
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out.add((name: name, value: value));
    }
    return out;
  }

  /// The driver's own Chrome profile (never the visible browser's
  /// chromium-profile — two Chrome processes cannot share one).
  static Future<String> driverProfileDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}chromium-profile-video');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  static String? _readWsUrl(String profileDir) {
    final f =
        File('$profileDir${Platform.pathSeparator}DevToolsActivePort');
    if (!f.existsSync()) return null;
    try {
      final lines = f
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length < 2) return null;
      final port = int.tryParse(lines[0]);
      if (port == null || port <= 0) return null;
      return 'ws://127.0.0.1:$port${lines[1]}';
    } catch (_) {
      return null;
    }
  }

  /// Starts the headless driver on [prompt]/[modelId] and returns
  /// true once the job is running in the Gemini page. The finished
  /// video / error arrives on [requests] as `video_ready` /
  /// `video_error`, exactly like the Android driver.
  Future<bool> startVideoHeadless(
      String prompt, String modelId, String jobId) async {
    if (!supported) {
      throw WindowsVideoDriverException(
          'Video generation-er Windows driver sudhu Windows build-e chole.');
    }
    if (_jobRunning) return false;
    final exe = ChromiumBrowser.findExecutable();
    if (exe == null) {
      throw WindowsVideoDriverException('Chrome / Edge / Brave pai nai — '
          'Windows-e video banate Chrome, Edge ba Brave install koro, '
          'tarpor abar try koro.');
    }
    // The signed-in slot: the same account the Login dropdown
    // picked (v144) — the driver seeds THAT slot's jar.
    final info = await SessionStore.loadActiveInfo();
    final slot = (info?['authUser'] as num?)?.toInt() ?? 0;
    final cookieHeader = await SessionStore.cookieForUser(slot) ?? '';
    if (!SessionStore.cookieHeaderLooksLoggedIn(cookieHeader)) {
      throw WindowsVideoDriverException('Gemini-te sign in kora nei — '
          'age Login tab theke Gemini-te sign in koro, tarpor Generate chapo.');
    }
    _currentJobId = jobId;
    try {
      await _connectOrLaunch(exe);
      final sid = await _openGeminiTab(slot, cookieHeader);
      _sessionId = sid;
      // The driver script, installed before the job starts.
      final installed = await _eval(
          'typeof window.__ghsVideoStart === "function" ? "ok" : "missing"',
          expectOk: true);
      if (installed == null) {
        throw WindowsVideoDriverException('Driver script page-e bosheni — '
            'Gemini page load hoyni hote pare, abar try koro.');
      }
      final started = await _eval(
          'window.__ghsVideoStart(${jsonEncode(jsonEncode({
                'type': 'video',
                'prompt': prompt,
                'model': modelId,
                'jobId': jobId,
              }))})',
          expectOk: false);
      if (started != 'ok') {
        throw WindowsVideoDriverException(
            'Driver-e job dite parlam na — page-e script bosheni.');
      }
      _jobRunning = true;
      _poll = Timer.periodic(
          const Duration(seconds: 1), (_) => _pollOutbox());
      return true;
    } catch (e) {
      await close();
      if (e is WindowsVideoDriverException) rethrow;
      throw WindowsVideoDriverException('Windows driver start hoyni: $e');
    }
  }

  /// Drops the running job (v151 cancel chain): tells the in-page
  /// driver to stop, then closes the headless browser so the job
  /// can never start later. Best effort; never throws.
  Future<void> cancelVideo(String jobId) async {
    try {
      if (_sessionId != null && _jobRunning) {
        await _cdp?.send('Runtime.evaluate', params: {
          'expression': 'window.__ghsVideoCancel && '
              'window.__ghsVideoCancel(${jsonEncode(jobId)})',
          'silent': true,
        }, sessionId: _sessionId, timeout: const Duration(seconds: 5));
      }
    } catch (_) {}
    await close();
  }

  /// Closes the headless browser (and the poll timer). Safe to call
  /// twice or with nothing running.
  Future<void> close() async {
    _jobRunning = false;
    _currentJobId = '';
    _poll?.cancel();
    _poll = null;
    _sessionId = null;
    final cdp = _cdp;
    _cdp = null;
    final proc = _proc;
    _proc = null;
    try {
      await cdp?.send('Browser.close',
          timeout: const Duration(seconds: 5));
    } catch (_) {}
    try {
      await cdp?.close();
    } catch (_) {}
    try {
      if (proc != null) {
        final exited = await proc.exitCode
            .timeout(const Duration(seconds: 5), onTimeout: () {
          try {
            proc.kill();
          } catch (_) {}
          return -1;
        });
        if (exited == -1) {
          try {
            proc.kill();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ internals

  /// Re-attaches to a driver browser left over from an earlier run
  /// (same profile), or launches a fresh headless one.
  Future<void> _connectOrLaunch(String exe) async {
    final profile = await driverProfileDir();
    final existing = _readWsUrl(profile);
    if (existing != null) {
      try {
        final cdp = await CdpConnection.connect(existing,
            timeout: const Duration(seconds: 3));
        await cdp.send('Browser.getVersion');
        _cdp = cdp;
        _proc = null;
        return;
      } catch (_) {
        _cdp = null;
      }
    }
    try {
      final f =
          File('$profile${Platform.pathSeparator}DevToolsActivePort');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    final proc = await Process.start(exe, [
      '--remote-debugging-port=0',
      '--user-data-dir=$profile',
      '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=Translate,ChromeWhatsNewUI',
      'about:blank',
    ], mode: ProcessStartMode.detached);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    var exited = false;
    proc.exitCode.then((_) => exited = true);
    String? ws;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline) && !exited) {
      await Future.delayed(const Duration(milliseconds: 250));
      ws = _readWsUrl(profile);
      if (ws != null) break;
    }
    if (ws == null) {
      try {
        proc.kill();
      } catch (_) {}
      throw WindowsVideoDriverException(
          'Headless Chrome start hoyni — browser profile busy hote pare. '
          'Chrome-er shob window bondho kore abar try koro.');
    }
    CdpConnection? cdp;
    Object? lastErr;
    for (var i = 0; i < 12 && cdp == null; i++) {
      try {
        cdp = await CdpConnection.connect(ws);
      } catch (e) {
        lastErr = e;
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    if (cdp == null) {
      try {
        proc.kill();
      } catch (_) {}
      throw WindowsVideoDriverException(
          'Headless Chrome-er sathe connect hoyni: $lastErr');
    }
    _cdp = cdp;
    _proc = proc;
  }

  /// Opens the Gemini tab on the signed-in slot: seeds the saved
  /// cookies first (the headless profile starts empty), navigates,
  /// waits for the page, then injects the driver script. Returns
  /// the CDP session id of the tab.
  Future<String> _openGeminiTab(int slot, String cookieHeader) async {
    final cdp = _cdp!;
    final t = await cdp.send('Target.createTarget',
        params: {'url': 'about:blank', 'background': true});
    final targetId = t['targetId'] as String?;
    if (targetId == null) {
      throw WindowsVideoDriverException(
          'Headless browser-e tab khulte parlam na.');
    }
    final a = await cdp.send('Target.attachToTarget',
        params: {'targetId': targetId, 'flatten': true});
    final sid = a['sessionId'] as String?;
    if (sid == null) {
      throw WindowsVideoDriverException(
          'Headless browser-er tab-e attach hoyni.');
    }
    // Headless Chrome announces itself as "HeadlessChrome" — say
    // plain Chrome instead (same trick the cookie harvest uses).
    try {
      final v = await cdp.send('Browser.getVersion');
      final ua = (v['userAgent'] ?? '')
          .toString()
          .replaceAll('HeadlessChrome', 'Chrome');
      if (ua.isNotEmpty) {
        await cdp.send('Emulation.setUserAgentOverride',
            params: {'userAgent': ua}, sessionId: sid);
      }
    } catch (_) {}
    await cdp.send('Page.enable', sessionId: sid);
    // Seed the saved login into the empty headless profile, so the
    // Gemini page opens already signed in (no sign-in window).
    try {
      await cdp.send('Network.enable', sessionId: sid);
      for (final c in parseCookieHeader(cookieHeader)) {
        try {
          await cdp.send('Network.setCookie', params: {
            'name': c.name,
            'value': c.value,
            'domain': '.google.com',
            'path': '/',
            'secure': true,
          }, sessionId: sid, timeout: const Duration(seconds: 5));
        } catch (_) {}
      }
    } catch (_) {}
    // Install the driver before the page loads, so it is present
    // from the first paint (a second Runtime.evaluate below covers
    // a page that was already loaded).
    try {
      await cdp.send('Page.addScriptToEvaluateOnNewDocument',
          params: {'source': windowsVideoDriverScript}, sessionId: sid);
    } catch (_) {}
    final url =
        'https://gemini.google.com/u/$slot/app?authuser=$slot';
    await cdp.send('Page.navigate', params: {'url': url}, sessionId: sid);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var loaded = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final r = await cdp.send('Runtime.evaluate',
            params: {'expression': 'document.readyState'},
            sessionId: sid,
            timeout: const Duration(seconds: 5));
        if ((r['result']?['value'] ?? '').toString() == 'complete') {
          loaded = true;
          break;
        }
      } catch (_) {}
    }
    if (!loaded) {
      throw WindowsVideoDriverException('Gemini page khulche na — '
          'net / login check koro, tarpor abar try koro.');
    }
    await Future.delayed(const Duration(seconds: 2));
    try {
      await cdp.send('Runtime.evaluate',
          params: {'expression': windowsVideoDriverScript},
          sessionId: sid,
          timeout: const Duration(seconds: 10));
    } catch (_) {}
    return sid;
  }

  /// Runs one Runtime.evaluate on the Gemini tab and returns the
  /// result's string value (null when the call failed). When
  /// [expectOk] is true the value must be the string 'ok'.
  Future<String?> _eval(String expression, {required bool expectOk}) async {
    final cdp = _cdp;
    final sid = _sessionId;
    if (cdp == null || sid == null) return null;
    try {
      final r = await cdp.send('Runtime.evaluate', params: {
        'expression': expression,
        'returnByValue': true,
        'silent': true,
      }, sessionId: sid, timeout: const Duration(seconds: 10));
      final v = (r['result'] as Map?)?['value'];
      final s = v?.toString();
      if (expectOk) return s == 'ok' ? s : null;
      return s;
    } catch (_) {
      return null;
    }
  }

  /// One poll round: takes the driver's outbox and forwards every
  /// event to the engine. A terminal event (video_ready /
  /// video_error) closes the headless browser shortly after — the
  /// page has nothing more to give (the MP4 bytes ride in the
  /// event itself).
  Future<void> _pollOutbox() async {
    if (_polling) return;
    _polling = true;
    try {
      final raw = await _eval(
          'typeof window.__ghsVideoTake === "function" '
          '? window.__ghsVideoTake() : "{\\"q\\":[]}"',
          expectOk: false);
      final reqs = parseOutbox(raw);
      var terminal = false;
      for (final req in reqs) {
        _requests.add(req);
        if (req.action == 'video_ready' || req.action == 'video_error') {
          terminal = true;
        }
      }
      if (terminal) {
        final jobId = _currentJobId;
        _jobRunning = false;
        Future.delayed(const Duration(seconds: 1), () {
          if (_currentJobId == jobId || _currentJobId.isEmpty) close();
        });
      }
    } finally {
      _polling = false;
    }
  }
}
