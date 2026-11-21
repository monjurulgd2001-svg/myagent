import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'chromium_browser.dart';
import 'gecko_browser.dart';
import 'gecko_signin.dart';

/// Windows: the app's own Chromium window — the desktop twin of the
/// Android Gecko browser, following the AI Image Studio source's
/// desktop design:
///
///  * It drives a REAL Chrome / Edge / Brave window (installed on
///    the PC) through the DevTools protocol. Nothing is embedded in
///    the app — pages render in genuine Chromium, and the app only
///    injects the same picture-selection overlay and reads its
///    requests. The window runs with the app's OWN profile (under
///    the app-support folder), separate from the user's daily
///    browser.
///  * Sign-in uses a PLAIN launch of that profile (no DevTools —
///    Google refuses sign-in in controlled browsers); on Windows
///    the window closes itself once Gemini opens signed in, and
///    the session cookies are then harvested from the profile —
///    automatic connection, no pasting, exactly like Android.
///  * Google / account pages are never attached or injected.
class ChromiumStudioBrowser {
  ChromiumStudioBrowser._();

  static ChromiumStudioBrowser? _instance;
  static ChromiumStudioBrowser get instance =>
      _instance ??= ChromiumStudioBrowser._();

  /// The product gate for the desktop browser features (the
  /// underlying engine also runs on Linux/macOS, but the shipped
  /// desktop build is Windows).
  static bool get supported => Platform.isWindows;

  ChromiumBrowser? _b;
  StreamSubscription<WebImageRequest>? _reqSub;
  StreamSubscription<void>? _chgSub;

  final _requests = StreamController<GeckoBrowserRequest>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Stream<GeckoBrowserRequest> get requests => _requests.stream;
  Stream<void> get changes => _changes.stream;

  bool get isOpen => _b?.isConnected ?? false;
  String get displayName => _b?.displayName ?? 'Chrome / Edge';

  /// Adapts the Chromium overlay request to the shared model the
  /// Image Search screen already consumes (pure, testable).
  static GeckoBrowserRequest adapt(WebImageRequest r) =>
      GeckoBrowserRequest(
        r.action,
        [
          for (final i in r.images)
            GeckoImageRef(
              src: i.src,
              hi: i.hi,
              alt: i.alt,
              kind: (i.meta['kind'] ?? '').toString(),
              meta: i.meta,
            ),
        ],
        r.pageUrl,
        r.pageTitle,
        sessionId: r.sessionId,
      );

  void _wire(ChromiumBrowser b) {
    _reqSub?.cancel();
    _chgSub?.cancel();
    _reqSub = b.requests.listen((r) => _requests.add(adapt(r)));
    _chgSub = b.changes.listen((_) => _changes.add(null));
  }

  /// Opens the controlled window on [url] (a new tab when the
  /// window is already running).
  Future<void> open(String url) async {
    final b = _b;
    if (b != null && b.isConnected) {
      await b.openTab(url);
      _changes.add(null);
      return;
    }
    final nb = await ChromiumBrowser.launch(startUrl: url);
    _wire(nb);
    _b = nb;
    _changes.add(null);
  }

  void setBasket(List<String> srcs, int pages) =>
      _b?.setBasket(srcs, pages);

  Future<void> notifyStatus(String src, String state,
      [String message = '']) async {
    try {
      await _b?.notifyPage('', src, state, message);
    } catch (_) {}
  }

  Future<void> toast(String msg) async {
    try {
      await _b?.toast(msg);
    } catch (_) {}
  }

  /// Picture bytes via the browser (resource cache / direct /
  /// in-page fetch chain); null when every route fails.
  Future<(Uint8List, String)?> fetchImage(
      String src, String pageUrl, String sessionId) async {
    final b = _b;
    if (b == null) return null;
    try {
      final f =
          await b.fetchImage(src, sessionId: sessionId, pageUrl: pageUrl);
      return (f.bytes, f.mimeType);
    } catch (_) {
      return null;
    }
  }

  /// Screenshots the overlay-marked area of a tab (rect in meta).
  Future<Uint8List?> captureRegion(
      String sessionId, Map<String, dynamic> meta) async {
    final b = _b;
    if (b == null) return null;
    try {
      return await b.captureRegion(sessionId, meta) ??
          await b.captureElement(
              (meta['src'] ?? '').toString(), sessionId);
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    try {
      await _b?.closeBrowser();
    } catch (_) {}
    _b = null;
    _changes.add(null);
  }

  /// The sign-in window needs the profile exclusively: close the
  /// controlled window first (their session manager does the same).
  Future<void> closeForSignIn() async {
    if (_b == null) return;
    try {
      await _b!.closeBrowser();
    } catch (_) {}
    _b = null;
    _changes.add(null);
  }

  // ---------------------------------------------------------- sign-in
  /// Opens the app-profile browser as a normal window on [url]
  /// (Google sign-in); completes when the window closes — on
  /// Windows it closes itself as soon as Gemini opens signed in.
  static Future<int> launchSignInWindow({String? url}) =>
      ChromiumBrowser.launchPlain(
          url: url ??
              'https://accounts.google.com/ServiceLogin?continue='
                  'https%3A%2F%2Fgemini.google.com%2Fapp');

  /// Reads the profile's Gemini session cookies and converts them
  /// to a Cookie header ('' when the profile is not signed in).
  /// With [visit] the profile first loads Gemini in the background
  /// so Chrome renews the session itself.
  static Future<String> harvestHeader({bool visit = true}) async {
    try {
      final cookies =
          await ChromiumBrowser.harvestGoogleCookies(visit: visit);
      return GeckoSignIn.headerFromCookiesJson(jsonEncode(cookies));
    } catch (_) {
      return '';
    }
  }
}
