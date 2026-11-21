import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'cdp.dart';
import 'overlay_script.dart';

/// One picture the user asked for from a web page.
class WebImageRef {
  final String src;
  final String alt;
  final int width;
  final int height;

  /// Sharpest version of the picture (largest srcset entry), may be ''.
  final String hi;

  /// Capture requests: `kind`, `rect` (document CSS px), `frac` (share of
  /// the visible viewport) and `dpr`.
  final Map<String, dynamic> meta;
  const WebImageRef(this.src, this.alt, this.width, this.height,
      {this.hi = '', this.meta = const {}});

  static WebImageRef? fromJson(dynamic i) {
    if (i is! Map) return null;
    final src = (i['src'] ?? '').toString();
    if (src.isEmpty) return null;
    final meta = <String, dynamic>{};
    for (final k in const ['kind', 'rect', 'frac', 'dpr']) {
      if (i[k] != null) meta[k] = i[k];
    }
    return WebImageRef(
      src,
      (i['alt'] ?? '').toString(),
      (i['w'] as num?)?.toInt() ?? 0,
      (i['h'] as num?)?.toInt() ?? 0,
      hi: (i['hi'] ?? '').toString(),
      meta: meta,
    );
  }
}

/// A request coming from the in-page overlay ("Prompt" button or the
/// "Generate prompts" dock for ticked pictures).
class WebImageRequest {
  final String action; // single | batch
  final List<WebImageRef> images;
  final String pageUrl;
  final String pageTitle;
  final String sessionId; // CDP session of the tab it came from
  const WebImageRequest(
      this.action, this.images, this.pageUrl, this.pageTitle, this.sessionId);
}

/// Raw picture bytes plus their detected MIME type.
class FetchedImage {
  final Uint8List bytes;
  final String mimeType;
  const FetchedImage(this.bytes, this.mimeType);
}

/// Drives a **real, separate Chromium window** (Chrome / Edge / Brave /
/// Chromium already installed on the PC) through the Chrome DevTools
/// Protocol. No WebView is embedded in the app: browsing stays 100 %
/// native Chromium (GPU, extensions, password manager, smooth scrolling),
/// and the app only injects a small overlay into each tab.
///
/// The browser runs with its own profile under the app-support folder, so
/// signing in to gemini.google.com there once is enough for the live
/// cookie path.
class ChromiumBrowser {
  ChromiumBrowser._(this._cdp, this.executable, this.profileDir) {
    _evSub = _cdp.events.listen(_onEvent);
    _cdp.done.then((_) => _handleClosed());
  }

  final CdpConnection _cdp;
  final String executable;
  final String profileDir;
  late final StreamSubscription _evSub;

  final _requests = StreamController<WebImageRequest>.broadcast();
  final _changes = StreamController<void>.broadcast();

  /// targetId -> sessionId of every attached tab.
  final Map<String, String> _sessions = {};
  final Set<String> _attaching = {};
  final Map<String, String> _tabUrls = {};
  bool _closed = false;
  Timer? _poll;
  bool _polling = false;

  /// App-side tick selection, mirrored into every tab.
  List<String> _basket = const [];
  int _basketVersion = 0;
  int _basketPages = 0;

  /// Replaces the basket shown in every tab (pushed on the next poll).
  void setBasket(List<String> srcs, int pages) {
    _basket = List.unmodifiable(srcs);
    _basketPages = pages;
    _basketVersion++;
  }

  Stream<WebImageRequest> get requests => _requests.stream;
  Stream<void> get changes => _changes.stream;
  String get displayName {
    final n = executable.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (n.contains('msedge')) return 'Microsoft Edge';
    if (n.contains('brave')) return 'Brave';
    if (executable.toLowerCase().contains('chromium')) return 'Chromium';
    return 'Google Chrome';
  }

