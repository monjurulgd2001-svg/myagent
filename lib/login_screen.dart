// Gemini Login screen — the heart of the "Gemini login feature".
//
// Sign-in runs on Google's own page; the app NEVER sees or stores
// the password. Three routes, by platform:
//
//  * ANDROID — the app's built-in Firefox browser (GeckoView, see
//    gecko_signin.dart): a full browser engine, so Google allows
//    the sign-in (the Android system WebView gets "This browser or
//    app may not be secure"), and its built-in extension hands the
//    session cookies straight back to the app — connecting is
//    automatic, and Refresh can renew the session the same way.
//  * WINDOWS — the app's own Chrome / Edge window on its own
//    profile (see chromium_studio_browser.dart), launched plainly
//    for sign-in; it closes itself once Gemini opens signed in,
//    and the session cookies are read from that profile —
//    connecting is automatic, and Refresh renews the same way.
//  * ELSEWHERE — a DEDICATED EXTERNAL browser process (Chrome /
//    Firefox / default). An app cannot read another browser's
//    cookies (OS sandbox), so the session comes back as a paste:
//    the user copies the session cookie (__Secure-1PSID +
//    __Secure-1PSIDTS, a full Cookie header, or a cookies.txt
//    export — on desktop Chrome: F12 > Application > Cookies)
//    into the Session cookies box for that account slot.
//
// Either way the jar is stored per account slot u/<n>; Test
// verifies by fetching the Gemini app page and extracting the
// SNlM0e token + account email (GeminiApi.getSession). From there
// the jar is used — and renewed — entirely in-app (auto-renew
// switch in the card).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'background_mode_card.dart';
import 'chromium_studio_browser.dart';
import 'external_browser.dart';
import 'gecko_signin.dart';
import 'gemini_api.dart';
import 'models.dart';
import 'session_store.dart';

class LoginScreen extends StatefulWidget {
  final int initialAuthUser;
  final VoidCallback? onConnected;
  const LoginScreen({super.key, this.initialAuthUser = 0, this.onConnected});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _connecting = false;
  String _status =
      'Tap Sign in — Gemini opens in your browser. Then paste the '
      'session cookie below to connect.';
  bool _statusIsError = false;
  final TextEditingController _cookieCtrl = TextEditingController();
  late int _authUser;

  // "Gemini web session" settings card state.
  bool _autoRenew = true;
  bool _cookiesVisible = false;

  // v123 — what is SAVED on this phone for this slot, shown
  // persistently under the status line and read from storage (not
  // from a live check). A blocked live check used to make it look
  // like the login was never saved; this line proves it is.
  String? _savedLoginLabel;

  @override
  void initState() {
    super.initState();
    _authUser = widget.initialAuthUser;
    if (GeckoSignIn.supported) {
      _status = 'Tap Sign in — the built-in Firefox browser opens; '
          'sign in there and this screen connects by itself.';
    } else if (ChromiumStudioBrowser.supported) {
      _status = 'Tap Sign in — the app browser window opens; sign '
          'in there and this screen connects by itself.';
    }
    _loadSessionSettings();
  }

  @override
  void dispose() {
    _cookieCtrl.dispose();
    super.dispose();
  }

  void _say(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusIsError = error;
    });
  }

  String get _startUrl =>
      'https://gemini.google.com/u/$_authUser/app?authuser=$_authUser';

  // ---- "Gemini web session" settings card ----

  Future<void> _loadSessionSettings() async {
    final renew = await SessionStore.loadAutoRenew();
    final saved = await SessionStore.cookieForUser(_authUser);
    if (!mounted) return;
    setState(() {
      _autoRenew = renew;
      if (saved != null && saved.isNotEmpty) _cookieCtrl.text = saved;
    });
    await _refreshSavedInfo();
  }

  /// v123 — refreshes the persistent "Saved on this phone" line
  /// from storage: the saved header for this slot plus the saved
  /// account email (only when it belongs to this slot).
  Future<void> _refreshSavedInfo() async {
    final info = await SessionStore.loadActiveInfo();
    final saved = await SessionStore.cookieForUser(_authUser);
    if (!mounted) return;
    setState(() {
      if (saved != null && saved.isNotEmpty) {
        final email = info?['email'] as String?;
        final infoSlot = info?['authUser'];
        _savedLoginLabel = email != null &&
                email.isNotEmpty &&
                infoSlot == _authUser
            ? '$email · u/$_authUser'
            : 'Cookies saved for u/$_authUser';
      } else {
        _savedLoginLabel = null;
      }
    });
  }

  /// When the account slot changes, the session-cookies box follows
  /// it (that slot's saved header, hidden again).
  Future<void> _prefillCookiesForSlot() async {
    final saved = await SessionStore.cookieForUser(_authUser);
    if (!mounted) return;
    setState(() {
      _cookieCtrl.text = saved ?? '';
      _cookiesVisible = false;
    });
    await _refreshSavedInfo();
  }

  /// "Sign in" — Android: the built-in Firefox browser (GeckoView)
  /// opens on Google's sign-in page and the session comes back by
  /// itself when it closes. Windows: the app's own Chrome / Edge
  /// window opens for sign-in and the session is read from its
  /// profile afterwards. Elsewhere: the external browser opens,
  /// and the session comes back through the Session cookies box.
  Future<void> _openSignInPage() async {
    if (GeckoSignIn.supported) {
      await _signInWithGecko();
      return;
    }
    if (ChromiumStudioBrowser.supported) {
      await _signInWithChromium();
      return;
    }
    final ok = await ExternalBrowser.open(_startUrl);
    _say(
      ok
          ? 'Gemini opened in your browser — sign in there. Then bring '
              'the session back: copy the session cookie and paste it '
              'into the Session cookies box below (Save, then Test).'
          : 'No browser could be opened on this device.',
      error: !ok,
    );
  }

  /// Android sign-in via the built-in Firefox engine: the native
  /// screen returns the session-cookie JSON when it closes; a jar
  /// that passes the shape check is saved to this slot and verified
  /// against Gemini itself. [url] overrides the start page (the
  /// add-account flow passes Google's AddSession page).
  Future<void> _signInWithGecko({String? url}) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      _say('Opening the built-in Firefox sign-in — sign in with '
          'Google there; this screen connects by itself when you '
          'finish.');
      final raw = await GeckoSignIn.signIn(url ?? _startUrl);
      final header = GeckoSignIn.headerFromCookiesJson(raw);
      if (header.isEmpty ||
          !SessionStore.cookieHeaderLooksLoggedIn(header)) {
        // v124 — the browser did not finish signing in (on a slow
        // connection the page can take minutes, and the old message
        // sent the user to Refresh — which cannot help when the
        // profile holds no login at all). The saved login, if any,
        // is untouched: say so, and ask for one more Sign in with
        // time to load.
        final saved = await SessionStore.cookieForUser(_authUser);
        _say(
            saved != null &&
                    SessionStore.cookieHeaderLooksLoggedIn(saved)
                ? 'Sign-in closed without a session — the browser did '
                    'not finish signing in. Your saved login below is '
                    'untouched. Please tap Sign in again and wait for '
                    'Gemini to open; on a slow connection it can take '
                    'a while. Pasting below also still works.'
                : 'Sign-in closed without a session — the browser did '
                    'not finish signing in. Please tap Sign in again '
                    'and wait for Gemini to open; on a slow connection '
                    'it can take a while. Pasting below also still works.',
            error: true);
        return;
      }
      // v121 — the browser read the session token off its own
      // loaded page: use it directly, no Dart HTTP fetch (Google
      // bot-checks that fetch — live 2026-11-21). When the page
      // read missed, fall back to the v118 verify below, which
      // fetches the token itself.
      final browserSession = _browserSessionFromResult(raw, header);
      if (browserSession != null) {
        await _verifyAndFinish(
            headerToSave: header, browserSession: browserSession);
        return;
      }
      // v118 — verify-before-save: prove the jar first, store it
      // only once it works, so a bad harvest cannot kill the saved
      // login. On failure the old saved session stays untouched.
      await _verifyAndFinish(headerToSave: header);
    } catch (e) {
      _say('Built-in sign-in failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Windows sign-in via the app's own Chrome / Edge window: the
  /// profile first opens as a plain browser (it closes itself once
  /// Gemini opens signed in); then the session cookies are read
  /// from the profile — a fast read first, a renewing visit if that
  /// found nothing — saved to this slot and verified.
  Future<void> _signInWithChromium({String? url}) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      _say('Opening the app browser for Google sign-in — sign in '
          'there; the window closes itself when Gemini opens, and '
          'this screen connects by itself.');
      await ChromiumStudioBrowser.instance.closeForSignIn();
      await ChromiumStudioBrowser.launchSignInWindow(
          url: url ?? _startUrl);
      var header =
          await ChromiumStudioBrowser.harvestHeader(visit: false);
      if (!SessionStore.cookieHeaderLooksLoggedIn(header)) {
        header = await ChromiumStudioBrowser.harvestHeader();
      }
      if (!SessionStore.cookieHeaderLooksLoggedIn(header)) {
        _say('Sign-in window closed without a session. If you did '
            'sign in, tap Refresh — the app browser keeps the login '
            'and can hand it over again. Pasting below also works.',
            error: true);
        return;
      }
      // v118 — verify-before-save (same as the Android flow above).
      await _verifyAndFinish(headerToSave: header);
    } catch (e) {
      _say('Browser sign-in failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// "Refresh" — re-check this slot's session right now. On
  /// Android the built-in browser's profile first renews the
  /// session itself and hands over fresh cookies; on Windows the
  /// app-browser profile does the same. Each fresh jar is verified
  /// BEFORE it is saved (v118), so a bad harvest cannot overwrite
  /// the working saved login — and when every fresh jar fails, the
  /// saved jar below is still checked as before.
  Future<void> _refreshSession() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      final candidates = <({String header, GeminiSession? session})>[];
      final savedForRefresh = await SessionStore.cookieForUser(_authUser);
      if (GeckoSignIn.supported) {
        try {
          // v132 — pass saved cookies so manually pasted cookies are
          // also synced into GeckoView and verified in Firefox instead
          // of falling back to Google's bot-checked Dart HTTP fetch.
          final raw =
              await GeckoSignIn.refresh(cookieHeader: savedForRefresh);
          final header = GeckoSignIn.headerFromCookiesJson(raw);
          if (SessionStore.cookieHeaderLooksLoggedIn(header)) {
            // v121 — the headless refresh read the token off its
            // own loaded page too; use it when it is this slot's.
            candidates.add((
              header: header,
              session: _browserSessionFromResult(raw, header),
            ));
          }
        } catch (_) {
          // No signed-in profile (yet) — the saved-jar check below
          // still runs and reports the real state.
        }
      }
      if (ChromiumStudioBrowser.supported) {
        try {
          final header = await ChromiumStudioBrowser.harvestHeader();
          if (SessionStore.cookieHeaderLooksLoggedIn(header)) {
            candidates.add((header: header, session: null));
          }
        } catch (_) {
          // No signed-in profile (yet) — the saved-jar check below
          // still runs and reports the real state.
        }
      }
      for (final c in candidates) {
        try {
          await _verifyAndFinish(
              headerToSave: c.header, browserSession: c.session);
          return;
        } catch (_) {
          // This fresh jar did not verify — try the next one, then
          // the saved jar below.
        }
      }
      final saved = await SessionStore.cookieForUser(_authUser);
      if (saved != null && SessionStore.cookieHeaderLooksLoggedIn(saved)) {
        try {
          final api = GeminiApi();
          final s = await api.getSession(
              forceRefresh: true, explicitAuthUser: _authUser);
          _say('Session OK — Account u/${s.authUser}: ${s.email}');
          final fresh = await SessionStore.cookieForUser(_authUser);
          if (fresh != null && mounted) {
            setState(() => _cookieCtrl.text = fresh);
          }
        } catch (e) {
          // v122 — the CHECK was blocked (bot check), not the
          // session: getSession throws before saving anything, so
          // the saved login is untouched. Say that plainly instead
          // of reporting the account as disconnected (live
          // 2026-11-21: first connect shows Connected, Refresh
          // shows not connected — the session was fine all along).
          if (GeminiApi.isBotBlocked(e)) {
            _say('Could not verify right now — Google blocked the '
                'check (bot check). Your saved session is untouched — '
                'try again later, or tap Sign in to reconnect in the '
                'browser.',
                error: true);
            return;
          }
          rethrow;
        }
      } else {
        _say('No saved session for Account u/$_authUser yet. Tap '
            'Sign in to connect this account.',
            error: true);
      }
    } catch (e) {
      // v122 — same blocked-check case surfacing from another step.
      if (GeminiApi.isBotBlocked(e)) {
        _say('Could not verify right now — Google blocked the check '
            '(bot check). Your saved session is untouched — try again '
            'later, or tap Sign in to reconnect in the browser.',
            error: true);
      } else {
        _say('Refresh failed: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
      await _refreshSavedInfo();
    }
  }

  Future<void> _setAutoRenew(bool value) async {
    setState(() => _autoRenew = value);
    await SessionStore.saveAutoRenew(value);
    _say(value
        ? 'Cookie auto-renew ON — saved sessions refresh in the background.'
        : 'Cookie auto-renew OFF — sessions are only read when you generate.');
  }

  /// Save the session-cookies box content to the selected slot.
  /// Returns false (with a status message) when the content is not
  /// a usable Gemini cookie.
  Future<bool> _saveSessionCookies({bool quiet = false}) async {
    final normalised = SessionStore.normalisePastedCookies(_cookieCtrl.text);
    if (normalised.isEmpty ||
        !SessionStore.cookieHeaderLooksLoggedIn(normalised)) {
      if (!quiet) {
        _say(
          'That is not a usable Gemini cookie. Paste the '
          '__Secure-1PSID value (and __Secure-1PSIDTS), a full Cookie '
          'header, or a cookies.txt export.',
          error: true,
        );
      }
      return false;
    }
    await SessionStore.saveCookieForUser(_authUser, normalised);
    if (GeckoSignIn.supported) {
      unawaited(GeckoSignIn.syncCookies(normalised));
    }
    if (mounted) setState(() => _cookieCtrl.text = normalised);
    if (!quiet) _say('Session cookies saved for Account u/$_authUser.');
    await _refreshSavedInfo();
    return true;
  }

  /// "Test" — verify the session against Gemini (same finish as
  /// Connect). When the box changed, the pasted content is verified
  /// BEFORE it is saved (v118): a bad paste used to overwrite the
  /// working saved login, and the failure then looked like "login
  /// expired" with no way back. On failure the old saved session
  /// stays untouched, and the message now says what the page
  /// actually was (see GeminiApi.diagnoseSessionPage).
  Future<void> _testSessionCookies() async {
    if (_connecting) return;
    final saved = await SessionStore.cookieForUser(_authUser) ?? '';
    final boxText = _cookieCtrl.text.trim();
    String? headerToSave;
    if (boxText != saved.trim()) {
      final normalised = SessionStore.normalisePastedCookies(_cookieCtrl.text);
      if (normalised.isEmpty ||
          !SessionStore.cookieHeaderLooksLoggedIn(normalised)) {
        _say(
          'That is not a usable Gemini cookie. Paste the '
          '__Secure-1PSID value (and __Secure-1PSIDTS), a full Cookie '
          'header, or a cookies.txt export.',
          error: true,
        );
        return;
      }
      headerToSave = normalised;
    } else if (saved.isEmpty) {
      _say('Nothing to test yet — paste a cookie in the box. (Sign in '
          'opens your browser, where the cookie comes from.)',
          error: true);
      return;
    }
    setState(() => _connecting = true);
    try {
      // v122 — the saved jar is tested through the browser first:
      // the Dart /app fetch is bot-blocked (live 2026-11-21), so
      // Test kept failing on a session that was actually fine
      // (v121 proved the sign-in itself works). Only when the box
      // is unchanged — the jar under test IS the saved login the
      // profile holds. A fresh paste can only be proven by
      // fetching with it, so it keeps the Dart verify below.
      if (GeckoSignIn.supported) {
        try {
          // v132 — test saved AND newly pasted cookies via GeckoView
          // first (seeds the profile if empty, verifies in Firefox so
          // Google does not bot-check the request).
          final refreshed = await GeckoSignIn.refreshSessionPage(
              cookieHeader: headerToSave ?? saved);
          final session = refreshed == null
              ? null
              : _browserSessionFromPage(refreshed.page, refreshed.header);
          if (session != null) {
            // The profile's fresh cookies are saved too (rotated
            // cookies absorbed), exactly like Refresh does.
            await _verifyAndFinish(
                headerToSave: refreshed!.header, browserSession: session);
            return;
          }
        } catch (_) {
          // Browser path missed — the Dart verify below still runs.
        }
      }
      await _verifyAndFinish(headerToSave: headerToSave);
    } catch (e) {
      _say('Test failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _copySessionCookies() async {
    var text = _cookieCtrl.text.trim();
    if (text.isEmpty) {
      text = await SessionStore.cookieForUser(_authUser) ?? '';
    }
    if (text.isEmpty) {
      _say('No session cookies to copy for Account u/$_authUser.',
          error: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _say('Session cookies copied. Keep them private — they ARE your '
        'Gemini login.');
  }

  Future<void> _removeSessionCookies() async {
    await SessionStore.saveCookieForUser(_authUser, '');
    if (!mounted) return;
    setState(() {
      _cookieCtrl.clear();
      _cookiesVisible = false;
    });
    await _refreshSavedInfo();
    _say('Saved session for Account u/$_authUser removed. Tap Sign '
        'in to add it again.');
  }

  /// Verify the session against Gemini and finish (Connected! +
  /// snackbar + onConnected).
  ///
  /// v118 — verify-before-save: when [headerToSave] is given, the
  /// jar is proven with it FIRST and only stored once it works. A
  /// bad harvest used to overwrite the working saved login, and the
  /// failure then looked like "login expired" with no way back.
  /// When null, the stored jar for this slot is verified as before.
  /// v121 — the in-browser token belongs to the account whose
  /// /app page the browser loaded. The sign-in screen loads the
  /// selected slot's own /app URL, so they normally match; when
  /// Google landed the browser on another slot's page instead,
  /// the token is NOT this slot's — the caller falls back to the
  /// Dart verify, which fetches the right slot's page.
  bool _browserPageMatchesSlot(GeckoSessionPage page) {
    final slot = page.authUser;
    if (slot == null) return true;
    return slot == _authUser;
  }

  /// v121 — builds the in-browser session for a sign-in /
  /// refresh result, or null when the page read missed or the
  /// browser landed on another slot's page (the caller falls back
  /// to the Dart HTTP verify).
  GeminiSession? _browserSessionFromResult(String? raw, String header) {
    final page = GeckoSignIn.sessionPageFromResult(raw);
    if (page == null) return null;
    return _browserSessionFromPage(page, header);
  }

  /// v122 — same as [_browserSessionFromResult], but from the
  /// already-parsed page (the Test / renewal helper hands it over
  /// parsed).
  GeminiSession? _browserSessionFromPage(
      GeckoSessionPage page, String header) {
    if (!_browserPageMatchesSlot(page)) return null;
    return GeminiApi.sessionFromPageFields(
      authUser: _authUser,
      cookieHeader: header,
      at: page.at,
      bl: page.bl,
      fSid: page.fSid,
      email: page.email,
      serverToken: page.serverToken,
      apiKeys: page.apiKeys,
    );
  }

  Future<void> _verifyAndFinish(
      {String? headerToSave, GeminiSession? browserSession}) async {
    _say('Verifying Gemini session (SNlM0e token)...');
    final api = GeminiApi();
    // v121 — a browser session skips the Dart HTTP fetch
    // entirely: the token came from the page the real browser
    // loaded, and Google never saw a raw request to bot-check.
    final session = browserSession ??
        await api.getSession(
            forceRefresh: true,
            explicitAuthUser: _authUser,
            verifyHeader: headerToSave);
    if (browserSession != null) {
      await api.adoptSession(browserSession);
    }
    if (headerToSave != null) {
      await SessionStore.saveCookieForUser(_authUser, headerToSave);
      if (GeckoSignIn.supported) {
        unawaited(GeckoSignIn.syncCookies(headerToSave));
      }
      if (mounted) setState(() => _cookieCtrl.text = headerToSave);
    }
    _say('Connected! Gemini Account u/${session.authUser} — ${session.email}');
    widget.onConnected?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gemini connected: ${session.email}')),
      );
    }
    await _refreshSavedInfo();
  }

  /// Add another Gmail — Android: Google's Add-session page opens
  /// in the built-in Firefox browser (its profile holds every
  /// signed-in account side by side) and the session comes back by
  /// itself. Elsewhere: the external browser opens, and the account
  /// connects here by pasting its session cookie for its slot.
  Future<void> _openAddAccount() async {
    final url =
        'https://accounts.google.com/AddSession?hl=en&continue=${Uri.encodeComponent('https://gemini.google.com/app')}';
    if (GeckoSignIn.supported) {
      await _signInWithGecko(url: url);
      return;
    }
    if (ChromiumStudioBrowser.supported) {
      await _signInWithChromium(url: url);
      return;
    }
    final ok = await ExternalBrowser.open(url);
    _say(
      ok
          ? 'Add the account in your browser. To use it here, select '
              'its slot above and paste its session cookie below.'
          : 'No browser could be opened on this device.',
      error: !ok,
    );
  }

  Future<void> _signOut() async {
    await SessionStore.clearAllCookies();
    if (!mounted) return;
    setState(() {
      _cookieCtrl.clear();
      _cookiesVisible = false;
    });
    await _refreshSavedInfo();
    _say(GeckoSignIn.supported
        ? 'Signed out. All saved Gemini cookies were removed from '
            'this app. Note: the built-in browser keeps its own '
            'Google login, so Refresh can connect again — sign out '
            'inside that browser too for a full sign-out.'
        : ChromiumStudioBrowser.supported
            ? 'Signed out. All saved Gemini cookies were removed '
                'from this app. Note: the app browser window keeps '
                'its own Google login, so Refresh can connect again '
                '— sign out inside that window too for a full '
                'sign-out.'
            : 'Signed out. All saved Gemini cookies were removed '
                'from this app.');
  }

  /// The "Gemini web session" settings card under the browser:
  /// sign-in / refresh, the cookie auto-renew switch, and this
  /// slot's saved session cookies (masked, with Save / Test / Copy /
  /// Remove). All session management lives here now — including the
  /// cookie-paste fallback for a Google-blocked sign-in.
  /// One numbered step in the v56 login stepper.
  Widget _loginStep(String number, String title, String sub) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: Color(0xFF37335F),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(number,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
          const SizedBox(height: 6),
          Text(title,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(sub,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _sessionCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.cookie_outlined,
                      size: 20, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gemini web session',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(
                          'Generation, metadata + AI Set Director — no API key',
                          style:
                              TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // v56: three numbered steps up front — the old wall of
            // text never told a new user what to do first. The full
            // explanation lives in the expander below, unchanged.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _loginStep('1', 'Sign in', 'Gemini opens'),
                _loginStep('2', 'Connect', 'Auto, or paste a cookie'),
                _loginStep('3', 'Generate', 'Prompt in Studio'),
              ],
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('How sign-in works',
                  style: TextStyle(fontSize: 13)),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    GeckoSignIn.supported
                        ? 'Sign in opens the app\'s built-in Firefox '
                            'browser — sign in there once and the '
                            'session comes back here by itself, saved '
                            'on this device and renewed. The cookie '
                            'box below stays as a manual backup.'
                        : ChromiumStudioBrowser.supported
                            ? 'Sign in opens the app\'s own Chrome / '
                                'Edge window — sign in there once and '
                                'the session comes back here by '
                                'itself, saved on this device and '
                                'renewed. The cookie box below stays '
                                'as a manual backup.'
                            : 'Sign in opens in Chrome / Firefox. The '
                                'browser keeps its own cookies, so '
                                'bring the session back with the '
                                'cookie box below — paste once, and '
                                'it stays saved on this device and '
                                'renewed.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _status,
              style: TextStyle(
                fontSize: 13,
                color: _statusIsError ? scheme.error : null,
              ),
            ),
            // v123 — the saved login, from storage. Stays visible
            // even when a live check is blocked, so the screen
            // never looks like the login was never saved.
            if (_savedLoginLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                'Saved on this phone: $_savedLoginLabel',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _connecting ? null : _openSignInPage,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Sign in'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _connecting ? null : _refreshSession,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh'),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.autorenew,
                      size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Renew cookies from the app',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        'On (recommended): the app quietly refreshes '
                        'saved sessions in the background, so a pasted '
                        'or idle login does not expire. Off: cookies '
                        'are only read when you generate — the signed-in '
                        'browser renews its own session while you use it.',
                        style:
                            TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Switch(value: _autoRenew, onChanged: _setAutoRenew),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Session cookies (Account u/$_authUser)',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary),
            ),
            const SizedBox(height: 6),
            if (!_cookiesVisible)
              InkWell(
                onTap: () => setState(() => _cookiesVisible = true),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _cookieCtrl.text.isEmpty
                              ? 'No cookies saved yet — tap to paste'
                              : '••••••••••••••••••••••••••••',
                          style: const TextStyle(
                              fontSize: 13, letterSpacing: 2),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.visibility_outlined, size: 18),
                    ],
                  ),
                ),
              )
            else
              TextField(
                controller: _cookieCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: '__Secure-1PSID value...\n'
                      '__Secure-1PSIDTS value...\n'
                      '(or a full Cookie header / cookies.txt)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _cookiesVisible = false),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _connecting ? null : () => _saveSessionCookies(),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _connecting ? null : _testSessionCookies,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Test'),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _copySessionCookies,
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('Copy'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _connecting ? null : _removeSessionCookies,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                  style:
                      TextButton.styleFrom(foregroundColor: scheme.error),
                ),
              ],
            ),
            Text(
              'Paste a cookie for the account selected above. To copy '
              'one: Chrome > gemini.google.com > F12 > Application > '
              'Cookies > copy the __Secure-1PSID and __Secure-1PSIDTS '
              'values. Stored only on this device, sent only to '
              'gemini.google.com.',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Login'),
        actions: [
          IconButton(
            tooltip: 'Add another Gmail account',
            onPressed: _openAddAccount,
            icon: const Icon(Icons.person_add_alt_1_outlined),
          ),
          IconButton(
            tooltip: 'Sign out & clear saved cookies',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Row(
              children: [
                const Text('Account slot:'),
                const SizedBox(width: 8),
                Flexible(
                  child: DropdownButton<int>(
                    value: _authUser,
                    isExpanded: true,
                    items: List.generate(
                      6,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text(
                          i == 0
                              ? 'u/0 (Default Gmail)'
                              : 'u/$i (Gmail #${i + 1})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _authUser = v);
                      await _prefillCookiesForSlot();
                    },
                  ),
                ),
              ],
            ),
          ),
          // v108 — the build label on this screen too, so a Login
          // screenshot alone proves which build is installed.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'App v2.5.67',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sessionCard(),
                  // v84: the Background generation card moved here
                  // from the dashboard — it is a settings item, and
                  // this is the section where he signs in.
                  const BackgroundModeCard(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