  bool get isConnected => !_closed && _cdp.isOpen;
  int get tabCount => _sessions.length;

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  // ------------------------------------------------------------ discovery
  /// Finds an installed Chromium-based browser. [preferred] (a full path
  /// typed in the app) wins when it exists.
  static String? findExecutable([String? preferred]) {
    if (preferred != null &&
        preferred.trim().isNotEmpty &&
        File(preferred.trim()).existsSync()) {
      return preferred.trim();
    }
    final env = Platform.environment;
    final candidates = <String>[];
    if (Platform.isWindows) {
      final roots = [
        env['ProgramFiles'],
        env['ProgramFiles(x86)'],
        env['LOCALAPPDATA'],
        env['ProgramW6432'],
      ].whereType<String>().where((s) => s.isNotEmpty);
      for (final r in roots) {
        candidates.addAll([
          '$r\\Google\\Chrome\\Application\\chrome.exe',
          '$r\\Chromium\\Application\\chrome.exe',
          '$r\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
          '$r\\Microsoft\\Edge\\Application\\msedge.exe',
        ]);
      }
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      ]);
    } else {
      final path = (env['PATH'] ?? '/usr/bin:/usr/local/bin').split(':');
      for (final name in const [
        'google-chrome',
        'google-chrome-stable',
        'chromium',
        'chromium-browser',
        'brave-browser',
        'microsoft-edge',
      ]) {
        for (final dir in path) {
          candidates.add('$dir/$name');
        }
      }
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static Future<String> _profileDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
        '${base.path}${Platform.pathSeparator}chromium-profile');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// Reads `DevToolsActivePort` (written by Chromium when started with
  /// `--remote-debugging-port=0`) and returns the browser WebSocket URL.
  static String? _readWsUrl(String profileDir) {
    final f = File('$profileDir${Platform.pathSeparator}DevToolsActivePort');
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

  /// Starts the same profile as a completely normal browser (no DevTools
  /// port at all - Google refuses sign-in in controlled browsers) for
  /// Google sign-in. Completes when the window is closed. With [autoClose]
  /// (Windows) the window title is watched and, as soon as the Gemini app
  /// has opened after sign-in, the window is closed gracefully (so Chrome
  /// writes its cookies) - the user does not have to close it.
  static Future<int> launchPlain({
    String? preferredExecutable,
    String url = 'https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp',
    bool autoClose = true,
    void Function(String status)? onStatus,
  }) async {
    final exe = findExecutable(preferredExecutable);
    if (exe == null) {
      throw CdpException('No Chromium browser found.');
    }
    final profile = await _profileDir();
    try {
      final f = File('$profile${Platform.pathSeparator}DevToolsActivePort');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    final p = await Process.start(exe, [
      '--user-data-dir=$profile',
      '--no-first-run',
      '--no-default-browser-check',
      url,
    ]);
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    if (!autoClose || !Platform.isWindows) return p.exitCode;

    var exited = false;
    int code = 0;
    p.exitCode.then((c) {
      exited = true;
      code = c;
    });
    var seenSignIn = false;
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (!exited && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 700));
      if (exited) break;
      final title = await windowTitle(p.pid);
      if (title == null) continue;
      if (!isGeminiAppTitle(title)) {
        if (title.isNotEmpty) seenSignIn = true;
        continue;
      }
      // Gemini opened. Only right away when it came after the sign-in
      // page; let it settle a moment so the final cookies are set.
      onStatus?.call('Signed in - reading the session...');
      await Future.delayed(Duration(milliseconds: seenSignIn ? 1500 : 2500));
      await _closeGracefully(p.pid);
      break;
    }
    return p.exitCode.timeout(const Duration(seconds: 12), onTimeout: () {
      p.kill();
      return code;
    });
  }

  /// "Google Gemini - Google Chrome", "Google Gemini - Personal - Microsoft
  /// Edge", "Gemini - Brave"... but not the sign-in page.
  static bool isGeminiAppTitle(String title) {
    final t = title.trim().toLowerCase();
    if (!(t.startsWith('google gemini') || t.startsWith('gemini'))) {
      return false;
    }
    return !t.contains('sign in') && !t.contains('accounts');
  }

  /// Window title of a process (Windows), null when unknown.
  static Future<String?> windowTitle(int pid) async {
    try {
      final r = await Process.run('tasklist',
          ['/v', '/fo', 'csv', '/nh', '/fi', 'PID eq $pid'],
          runInShell: false);
      final line = r.stdout.toString().trim();
      if (!line.startsWith('"')) return null;
      final cells = RegExp(r'"((?:[^"]|"")*)"')
          .allMatches(line)
          .map((m) => m.group(1)!.replaceAll('""', '"'))
          .toList();
      if (cells.isEmpty) return null;
      final t = cells.last;
      return t == 'N/A' ? '' : t;
    } catch (_) {
      return null;
    }
  }

  /// WM_CLOSE to the browser windows (like clicking X): Chrome saves its
  /// cookies and exits normally.
  static Future<void> _closeGracefully(int pid) async {
    try {
      await Process.run('taskkill', ['/PID', '$pid']);
    } catch (_) {}
  }

  /// Opens (or re-attaches to) the controlled Chromium window and loads
  /// [startUrl].
  static Future<ChromiumBrowser> launch({
    String? preferredExecutable,
    String startUrl = 'https://www.google.com/',
    String? profileDir,
    List<String> extraArgs = const [],
  }) async {
    if (!supported) {
      throw CdpException('The Chromium browser feature needs the desktop '
          '(Windows) build of the app.');
    }
    final exe = findExecutable(preferredExecutable);
    if (exe == null) {
      throw CdpException('No Chromium browser found. Install Google Chrome, '
          'Chromium, Brave or Microsoft Edge, or enter the full path to '
          'chrome.exe in "Browser path".');
    }
    final profile = profileDir ?? await _profileDir();

    // 1) A window from an earlier run may still be open: re-attach.
    final existing = _readWsUrl(profile);
    if (existing != null) {
      try {
        final cdp = await CdpConnection.connect(existing,
            timeout: const Duration(seconds: 3));
        final b = ChromiumBrowser._(cdp, exe, profile);
        await b._start();
        await b.openTab(startUrl);
        return b;
      } catch (_) {}
    }

    // 2) Fresh start.
    try {
      final f = File('$profile${Platform.pathSeparator}DevToolsActivePort');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}

    await Process.start(
      exe,
      [
        '--remote-debugging-port=0',
        '--user-data-dir=$profile',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-features=Translate,ChromeWhatsNewUI',
        ...extraArgs,
        '--new-window',
        startUrl,
      ],
      mode: ProcessStartMode.detached,
    );

    String? ws;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 250));
      ws = _readWsUrl(profile);
      if (ws != null) break;
    }
    if (ws == null) {
      throw CdpException('Chromium started but did not open its DevTools '
          'port. Close every window of that browser profile and try again.');
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
      throw CdpException('Could not connect to Chromium: $lastErr');
    }
    final b = ChromiumBrowser._(cdp, exe, profile);
    await b._start();
    return b;
  }

  // ------------------------------------------------------------- sessions
  /// Google sign-in / account pages are never touched: no session, no
  /// script, so Google sees a completely normal Chrome there.
  static bool _isProtected(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'accounts.google.com' ||
        host.endsWith('.accounts.google.com') ||
        host == 'myaccount.google.com' ||
        host == 'gemini.google.com' ||
        host == 'accounts.youtube.com' ||
        host == 'login.microsoftonline.com' ||
        host == 'appleid.apple.com';
  }

  Future<void> _start() async {
    _poll = Timer.periodic(
        const Duration(milliseconds: 500), (_) => _pollOutboxes());
    await _cdp.send('Target.setDiscoverTargets', params: {'discover': true});
    final res = await _cdp.send('Target.getTargets');
    for (final t in (res['targetInfos'] as List? ?? const [])) {
      if (t is Map) _maybeAttach(t.cast<String, dynamic>());
    }
  }

  void _maybeAttach(Map<String, dynamic> info) {
    if (info['type'] != 'page') return;
    final id = info['targetId'] as String?;
    if (id == null) return;
    final url = (info['url'] ?? '').toString();
    _tabUrls[id] = url;
    if (_isProtected(url)) {
      final sid = _sessions.remove(id);
      if (sid != null) {
        _cdp
            .send('Target.detachFromTarget', params: {'sessionId': sid})
            .catchError((_) => <String, dynamic>{});
        _changes.add(null);
      }
      return;
    }
    if (_sessions.containsKey(id) || _attaching.contains(id)) return;
    _attaching.add(id);
    _attach(id).whenComplete(() => _attaching.remove(id));
  }

  Future<void> _attach(String targetId) async {
    try {
      final r = await _cdp.send('Target.attachToTarget',
          params: {'targetId': targetId, 'flatten': true});
      final sid = r['sessionId'] as String?;
      if (sid == null) return;
      if (_isProtected(_tabUrls[targetId] ?? '')) {
        await _cdp.send('Target.detachFromTarget', params: {'sessionId': sid});
        return;
      }
      _sessions[targetId] = sid;
      // Deliberately NO Runtime.enable / Runtime.addBinding (automation
      // fingerprints); the overlay is polled instead.
      await _cdp.send('Page.enable', sessionId: sid);
      await _cdp.send('Page.addScriptToEvaluateOnNewDocument',
          params: {'source': overlayScript}, sessionId: sid);
      // Tab that is already showing a page: inject right away.
      await _cdp.send('Runtime.evaluate',
          params: {'expression': overlayScript}, sessionId: sid);
      _changes.add(null);
    } catch (_) {
      // chrome:// pages, closing tabs, etc. – ignore.
    }
  }

  void _onEvent(CdpEvent e) {
    switch (e.method) {
      case 'Target.targetCreated':
      case 'Target.targetInfoChanged':
        final info = (e.params['targetInfo'] as Map?)?.cast<String, dynamic>();
        if (info != null) _maybeAttach(info);
        break;
      case 'Target.targetDestroyed':
        final id = e.params['targetId'] as String?;
        if (id != null) {
          _sessions.remove(id);
          _tabUrls.remove(id);
          _changes.add(null);
        }
        break;
      case 'Target.detachedFromTarget':
        final sid = e.params['sessionId'] as String?;
        _sessions.removeWhere((_, v) => v == sid);
        _changes.add(null);
        break;
    }
  }

  /// Collects the overlay requests of every attached tab.
  Future<void> _pollOutboxes() async {
    if (_polling || !isConnected || _sessions.isEmpty) return;
    _polling = true;
    try {
      for (final sid in _sessions.values.toList()) {
        try {
          final r = await _cdp.send('Runtime.evaluate',
              params: {
                'expression':
                    'typeof window.__aisTake === "function" ? window.__aisTake() : "[]"',
                'returnByValue': true,
                'silent': true,
              },
              sessionId: sid,
              timeout: const Duration(seconds: 3));
          final v = (r['result'] as Map?)?['value'];
          if (v is! String || v == '[]') continue;
          final box = jsonDecode(v);
          if (box is! Map) continue;
          for (final payload in (box['q'] as List? ?? const [])) {
            _handleBinding(payload.toString(), sid);
          }
          // Requests above may have changed the basket: push it when the
          // tab shows an older version (new page, other tab, other site).
          if (box['v'] != _basketVersion) {
            final arg = '${jsonEncode(_basket)}, $_basketVersion, $_basketPages';
            await _cdp.send('Runtime.evaluate',
                params: {
                  'expression':
                      'window.__aisBasket && window.__aisBasket($arg)',
                  'silent': true,
                },
                sessionId: sid,
                timeout: const Duration(seconds: 3));
          }
        } catch (_) {}
      }
    } finally {
      _polling = false;
    }
  }

  void _handleBinding(String payload, String? sessionId) {
    try {
      final m = (jsonDecode(payload) as Map).cast<String, dynamic>();
      final imgs = <WebImageRef>[];
      for (final i in (m['images'] as List? ?? const [])) {
        final ref = WebImageRef.fromJson(i);
        if (ref != null) imgs.add(ref);
      }
      final action = (m['action'] ?? 'single').toString();
      if (imgs.isEmpty &&
          action != 'clear_basket' &&
          action != 'generate_basket') {
        return;
      }
      _requests.add(WebImageRequest(
        action,
        imgs,
        (m['page'] ?? '').toString(),
        (m['title'] ?? '').toString(),
        sessionId ?? '',
      ));
    } catch (_) {}
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _sessions.clear();
    _changes.add(null);
  }

  // -------------------------------------------------------------- actions
  /// Opens [url] in a new tab of the controlled window.
  Future<void> openTab(String url) async {
    await _cdp.send('Target.createTarget', params: {'url': url});
  }

  /// Pushes a status update to the overlay of the tab that asked.
  Future<void> notifyPage(String sessionId, String src, String state,
      [String message = '']) async {
    // Sent to every tab: the picture may now be visible in another tab
    // or the user may have navigated since ticking it.
    if (!isConnected) return;
    final arg = jsonEncode({'src': src, 'state': state, 'message': message});
    for (final sid in _sessions.values.toList()) {
      try {
        await _cdp.send('Runtime.evaluate',
            params: {
              'expression': 'window.__aisStatus && window.__aisStatus($arg)',
              'silent': true,
            },
            sessionId: sid,
            timeout: const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// Shows a short toast inside every attached tab's overlay.
  Future<void> toast(String msg) async {
    if (!isConnected) return;
    final arg = jsonEncode(msg);
    for (final sid in _sessions.values.toList()) {
      try {
        await _cdp.send('Runtime.evaluate',
            params: {
              'expression': 'window.__aisToast && window.__aisToast($arg)',
              'silent': true,
            },
            sessionId: sid,
            timeout: const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// Cookies of the controlled profile for google.com (the live Gemini
  /// web session when the user is signed in there).
  Future<List<Map<String, dynamic>>> googleCookies() async {
    final r = await _cdp.send('Storage.getCookies');
    return [
      for (final c in (r['cookies'] as List? ?? const []))
        if (c is Map && (c['domain'] ?? '').toString().contains('google.com'))
          c.cast<String, dynamic>()
    ];
  }

  /// Loads gemini.google.com in a background tab of this profile so
  /// Chrome itself renews the Google session (the signed-in account is
  /// reused - no password), then returns the fresh google.com cookies.
  /// Returns an empty list when the profile is not signed in.
  Future<List<Map<String, dynamic>>> refreshGoogleCookies({
    String url = 'https://gemini.google.com/app',
    Duration settle = const Duration(seconds: 2),
    bool visit = true,
  }) async {
    String? targetId;
    try {
      if (!visit) throw const _SkipVisit();
      final t = await _cdp.send('Target.createTarget',
          params: {'url': 'about:blank', 'background': true});
      targetId = t['targetId'] as String?;
      if (targetId != null) {
        final a = await _cdp.send('Target.attachToTarget',
            params: {'targetId': targetId, 'flatten': true});
        final sid = a['sessionId'] as String?;
        if (sid != null) {
          // Headless Chrome announces itself as "HeadlessChrome".
          try {
            final v = await _cdp.send('Browser.getVersion');
            final ua = (v['userAgent'] ?? '')
                .toString()
                .replaceAll('HeadlessChrome', 'Chrome');
            if (ua.isNotEmpty) {
              await _cdp.send('Emulation.setUserAgentOverride',
                  params: {'userAgent': ua}, sessionId: sid);
            }
          } catch (_) {}
          await _cdp.send('Page.navigate',
              params: {'url': url}, sessionId: sid);
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          var loaded = false;
          while (DateTime.now().isBefore(deadline)) {
            await Future.delayed(const Duration(milliseconds: 500));
            try {
              final r = await _cdp.send('Runtime.evaluate',
                  params: {'expression': 'document.readyState'},
                  sessionId: sid,
                  timeout: const Duration(seconds: 5));
              final st = (r['result']?['value'] ?? '').toString();
              if (st == 'complete') {
                loaded = true;
                break;
              }
            } catch (_) {}
          }
          if (loaded) await Future.delayed(settle);
        }
      }
    } catch (_) {
    } finally {
      if (targetId != null) {
        try {
          await _cdp.send('Target.closeTarget',
              params: {'targetId': targetId});
        } catch (_) {}
      }
    }
    final all = await googleCookies();
    final signedIn = all.any((c) =>
        c['name'] == '__Secure-1PSID' &&
        (c['value'] ?? '').toString().isNotEmpty);
    return signedIn ? all : const [];
  }

  /// Gets fresh Google cookies from the app's browser profile without
  /// showing a window: re-uses an open controlled window when there is
  /// one, otherwise starts the profile headless for a few seconds.
  static Future<List<Map<String, dynamic>>> harvestGoogleCookies({
    String? preferredExecutable,
    String? profileDir,
    bool headless = true,
    List<String> extraArgs = const [],
    bool visit = true,
  }) async {
    final exe = findExecutable(preferredExecutable);
    if (exe == null) {
      throw CdpException('No Chromium browser found (Chrome / Edge / '
          'Brave). Set "Browser path" in Image to Prompt options.');
    }
    final profile = profileDir ?? await _profileDir();
    final existing = _readWsUrl(profile);
    if (existing != null) {
      try {
        final cdp = await CdpConnection.connect(existing,
            timeout: const Duration(seconds: 3));
        final b = ChromiumBrowser._(cdp, exe, profile);
        try {
          return await b.refreshGoogleCookies(visit: visit);
        } finally {
          await b._evSub.cancel();
          await cdp.close();
        }
      } catch (_) {}
    }
    try {
      final f = File('$profile${Platform.pathSeparator}DevToolsActivePort');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    final proc = await Process.start(exe, [
      '--remote-debugging-port=0',
      '--user-data-dir=$profile',
      '--no-first-run',
      '--no-default-browser-check',
      if (headless) '--headless=new',
      if (!headless) '--window-position=-32000,-32000',
      ...extraArgs,
      'about:blank',
    ]);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    var exited = false;
    proc.exitCode.then((_) => exited = true);
    String? ws;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline) && !exited) {
      await Future.delayed(const Duration(milliseconds: 250));
      ws = _readWsUrl(profile);
      if (ws != null) break;
    }
    if (ws == null) {
      if (!exited) proc.kill();
      throw CdpException('The app browser profile is busy. Close the '
          'browser window that was opened for Google sign-in and try again.');
    }
    CdpConnection? cdp;
    for (var i = 0; i < 12 && cdp == null; i++) {
      try {
        cdp = await CdpConnection.connect(ws);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    if (cdp == null) {
      proc.kill();
      throw CdpException('Could not connect to the browser profile.');
    }
    final b = ChromiumBrowser._(cdp, exe, profile);
    try {
      return await b.refreshGoogleCookies(visit: visit);
    } finally {
      try {
        await cdp.send('Browser.close', timeout: const Duration(seconds: 5));
      } catch (_) {}
      await b._evSub.cancel();
      await cdp.close();
      await proc.exitCode
          .timeout(const Duration(seconds: 8), onTimeout: () {
        proc.kill();
        return -1;
      });
      try {
        final f = File('$profile${Platform.pathSeparator}DevToolsActivePort');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// Gets the picture bytes, trying (1) Chromium's own resource cache for
  /// the tab, (2) a direct download with the page as referrer and (3) a
  /// fetch() inside the page (blob: / cookie-protected images).
  Future<FetchedImage> fetchImage(String src,
      {String sessionId = '', String pageUrl = ''}) async {
    if (src.startsWith('data:')) {
      final comma = src.indexOf(',');
      if (comma > 0) {
        final meta = src.substring(5, comma);
        final data = src.substring(comma + 1);
        final bytes = meta.contains(';base64')
            ? base64Decode(data)
            : Uint8List.fromList(utf8.encode(Uri.decodeComponent(data)));
        return FetchedImage(Uint8List.fromList(bytes), meta.split(';').first);
      }
    }
    final live = sessionId.isNotEmpty &&
        isConnected &&
        _sessions.containsValue(sessionId);

    if (live && !src.startsWith('blob:')) {
      try {
        final tree = await _cdp.send('Page.getFrameTree',
            sessionId: sessionId, timeout: const Duration(seconds: 5));
        final ids = <String>[];
        void walk(dynamic node) {
          if (node is! Map) return;
          final f = node['frame'];
          if (f is Map && f['id'] != null) ids.add(f['id'].toString());
          for (final c in (node['childFrames'] as List? ?? const [])) {
            walk(c);
          }
        }

        walk(tree['frameTree']);
        for (final fid in ids) {
          try {
            final r = await _cdp.send('Page.getResourceContent',
                params: {'frameId': fid, 'url': src},
                sessionId: sessionId,
                timeout: const Duration(seconds: 10));
            final content = (r['content'] ?? '').toString();
            if (content.isEmpty) continue;
            final bytes = r['base64Encoded'] == true
                ? base64Decode(content)
                : Uint8List.fromList(utf8.encode(content));
            if (bytes.length > 64) {
              return FetchedImage(bytes, sniffMime(bytes));
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    if (!src.startsWith('blob:')) {
      try {
        return await fetchDirect(src, pageUrl);
      } catch (_) {}
    }

    if (live) {
      final expr = '(async (u) => { const r = await fetch(u, '
          '{credentials: "include"}); const b = await r.blob(); '
          'return await new Promise((ok, no) => { const fr = new FileReader(); '
          'fr.onload = () => ok(fr.result); fr.onerror = () => no("read"); '
          'fr.readAsDataURL(b); }); })(${jsonEncode(src)})';
      try {
        final r = await _cdp.send('Runtime.evaluate',
            params: {
              'expression': expr,
              'awaitPromise': true,
              'returnByValue': true
            },
            sessionId: sessionId,
            timeout: const Duration(seconds: 40));
        final v = (r['result'] as Map?)?['value']?.toString() ?? '';
        final comma = v.indexOf(',');
        if (v.startsWith('data:') && comma > 0) {
          final bytes = base64Decode(v.substring(comma + 1));
          if (bytes.length > 64) return FetchedImage(bytes, sniffMime(bytes));
        }
      } catch (_) {}
    }
    throw CdpException('Could not download the picture (the site blocks '
        'it or the tab was closed).');
  }

  /// Plain HTTP download with the page as referrer (no browser needed).
  static Future<FetchedImage> fetchDirect(String src, String pageUrl) async {
    final res = await http.get(Uri.parse(src), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 '
          'Safari/537.36',
      'Accept': 'image/avif,image/webp,image/png,image/*,*/*;q=0.8',
      if (pageUrl.isNotEmpty) 'Referer': pageUrl,
    }).timeout(const Duration(seconds: 40));
    if (res.statusCode != 200 || res.bodyBytes.length <= 64) {
      throw CdpException('Picture download failed (HTTP ${res.statusCode}).');
    }
    return FetchedImage(res.bodyBytes, sniffMime(res.bodyBytes));
  }

  static String sniffMime(Uint8List b) {
    bool at(int o, List<int> sig) {
      if (b.length < o + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[o + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) {
      return 'image/webp';
    }
    if (at(4, [0x66, 0x74, 0x79, 0x70])) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (brand.startsWith('avi')) return 'image/avif';
      if (brand.startsWith('hei') || brand.startsWith('mif')) {
        return 'image/heic';
      }
    }
    if (at(0, [0x42, 0x4D])) return 'image/bmp';
    final head = String.fromCharCodes(b.take(256)).toLowerCase();
    if (head.contains('<svg')) return 'image/svg+xml';
    return 'application/octet-stream';
  }

  /// Converts a picture that the image package cannot decode (AVIF, SVG,
  /// HEIC...) to PNG using Chromium itself: draws it on a canvas inside a
  /// tab and returns the PNG bytes.
  /// Screenshot of a page area (document CSS px) - works for anything that
  /// is visible: locked / protected pictures, video frames, canvas.
  Future<Uint8List?> captureRegion(
      String sessionId, Map<String, dynamic> meta) async {
    if (sessionId.isEmpty || !_sessions.containsValue(sessionId)) return null;
    final r = meta['rect'];
    if (r is! Map) return null;
    double n(String k) => (r[k] as num?)?.toDouble() ?? 0;
    final w = n('w'), h = n('h');
    if (w < 8 || h < 8) return null;
    // Move the virtual mouse away so the site's hover layer (dark wash,
    // "Save" buttons) is not in the shot.
    try {
      await _cdp.send('Input.dispatchMouseEvent',
          params: {'type': 'mouseMoved', 'x': 0, 'y': 0},
          sessionId: sessionId, timeout: const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 120));
    } catch (_) {}
    // Small areas are rendered at a higher zoom for a sharper picture.
    final big = w > h ? w : h;
    final scale = (1400 / big).clamp(1.0, 2.0);
    try {
      final res = await _cdp.send('Page.captureScreenshot',
          params: {
            'format': 'png',
            'clip': {'x': n('x'), 'y': n('y'), 'width': w, 'height': h, 'scale': scale},
          },
          sessionId: sessionId,
          timeout: const Duration(seconds: 20));
      final data = (res['data'] ?? '').toString();
      if (data.isEmpty) return null;
      return base64Decode(data);
    } catch (_) {
      return null;
    } finally {
      try {
        await _cdp.send('Runtime.evaluate',
            params: {'expression': 'window.__aisCapDone && window.__aisCapDone()', 'silent': true},
            sessionId: sessionId, timeout: const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  /// Fallback for pictures that cannot be downloaded at all: scrolls the
  /// picture into view in its tab and screenshots it.
  Future<Uint8List?> captureElement(String src, String sessionId) async {
    if (sessionId.isEmpty || !_sessions.containsValue(sessionId)) return null;
    try {
      final r = await _cdp.send('Runtime.evaluate',
          params: {
            'expression':
                'window.__aisCapPrep ? window.__aisCapPrep(${jsonEncode(src)}) : ""',
            'awaitPromise': true,
            'returnByValue': true,
          },
          sessionId: sessionId,
          timeout: const Duration(seconds: 10));
      final v = (r['result'] as Map?)?['value']?.toString() ?? '';
      if (v.isEmpty) return null;
      return captureRegion(sessionId, {'rect': jsonDecode(v)});
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> rasterizeInPage(String src, String sessionId) async {
    if (sessionId.isEmpty || !_sessions.containsValue(sessionId)) return null;
    final expr = '(async (u) => { const i = new Image(); '
        'i.crossOrigin = "anonymous"; i.src = u; await i.decode(); '
        'const max = 2048; let w = i.naturalWidth || 1024, h = i.naturalHeight || 1024; '
        'const k = Math.min(1, max / Math.max(w, h)); w = Math.round(w * k); h = Math.round(h * k); '
        'const c = document.createElement("canvas"); c.width = w; c.height = h; '
        'c.getContext("2d").drawImage(i, 0, 0, w, h); return c.toDataURL("image/png"); '
        '})(${jsonEncode(src)})';
    try {
      final r = await _cdp.send('Runtime.evaluate',
          params: {'expression': expr, 'awaitPromise': true, 'returnByValue': true},
          sessionId: sessionId,
          timeout: const Duration(seconds: 30));
      final v = (r['result'] as Map?)?['value']?.toString() ?? '';
      final comma = v.indexOf(',');
      if (v.startsWith('data:image/png') && comma > 0) {
        return base64Decode(v.substring(comma + 1));
      }
    } catch (_) {}
    return null;
  }

  /// Disconnects from the window (the browser itself stays open).
  Future<void> disconnect() async {
    await _evSub.cancel();
    await _cdp.close();
    _handleClosed();
  }

  /// Closes the whole Chromium window.
  Future<void> closeBrowser() async {
    try {
      await _cdp.send('Browser.close', timeout: const Duration(seconds: 5));
    } catch (_) {}
    await disconnect();
  }
}

class _SkipVisit implements Exception {
  const _SkipVisit();
}
