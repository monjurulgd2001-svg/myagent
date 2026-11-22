// Gemini HD Studio — Flutter port of the v2.5.3 Chrome extension.
// Wallpaper Set Designer, AI Metadata & Panel Uploader for Android
// (Kotlin) and Windows, built from one codebase.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'animation_engine.dart';
import 'animation_models.dart';
import 'animation_screen.dart';
import 'app_theme.dart';
import 'foreground_keep_alive.dart';
import 'gecko_browser.dart';
import 'gecko_signin.dart';
import 'dart:convert';
import 'generation_queue.dart';
import 'gemini_api.dart';
import 'image_search.dart';
import 'login_screen.dart';
import 'models.dart';
import 'originality.dart';
import 'panel_settings.dart';
import 'session_store.dart';
import 'studio_constants.dart';
import 'studio_engine.dart';
import 'widgets/device_mockup.dart';

/// v93 — dark / light theme choice (persisted; dark is the
/// default — the look the app has had since v49). The toggle in
/// the app bar flips this; the MaterialApp below listens to it.
const String kThemeModeKey = 'themeMode';
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.dark);

Future<void> toggleTheme() async {
  final next = themeModeNotifier.value == ThemeMode.dark
      ? ThemeMode.light
      : ThemeMode.dark;
  themeModeNotifier.value = next;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      kThemeModeKey, next == ThemeMode.light ? 'light' : 'dark');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = prefs.getString(kThemeModeKey) == 'light'
      ? ThemeMode.light
      : ThemeMode.dark;
  runApp(const GeminiHdStudioApp());
}

/// Dashboard colour palette (v49, from the user's reference
/// screenshot): near-black backgrounds, dark neutral cards and a
/// soft lavender primary (#A89CFE, sampled from the reference's
/// Generate button). Every screen in the app (Studio, Login,
/// Search, Settings) draws from this scheme, so the whole app
/// stays cohesive.
/// v95 — the dark background is now neutral black 90% (no more
/// blue tint): scaffold #0A0A0A, cards #1A1A1A.
// v139 — generate-main design system: calm layered slate surfaces,
// Inter typography, #A99CFF dark accent and 20dp cards / 12dp controls.
const ColorScheme kDashboardScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFA99CFF),
  onPrimary: Color(0xFF1B1050),
  primaryContainer: Color(0xFF3A2F8F),
  onPrimaryContainer: Color(0xFFE7E2FF),
  secondary: Color(0xFFC9C2FF),
  onSecondary: Color(0xFF1B1050),
  secondaryContainer: Color(0xFF2A2740),
  onSecondaryContainer: Color(0xFFE2DEFA),
  tertiary: Color(0xFFFF7AC6),
  onTertiary: Color(0xFF2B0A1E),
  error: Color(0xFFFF8A80),
  onError: Color(0xFF3B0907),
  surface: Color(0xFF0E0F14),
  onSurface: Color(0xFFECECF3),
  surfaceContainerLowest: Color(0xFF0B0C10),
  surfaceContainerLow: Color(0xFF15161D),
  surfaceContainer: Color(0xFF1A1B23),
  surfaceContainerHigh: Color(0xFF21222C),
  surfaceContainerHighest: Color(0xFF2A2B36),
  onSurfaceVariant: Color(0xFFA3A4B5),
  outline: Color(0xFF6E6F80),
  outlineVariant: Color(0xFF2B2C38),
  inverseSurface: Color(0xFFECECF3),
  onInverseSurface: Color(0xFF15161D),
  inversePrimary: Color(0xFF5B4BDB),
);

/// v93 — the light twin of [kDashboardScheme]: same lavender
/// family, but light surfaces with a deeper violet primary so
/// buttons and accents still read on white. Every screen draws
/// its colours from the scheme (never hardcoded), so the toggle
/// repaints the whole app.
const ColorScheme kDashboardLightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF5B4BDB),
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFE7E2FF),
  onPrimaryContainer: Color(0xFF1B1050),
  secondary: Color(0xFF6C5CE7),
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFEBEBF3),
  onSecondaryContainer: Color(0xFF1B1050),
  tertiary: Color(0xFFC2438B),
  onTertiary: Colors.white,
  error: Color(0xFFD32F2F),
  onError: Colors.white,
  surface: Color(0xFFF7F7FB),
  onSurface: Color(0xFF181822),
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Colors.white,
  surfaceContainer: Color(0xFFF1F1F7),
  surfaceContainerHigh: Color(0xFFEBEBF3),
  surfaceContainerHighest: Color(0xFFE4E4EE),
  onSurfaceVariant: Color(0xFF5A5B6E),
  outline: Color(0xFFB8B8C8),
  outlineVariant: Color(0xFFE0E0EA),
  inverseSurface: Color(0xFF15161D),
  onInverseSurface: Color(0xFFECECF3),
  inversePrimary: Color(0xFFA99CFF),
);

/// Batch prompt parsing, shared by the designer prompt field, the
/// batch queue panel and the generator itself: in batch mode every
/// non-empty line is one set job, run in order.
List<String> parseBatchPrompts(String text) => text
    .split('\n')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// Gentle fade + slide used for every route change, so moving between
/// the dashboard, login, search and settings feels smooth.
class FadeSlideTransitionsBuilder extends PageTransitionsBuilder {
  const FadeSlideTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(0.04, 0), end: Offset.zero)
            .animate(curved),
        child: child,
      ),
    );
  }
}

/// Aurora backdrop (v34 redesign): deep-space base with soft
/// violet / cyan / pink glows behind the dashboard, so the whole
/// home screen reads as one designed surface. Pushed screens keep
/// the solid base colour from the theme.
class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key});

  /// v93 — the base follows the theme now (deep-space in dark,
  /// pale lavender in light); the violet glows stay, softer in
  /// light so they tint instead of glaring.
  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Theme.of(context).colorScheme.surface);
  }
}

/// The app-wide theme (v34 Aurora Glass redesign), shared by
/// the app shell and design previews. v93: [light] builds the
/// light twin — same structure, the light scheme. The dark
/// branch keeps the v49 values (a few roles now come from the
/// scheme instead of literals, same numbers).
ThemeData buildStudioTheme({bool light = false}) {
  final base = light ? AppTheme.light() : AppTheme.dark();
  final scheme = base.colorScheme;
  return base.copyWith(
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      selectedLabelTextStyle: TextStyle(
          fontFamily: AppTheme.font,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface),
      unselectedLabelTextStyle: TextStyle(
          fontFamily: AppTheme.font,
          fontSize: 12,
          color: scheme.onSurfaceVariant),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeSlideTransitionsBuilder(),
        TargetPlatform.windows: FadeSlideTransitionsBuilder(),
        TargetPlatform.linux: FadeSlideTransitionsBuilder(),
        TargetPlatform.macOS: FadeSlideTransitionsBuilder(),
      },
    ),
  );
}

class GeminiHdStudioApp extends StatelessWidget {
  const GeminiHdStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    // v93 — the theme toggle above flips this notifier; the
    // whole app (dark + light ThemeData) rebuilds from it.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, __) => MaterialApp(
        title: 'Zedge Studio',
        debugShowCheckedModeBanner: false,
        theme: buildStudioTheme(light: true),
        darkTheme: buildStudioTheme(),
        themeMode: mode,
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final StudioEngine _engine;
  final List<String> _log = [];
  bool _busy = false;
  // v139 — Showcase grid columns per Set card (1..6, default 3 like generate-main).
  int _showcaseCols = 3;
  String _statusText = 'Ready';
  int _activeStep = 0;

  List<GeminiAccount> _accounts = [];
  bool _hasSavedCookies = false;
  bool get _isSignedIn => _accounts.isNotEmpty || _hasSavedCookies;
  String _accountMode = 'auto';
  String _sessionLabel = 'Not connected';
  List<SetEntry> _history = [];

  /// Dashboard tab: 0 = Studio (designer workbench + generated
  /// sets below it, v85), 1 = Animation (charging animations with
  /// Gemini, v86). Nav destinations 2-3 (Search / Login) open
  /// their screens as routes on top instead of switching the tab.
  /// (There is no separate Prompt destination — image-to-prompt
  /// lives inside Image Search.)
  int _tab = 0;

  // Charging Animation section (v86): videos made with Gemini
  // (Neon default, Task mode) in the app's Gecko browser session.
  // The engine owns the video list, the generation phase and the
  // Task choice; its driver reports come in on the Gecko
  // browserRequests stream (shared with the picture overlay).
  late final AnimationEngine _animEngine;
  StreamSubscription<GeckoBrowserRequest>? _animBrowserSub;

  /// v87 — remembered panel target for animation uploads (spread
  /// or a named account), separate from the image sets' target.
  String _animUploadTarget = 'spread';

  /// Phone Studio scroll view (v85): the designer card sits on
  /// top and the generated-sets gallery below it in one scroll.
  final ScrollController _studioScrollCtrl = ScrollController();

  /// Key on the inline gallery section — the auto-scroll after a
  /// generation finishes targets it (v85).
  final GlobalKey _resultsKey = GlobalKey();

  String _mode = 'set_24h';
  // v112 — reference layout: the prompt input is a numbered list
  // of rows (like the reference's Batch Sets Prompts card), not
  // one multi-line field. One row = one prompt = one set; two or
  // more non-empty rows IS batch mode (no switch any more).
  final List<TextEditingController> _promptCtrls = [
    TextEditingController()
  ];
  final List<FocusNode> _promptFocus = [FocusNode()];

  /// The row the import-concept writes into
  /// (the last row the user tapped or typed in).
  int _focusedPromptIndex = 0;

  /// Non-empty prompts, in row order — the single source of truth
  /// for generation, polish, the overnight queue and the batch
  /// panel. Empty rows are ignored (they are just spare lines).
  List<String> get _promptTexts => [
        for (final c in _promptCtrls) c.text.trim(),
      ].where((t) => t.isNotEmpty).toList();

  /// Batch = more than one prompt (derived from the rows, not a
  /// switch — the reference has no Batch toggle either).
  bool get _batchMode => _promptTexts.length > 1;

  /// Total characters across all rows (the "N/16384" count).
  int get _totalPromptChars =>
      _promptCtrls.fold(0, (n, c) => n + c.text.length);

  final TextEditingController _negativeCtrl =
      TextEditingController(text: kDefaultNegativePrompt);
  final TextEditingController _subfolderCtrl =
      TextEditingController(text: 'Gemini_HD');

  /// Per-job batch states ('waiting' | 'running' | 'done' | 'failed'),
  /// index-aligned with _promptTexts.
  List<String> _batchStatuses = const [];

  /// Set by the batch queue's Stop button: the running set finishes,
  /// the rest of the queue is skipped.
  bool _batchStop = false;

  // Overnight queue (v47): persisted items + runner state. The
  // queue survives the app closing; the runner works through the
  // pending items one by one under the foreground keep-alive.
  final List<QueueItem> _queue = [];
  bool _queueRunning = false;
  bool _queueStop = false;
  String _queueLiveStatus = '';
  final ValueNotifier<int> _queueTick = ValueNotifier<int>(0);
  Map<String, dynamic>? _queueSummary;

  // Background generation readiness (v72): generation start
  // offers the fix dialog while the phone is not exempt. The
  // in-app switch itself lives in BackgroundModeCard (Login
  // screen, since v84) and drives ForegroundKeepAlive.enabled.
  bool _bgDialogShownThisSession = false;

  // AI prompt polish (v48).
  bool _polishing = false;

  String _storyArc = 'auto';
  String _variation = 'clear';
  String _displayTarget = 'any';
  String _colorBoost = 'off';
  bool _upscale = true;
  bool _autoMetadata = true;
  bool _foldableCompanion = false;
  bool _useHubFolders = true;
  bool _useExactNames = true;
  bool _aiDirector = false;
  bool _forcePrefix = true;
  int _portraitW = kPortraitWidth;
  int _portraitH = kPortraitHeight;
  int _landscapeW = kLandscapeWidth;
  int _landscapeH = kLandscapeHeight;
  ({Uint8List bytes, String name, String mime})? _reference;
  final Map<int, TextEditingController> _stageCtrls = {};

  /// Fires _silentRenew every 15 minutes while the app is open.
  Timer? _sessionKeepAlive;

  @override
  void initState() {
    super.initState();
    _engine = StudioEngine(onStatus: _onStatus);
    _animEngine = AnimationEngine(
      onChanged: () {
        if (mounted) setState(() {});
      },
      // v87: the video metadata + panel upload run on the same
      // StudioEngine paths the image sets use (Gemini session,
      // R2 + Firebase).
      metadataGenerator: (video) => _engine.generateVideoMetadata(video),
      panelUploader: (video, {targetAccount = 'spread'}) =>
          _engine.uploadVideoToPanel(video, targetAccount: targetAccount),
      // v88: the video Prompt Polish runs on the same StudioEngine
      // Gemini session as the image Prompt Polish.
      promptPolisher: (prompt) => _engine.polishVideoPrompt(prompt),
      // v92: the Task-mode video BACKEND (no browser) runs on the
      // same StudioEngine Gemini session. v145 — a backend failure
      // no longer ends the job: it falls back to the browser
      // driver below (backend never succeeded live).
      taskBackendRunner: (taskText,
              {required onPhase, required deadline}) =>
          _engine.runTaskVideoBackend(taskText,
              onPhase: onPhase, deadline: deadline),
      // v146 — browser driver fallback, HEADLESS (user order:
      // browser show na kore, backend-e chole): NO browser window
      // ever opens — the job runs inside the invisible headless
      // GeckoSession (GeckoBridge.browserVideoHeadless, v136),
      // where the in-page driver types the SAME Task prompt in
      // Task mode itself. The finished video comes back through
      // the browserRequests stream (see _animBrowserSub above).
      // v150 — the runner returns whether Kotlin posted the job to
      // the extension port at once (true) or queued it (false);
      // the engine logs the queued case in its error log.
      videoDriverRunner: ({required prompt, required modelId, required jobId}) async {
        return GeckoBrowser.instance.startVideoHeadless(prompt, modelId, jobId);
      },
    );
    _animEngine.load();
    _animBrowserSub =
        GeckoBrowser.instance.requests.listen((req) {
      _animEngine.handleRequest(req);
    });
    _bootstrap();
    // Keep the saved Gemini login alive: every 15 minutes the session
    // is silently re-fetched, which absorbs Google's rotated cookies
    // (__Secure-1PSIDTS) into the saved jar — the login stays saved
    // and renews itself while the app is open.
    _sessionKeepAlive =
        Timer.periodic(const Duration(minutes: 15), (_) => _silentRenew());
  }

  @override
  void dispose() {
    _animBrowserSub?.cancel();
    _animEngine.dispose();
    _studioScrollCtrl.dispose();
    _sessionKeepAlive?.cancel();
    for (final c in _promptCtrls) {
      c.dispose();
    }
    for (final f in _promptFocus) {
      f.dispose();
    }
    _negativeCtrl.dispose();
    _subfolderCtrl.dispose();
    for (final c in _stageCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _engine.loadCloudinaryConfig();
    _accountMode = await SessionStore.loadAccountMode();
    _accounts = await SessionStore.loadDiscoveredAccounts();
    final savedCookies = await SessionStore.loadCookiesByUser();
    _hasSavedCookies =
        savedCookies.values.any(SessionStore.cookieHeaderLooksLoggedIn);
    _history = await _engine.loadHistory();
    await _loadQueue();
    final info = await SessionStore.loadActiveInfo();
    if (info != null && info['email'] != null) {
      _sessionLabel = 'u/${info['authUser']} - ${info['email']}';
      if (_accounts.isEmpty && _hasSavedCookies) {
        _accounts = [
          GeminiAccount(
            authUser: (info['authUser'] as num?)?.toInt() ?? 0,
            email: info['email'].toString(),
            bl: info['bl']?.toString() ?? '',
          ),
        ];
      }
    }
    // Background readiness (v72): arm the keep-alive gate from
    // the persisted switch (default ON). The switch itself lives
    // in BackgroundModeCard (Login screen, since v84) and drives
    // ForegroundKeepAlive.enabled directly when toggled.
    final prefs = await SharedPreferences.getInstance();
    ForegroundKeepAlive.enabled =
        prefs.getBool('bgModeEnabled') ?? true;
    _showcaseCols = (prefs.getInt('showcaseGridCols') ?? 3).clamp(1, 6);
    if (mounted) setState(() {});
    // If a login was saved earlier, renew it right away (fresh session
    // token + rotated cookies) so the app opens already signed in.
    await _silentRenew();
  }

  /// v122 — renews the session through the built-in browser
  /// (headless page read) and adopts it: fresh cookies are saved
  /// to the page's slot and the token is cached, exactly like a
  /// fetched session. Returns the session, or null when the
  /// browser had nothing to hand over. The Dart /app fetch is
  /// bot-blocked (live 2026-11-21), so without this the cache
  /// would go stale 15 minutes after sign-in and the next
  /// generation would fail on the re-fetch.
  Future<GeminiSession?> _renewSessionViaBrowser(GeminiApi api) async {
    if (!GeckoSignIn.supported) return null;
    try {
      final explicitSlot =
          _accountMode == 'auto' ? null : int.tryParse(_accountMode);
      final savedCookie = await SessionStore.cookieForUser(
          explicitSlot ?? api.activeAuthUserIndex);
      final refreshed =
          await GeckoSignIn.refreshSessionPage(cookieHeader: savedCookie);
      if (refreshed == null) return null;
      final explicit =
          _accountMode == 'auto' ? null : int.tryParse(_accountMode);
      final slot =
          refreshed.page.authUser ?? explicit ?? api.activeAuthUserIndex;
      final session = GeminiApi.sessionFromPageFields(
        authUser: slot,
        cookieHeader: refreshed.header,
        at: refreshed.page.at,
        bl: refreshed.page.bl,
        fSid: refreshed.page.fSid,
        email: refreshed.page.email,
        serverToken: refreshed.page.serverToken,
        apiKeys: refreshed.page.apiKeys,
      );
      await SessionStore.saveCookieForUser(slot, refreshed.header);
      await api.adoptSession(session);
      return session;
    } catch (_) {
      return null;
    }
  }

  /// Silent session renewal: re-fetches the Gemini session — which
  /// absorbs rotated cookies into the saved jar — without bothering
  /// the user. Runs once at startup when a saved login exists, then
  /// every 15 minutes while the app is open.
  Future<void> _silentRenew() async {
    if (_busy) return;
    // "Renew cookies from the app" setting (Gemini Login screen):
    // OFF means the app never refreshes sessions in the background.
    if (!await SessionStore.loadAutoRenew()) return;
    try {
      final cookies = await SessionStore.loadCookiesByUser();
      if (cookies.isEmpty) return;
      final api = GeminiApi();
      // v122 — renew through the browser FIRST (see
      // _renewSessionViaBrowser): the Dart calls below are
      // bot-blocked, so they would leave the cached session to go
      // stale. They still run afterwards — they fail silently per
      // slot when blocked, and they cover the other slots' jars
      // whenever Dart works again.
      final renewed = await _renewSessionViaBrowser(api);
      if (renewed != null) {
        final disc = await SessionStore.loadDiscoveredAccounts();
        if (mounted) {
          setState(() {
            _hasSavedCookies = true;
            if (disc.isNotEmpty) _accounts = disc;
            _sessionLabel = 'u/${renewed.authUser} - ${renewed.email}';
          });
        }
      }
      // Renew EVERY saved account (scan probes u/0..u/5 and absorbs
      // each jar's rotated cookies), so accounts used only for
      // quota auto-switch stay alive too, not just the active one.
      final found = await api.scanAccounts();
      if (found.isNotEmpty && mounted) {
        setState(() => _accounts = found);
      }
      final explicit =
          _accountMode == 'auto' ? null : int.tryParse(_accountMode);
      final s = await api.getSession(
          forceRefresh: true, explicitAuthUser: explicit);
      if (mounted) {
        setState(() => _sessionLabel = 'u/${s.authUser} - ${s.email}');
      }
    } catch (_) {
      // Stay quiet: a failed silent renewal only means the user may
      // need to sign in again from the Gemini Login tab.
    }
  }

  void _onStatus(StatusEvent e) {
    if (!mounted) return;
    setState(() {
      _statusText = e.message;
      if (e.step > 0) _activeStep = e.step - 1;
      _log.insert(0, e.message);
      if (_log.length > 80) _log.removeLast();
    });
    if (_queueRunning) {
      _queueLiveStatus = e.message;
      _queueTick.value++;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _verifySession() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = GeminiApi(onStatus: _onStatus);
      // v122 — same as the Login Test button: verify through the
      // browser first (the Dart fetch is bot-blocked).
      final renewed = await _renewSessionViaBrowser(api);
      if (renewed != null) {
        setState(() =>
            _sessionLabel = 'u/${renewed.authUser} - ${renewed.email}');
        _snack(
            'Gemini session active on u/${renewed.authUser} (${renewed.email})');
        return;
      }
      final explicit =
          _accountMode == 'auto' ? null : int.tryParse(_accountMode);
      final s =
          await api.getSession(forceRefresh: true, explicitAuthUser: explicit);
      setState(() => _sessionLabel = 'u/${s.authUser} - ${s.email}');
      _snack('Gemini session active on u/${s.authUser} (${s.email})');
    } catch (e) {
      _snack('Session check failed: $e');
      _onStatus(StatusEvent('error', 1, 'Session check failed: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanAccounts() async {
    if (_busy) return;
    setState(() => _busy = true);
    _onStatus(const StatusEvent('authenticating', 1,
        'Scanning saved logins for signed-in Gmail / Gemini accounts (u/0 to u/5)...'));
    try {
      final api = GeminiApi(onStatus: _onStatus);
      final found = await api.scanAccounts();
      setState(() => _accounts = found);
      if (found.isEmpty) {
        _snack(
            'No signed-in Gemini accounts detected. Use Gemini Login first.');
      } else {
        _snack(
            'Detected ${found.length} signed-in Gmail account(s): ${found.map((a) => 'u/${a.authUser} (${a.email})').join(', ')}');
      }
    } catch (e) {
      _snack('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLogin({int authUser = 0}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LoginScreen(initialAuthUser: authUser),
    ));
    await _bootstrap();
    try {
      final api = GeminiApi();
      final found = await api.scanAccounts();
      // v139 — never overwrite a valid browser-verified account list
      // with an empty result when Dart scanAccounts() is bot-blocked.
      if (found.isNotEmpty && mounted) setState(() => _accounts = found);
    } catch (_) {}
  }

  Future<void> _pickReference() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    if (f.bytes == null) return;
    final lower = f.name.toLowerCase();
    final mime = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg';
    setState(() => _reference = (bytes: f.bytes!, name: f.name, mime: mime));
  }

  /// Image Search screen (sources open in the external browser;
  /// image links come back through its collection panel). The
  /// returned pick is applied by action: reference -> anchor image,
  /// prompt -> the prompt generated inside the search screen fills
  /// the designer field, save -> a copy under app documents
  /// /GeminiHDStudio/Search/.
  Future<void> _openImageSearch({bool promptMode = false}) async {
    final pick = await Navigator.of(context).push<ImageSearchPick>(
        MaterialPageRoute(
            builder: (_) => ImageSearchScreen(promptMode: promptMode)));
    if (pick == null || !mounted) return;
    switch (pick.action) {
      case 'reference':
        setState(() => _reference =
            (bytes: pick.bytes, name: pick.name, mime: pick.mime));
        _snack('Reference image set from Image Search.');
        break;
      case 'prompt':
        final generated = pick.generatedPrompt?.trim() ?? '';
        if (generated.isNotEmpty) {
          if (pick.appendPrompt) {
            // Auto-add to Prompts list: a new row, so the prompt
            // joins the batch list instead of replacing it.
            setState(() => _addPromptRows([generated]));
            _snack('Prompt added to the Prompts list.');
          } else {
            // Replace the focused row (or the first row).
            final i =
                _focusedPromptIndex.clamp(0, _promptCtrls.length - 1);
            setState(() => _promptCtrls[i].text = generated);
            _snack('Prompt set.');
          }
        } else {
          _snack('No prompt was generated.');
        }
        break;
      case 'prompts':
        // Multi-select batch generation: one prompt per selected
        // image — one row each, so they land straight in the
        // Batch Sets queue (two or more rows IS batch mode).
        final list = pick.generatedPrompts
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (list.isEmpty) {
          _snack('No prompts were generated.');
          break;
        }
        setState(() => _addPromptRows(list));
        _snack('${list.length} prompts added to the Batch Sets box.');
        break;
      case 'save':
        try {
          final docs = await getApplicationDocumentsDirectory();
          final dir = Directory(p.join(docs.path, 'GeminiHDStudio', 'Search'));
          await dir.create(recursive: true);
          final file = File(p.join(dir.path, pick.name));
          await file.writeAsBytes(pick.bytes);
          _snack('Saved image copy: ${file.path}');
        } catch (e) {
          _snack('Save failed: $e');
        }
        break;
    }
  }

  List<String?> _customStagesFor(int count) {
    return List.generate(count, (i) {
      final t = _stageCtrls[i]?.text.trim() ?? '';
      return t.isEmpty ? null : t;
    });
  }

  /// Background readiness gate (v72, steps corrected v76+v78):
  /// before a generation starts, check whether the phone will
  /// kill it when the screen locks. If not exempt, offer the fix
  /// once per session — the system exemption screen, or the app
  /// settings page. HiOS keeps Auto-start inside the Phone Master
  /// app — on his CAMON 30S (PM 6.x grid home, no Toolbox tab)
  /// it lives under the "App Management" / "Battery Optimization"
  /// cards, or via the Settings search for "Auto-start".
  /// Generation itself is never blocked: "Pore" runs it anyway,
  /// and the amber banner stays until the phone is exempt. Returns
  /// the current exemption state.
  Future<bool> _ensureBackgroundReady() async {
    final exempt = await ForegroundKeepAlive.isBatteryExempt();
    if (exempt ||
        !ForegroundKeepAlive.enabled ||
        _bgDialogShownThisSession) {
      return exempt;
    }
    _bgDialogShownThisSession = true;
    final maker = await ForegroundKeepAlive.getManufacturer();
    final transsion = <String>['tecno', 'infinix', 'itel', 'transsion']
        .any((m) => maker.toLowerCase().contains(m));
    if (!mounted) return exempt;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Background generation chalu rakho'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Phone lock korle ba onno app-e gele generation thambe, jodi ei permission-ta na dao.'),
              const SizedBox(height: 12),
              const Text(
                  '1. "Allow koro" chaple system-er screen khulbe — okhane "Allow" / "No restrictions" select koro.'),
              if (transsion) ...[
                const SizedBox(height: 8),
                const Text(
                    '2. TECNO / Infinix phone-e aro dorkar: Phone Master-e "App Management" ba "Battery Optimization" card kholo — vitore Auto-start / Power Saving Management-e Zedge Studio ON / No restrictions koro. Na pele Settings app-er search-e "Auto-start" likhe khujo.'),
                const SizedBox(height: 8),
                const Text(
                    '3. Recents (square button) chaple Zedge Studio-r card-e 🔒 lock chap dao.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'later'),
              child: const Text('Pore')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'settings'),
              child: const Text('Settings kholo')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'allow'),
              child: const Text('Allow koro')),
        ],
      ),
    );
    if (action == 'allow') {
      await ForegroundKeepAlive.requestBatteryExemption();
    } else if (action == 'settings') {
      await ForegroundKeepAlive.openAppSettings();
    }
    final nowExempt = await ForegroundKeepAlive.isBatteryExempt();
    return nowExempt;
  }

  Future<void> _generate() async {
    if (_busy) return;
    final prompts = _promptTexts;
    if (prompts.isEmpty || prompts.first.isEmpty) {
      _snack('Write a prompt first.');
      return;
    }
    setState(() {
      _busy = true;
      _activeStep = 0;
    });
    // Keep the whole run (single or batch) alive in the
    // background — screen off / other apps must not kill it (v33).
    await _ensureBackgroundReady();
    await ForegroundKeepAlive.acquire(
        'Generating in the background — safe to switch apps');
    final isSetMode =
        _mode == 'set_dual' || _mode == 'set_24h' || _mode == 'set_battery';
    final stageCount = isSetMode ? stagesForMode(_mode).length : 0;
    if (_batchMode) {
      setState(() {
        _batchStatuses = List.filled(prompts.length, 'waiting');
        _batchStop = false;
      });
    }
    var doneCount = 0;
    var failCount = 0;
    try {
      for (var i = 0; i < prompts.length; i++) {
        if (_batchMode && _batchStop) {
          _onStatus(StatusEvent('done', 4,
              'Batch stopped: $doneCount of ${prompts.length} sets done.'));
          break;
        }
        if (_batchMode) {
          setState(() => _batchStatuses[i] = 'running');
          _onStatus(StatusEvent('generating', 1,
              'Batch ${i + 1}/${prompts.length}: ${prompts[i]}'));
        }
        try {
          final entry = await _engine.generateSet(
          prompt: prompts[i],
          negativePrompt: _negativeCtrl.text,
          workflowMode: _mode,
          customStages: isSetMode ? _customStagesFor(stageCount) : const [],
          storyArc: _storyArc,
          variationStrength: _variation,
          displayTarget: _displayTarget,
          colorBoost: _colorBoost,
          aiDirectorEnabled: _aiDirector,
          autoWriteMetadata: _autoMetadata,
          includeFoldableCompanion: _foldableCompanion && isSetMode,
          referenceBytes: _reference?.bytes,
          referenceFilename: _reference?.name ?? 'reference_image.jpg',
          referenceMime: _reference?.mime ?? 'image/jpeg',
          forceImagePrefix: _forcePrefix,
          upscaleEnabled: _upscale,
          useExactZedgeNames: _useExactNames,
          subfolder: _subfolderCtrl.text.trim().isEmpty
              ? 'Gemini_HD'
              : _subfolderCtrl.text.trim(),
          portraitWidth: _portraitW,
          portraitHeight: _portraitH,
          landscapeWidth: _landscapeW,
          landscapeHeight: _landscapeH,
        );
          setState(() {
            _history = [entry, ..._history];
            if (_batchMode) _batchStatuses[i] = 'done';
          });
          // v85: the new set is below the prompt — scroll to it.
          _scrollToResults();
          doneCount++;
        } catch (e) {
          if (!_batchMode) rethrow;
          failCount++;
          setState(() => _batchStatuses[i] = 'failed');
          _onStatus(StatusEvent(
              'error', 1, 'Batch ${i + 1}/${prompts.length} failed: $e'));
        }
      }
      if (_batchMode && prompts.length > 1) {
        _snack(failCount == 0
            ? 'Batch finished: $doneCount sets generated.'
            : 'Batch finished: $doneCount done, $failCount failed.');
      }
    } catch (e) {
      _onStatus(StatusEvent('error', 1, 'Generation failed: $e'));
      _snack('Generation failed: $e');
    } finally {
      await ForegroundKeepAlive.release();
      if (mounted) setState(() => _busy = false);
    }
  }


  // -------------------------------------------------------------------
  // Overnight queue (v47)
  // -------------------------------------------------------------------

  static const _queuePrefsKey = 'overnightQueueV47';
  static const _queueSummaryPrefsKey = 'overnightQueueSummaryV47';

  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _queue
        ..clear()
        ..addAll(QueueItem.decodeList(prefs.getString(_queuePrefsKey)));
      final rawSummary = prefs.getString(_queueSummaryPrefsKey);
      if (rawSummary != null) {
        final decoded = jsonDecode(rawSummary);
        if (decoded is Map) {
          _queueSummary = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
  }

  Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queuePrefsKey, QueueItem.encodeList(_queue));
    } catch (_) {}
  }

  Future<void> _persistQueueSummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = _queueSummary;
      if (s == null) {
        await prefs.remove(_queueSummaryPrefsKey);
      } else {
        await prefs.setString(_queueSummaryPrefsKey, jsonEncode(s));
      }
    } catch (_) {}
  }

  /// Snapshot the designer's current settings into a queue item —
  /// the same mapping _generate() uses, minus the reference image
  /// (bytes are not persisted).
  QueueItem _snapshotItem(String prompt) {
    final isSetMode =
        _mode == 'set_dual' || _mode == 'set_24h' || _mode == 'set_battery';
    final stageCount = isSetMode ? stagesForMode(_mode).length : 0;
    return QueueItem(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_queue.length}',
      prompt: prompt,
      negativePrompt: _negativeCtrl.text,
      workflowMode: _mode,
      customStages: isSetMode ? _customStagesFor(stageCount) : const [],
      storyArc: _storyArc,
      variationStrength: _variation,
      displayTarget: _displayTarget,
      colorBoost: _colorBoost,
      aiDirectorEnabled: _aiDirector,
      autoWriteMetadata: _autoMetadata,
      includeFoldableCompanion: _foldableCompanion && isSetMode,
      forceImagePrefix: _forcePrefix,
      upscaleEnabled: _upscale,
      useExactZedgeNames: _useExactNames,
      subfolder: _subfolderCtrl.text.trim().isEmpty
          ? 'Gemini_HD'
          : _subfolderCtrl.text.trim(),
      portraitWidth: _portraitW,
      portraitHeight: _portraitH,
      landscapeWidth: _landscapeW,
      landscapeHeight: _landscapeH,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _addToQueue() {
    final prompts = _promptTexts;
    if (prompts.isEmpty || prompts.first.isEmpty) {
      _snack('Write a prompt first.');
      return;
    }
    for (final p in prompts) {
      _queue.add(_snapshotItem(p));
    }
    _persistQueue();
    _queueTick.value++;
    setState(() {});
    final refNote =
        _reference != null ? ' (reference image is not kept in the queue)' : '';
    _snack(prompts.length == 1
        ? 'Added to the overnight queue$refNote.'
        : '${prompts.length} sets added to the overnight queue$refNote.');
  }

  Future<void> _runQueue() async {
    if (_busy || _queueRunning) return;
    final pending = _queue.where((q) => q.status == 'pending').toList();
    if (pending.isEmpty) {
      _snack('Nothing pending in the queue.');
      return;
    }
    setState(() {
      _queueRunning = true;
      _queueStop = false;
      _busy = true;
      _queueLiveStatus = 'Starting queue...';
    });
    _queueTick.value++;
    await _ensureBackgroundReady();
    await ForegroundKeepAlive.acquire(
        'Overnight queue running — safe to switch apps');
    var done = 0;
    var failed = 0;
    try {
      for (final item in pending) {
        if (_queueStop) break;
        item.status = 'running';
        item.error = '';
        await _persistQueue();
        _queueTick.value++;
        if (mounted) setState(() {});
        try {
          final entry = await _engine.generateSet(
            prompt: item.prompt,
            negativePrompt: item.negativePrompt,
            workflowMode: item.workflowMode,
            customStages: item.customStages,
            storyArc: item.storyArc,
            variationStrength: item.variationStrength,
            displayTarget: item.displayTarget,
            colorBoost: item.colorBoost,
            aiDirectorEnabled: item.aiDirectorEnabled,
            autoWriteMetadata: item.autoWriteMetadata,
            includeFoldableCompanion: item.includeFoldableCompanion,
            forceImagePrefix: item.forceImagePrefix,
            upscaleEnabled: item.upscaleEnabled,
            useExactZedgeNames: item.useExactZedgeNames,
            subfolder: item.subfolder,
            portraitWidth: item.portraitWidth,
            portraitHeight: item.portraitHeight,
            landscapeWidth: item.landscapeWidth,
            landscapeHeight: item.landscapeHeight,
          );
          item.status = 'done';
          done++;
          if (mounted) setState(() => _history = [entry, ..._history]);
        } catch (e) {
          var msg = '$e';
          if (msg.length > 140) msg = msg.substring(0, 140);
          item.status = 'failed';
          item.error = msg;
          failed++;
        }
        await _persistQueue();
        _queueTick.value++;
        if (mounted) setState(() {});
      }
    } finally {
      await ForegroundKeepAlive.release();
      if (mounted) {
        setState(() {
          _queueRunning = false;
          _busy = false;
        });
      } else {
        _queueRunning = false;
        _busy = false;
      }
    }
    if (done + failed > 0) {
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      _queueSummary = {
        'done': done,
        'failed': failed,
        'total': pending.length,
        'at': '${now.day}/${now.month} $hh:$mm',
      };
      await _persistQueueSummary();
      _queueTick.value++;
      await ForegroundKeepAlive.notifyDone(
        'Zedge Studio — queue finished',
        '$done set(s) done${failed > 0 ? ', $failed failed' : ''} — open the app to see them',
      );
      _snack('Queue finished: $done done, $failed failed.');
      // v85: show the finished sets below the prompt.
      _scrollToResults();
      if (mounted) setState(() {});
    }
  }

  void _removeQueueItem(QueueItem item) {
    if (_queueRunning) return;
    setState(() => _queue.remove(item));
    _persistQueue();
    _queueTick.value++;
  }

  void _retryFailedQueue() {
    for (final q in _queue) {
      if (q.status == 'failed') {
        q.status = 'pending';
        q.error = '';
      }
    }
    _persistQueue();
    _queueTick.value++;
    setState(() {});
  }

  void _clearDoneQueue() {
    setState(() => _queue.removeWhere((q) => q.status == 'done'));
    _persistQueue();
    _queueTick.value++;
  }

  Widget _queueBar() {
    final pending = _queue.where((q) => q.status == 'pending').length;
    final failed = _queue.where((q) => q.status == 'failed').length;
    final s = _queueSummary;
    final text = _queueRunning
        ? 'Overnight queue running...'
        : pending > 0
            ? 'Overnight queue: $pending pending'
                '${failed > 0 ? ' · $failed failed' : ''}'
            : s != null
                ? 'Last queue run: ${s['done']} done'
                    '${(s['failed'] as int) > 0 ? ' · ${s['failed']} failed' : ''}'
                    ' · ${s['at']}'
                : 'Overnight queue';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _openQueue,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.nightlight_round,
                size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text, style: const TextStyle(fontSize: 12.5))),
            Icon(Icons.chevron_right,
                size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _openQueue() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: const Text('Overnight Queue')),
        body: AnimatedBuilder(
          animation: _queueTick,
          builder: (ctx, _) => _queuePageBody(),
        ),
      ),
    ));
  }

  Widget _queuePageBody() {
    final pending = _queue.where((q) => q.status == 'pending').length;
    final failedCount = _queue.where((q) => q.status == 'failed').length;
    final hasDone = _queue.any((q) => q.status == 'done');
    final s = _queueSummary;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                      'Last run (${s['at']}): ${s['done']} done, '
                      '${s['failed']} failed of ${s['total']}',
                      style: TextStyle(
                          fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              if (_queueRunning && _queueLiveStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_queueLiveStatus,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              FilledButton.icon(
                onPressed: _queueRunning
                    ? (_queueStop
                        ? null
                        : () => setState(() => _queueStop = true))
                    : (pending == 0 || _busy ? null : _runQueue),
                icon: Icon(_queueRunning
                    ? Icons.stop_circle_outlined
                    : Icons.play_arrow),
                label: Text(_queueRunning
                    ? (_queueStop
                        ? 'Stopping after this set...'
                        : 'Stop after current set')
                    : 'Start queue ($pending pending)'),
              ),
              if (!_queueRunning && failedCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    onPressed: _retryFailedQueue,
                    icon: const Icon(Icons.replay, size: 17),
                    label: Text('Retry failed ($failedCount)'),
                  ),
                ),
              if (!_queueRunning && hasDone)
                TextButton(
                  onPressed: _clearDoneQueue,
                  child: const Text('Clear finished'),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'Sets run one by one, each with the settings it was '
                    'added with. A failed stage retries once on its own. '
                    'Best overnight: plug the phone in and start the queue.',
                    style:
                        TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _queue.isEmpty
              ? const Center(
                  child: Text(
                      'Queue is empty.\nAdd sets from the Set Designer.',
                      textAlign: TextAlign.center),
                )
              : ListView.builder(
                  itemCount: _queue.length,
                  itemBuilder: (ctx, i) => _queueTile(_queue[i]),
                ),
        ),
      ],
    );
  }

  Widget _queueTile(QueueItem item) {
    final (icon, color) = switch (item.status) {
      'done' => (Icons.check_circle, const Color(0xFF4ADE80)),
      'failed' => (Icons.error_outline, const Color(0xFFF87171)),
      'running' => (Icons.autorenew, Theme.of(context).colorScheme.primary),
      _ => (Icons.schedule, Theme.of(context).colorScheme.onSurfaceVariant),
    };
    return ListTile(
      leading: item.status == 'running'
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, color: color, size: 20),
      title: Text(item.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
          item.status == 'failed' && item.error.isNotEmpty
              ? '${item.modeLabel} · ${item.error}'
              : '${item.modeLabel} · ${item.status}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5)),
      trailing: (_queueRunning || item.status == 'running')
          ? null
          : IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _removeQueueItem(item),
            ),
    );
  }


  /// v48: rewrite the designer's prompt (or every batch row)
  /// into a detailed pro prompt via Gemini, with an Undo in the
  /// confirmation SnackBar. A failed row aborts the polish and
  /// keeps the original text untouched. (v115: triggered by the
  /// wand icon inside the focused prompt row, not a button.)
  Future<void> _polishPrompt() async {
    if (_busy || _polishing) return;
    // Non-empty row indices, so the polished text lands back in
    // the same rows it came from.
    final indices = [
      for (var i = 0; i < _promptCtrls.length; i++)
        if (_promptCtrls[i].text.trim().isNotEmpty) i,
    ];
    if (indices.isEmpty) {
      _snack('Write a prompt first.');
      return;
    }
    final originals = [for (final i in indices) _promptCtrls[i].text];
    setState(() => _polishing = true);
    try {
      final polished = <String>[];
      for (var j = 0; j < originals.length; j++) {
        if (originals.length > 1) {
          _onStatus(StatusEvent('generating', 1,
              'Polishing prompt ${j + 1}/${originals.length}...'));
        }
        polished.add(await _engine.polishPrompt(originals[j].trim()));
      }
      if (!mounted) return;
      setState(() {
        for (var j = 0; j < indices.length; j++) {
          _promptCtrls[indices[j]].text = polished[j];
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(originals.length > 1
            ? '${originals.length} prompts polished.'
            : 'Prompt polished.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (mounted) {
              setState(() {
                for (var j = 0; j < indices.length; j++) {
                  _promptCtrls[indices[j]].text = originals[j];
                }
              });
            }
          },
        ),
      ));
    } catch (e) {
      _snack('Polish failed: $e');
    } finally {
      if (mounted) setState(() => _polishing = false);
    }
  }

  Future<void> _importSet() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final files = res.files
        .where((f) => f.bytes != null)
        .map((f) => (bytes: f.bytes!, filename: f.name))
        .toList();
    if (files.isEmpty || !mounted) return;
    final mode =
        (_mode == 'single' || _mode == 'dual_single') ? 'set_24h' : _mode;
    // The import concept starts from the focused row's prompt
    // (or the first non-empty row when it is blank).
    final conceptText = _focusedPromptIndex < _promptCtrls.length &&
            _promptCtrls[_focusedPromptIndex].text.trim().isNotEmpty
        ? _promptCtrls[_focusedPromptIndex].text.trim()
        : (_promptTexts.isEmpty ? '' : _promptTexts.first);
    final conceptCtrl = TextEditingController(text: conceptText);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import set'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${files.length} image(s) selected. They are formatted to ${_portraitW}x$_portraitH JPG and land in the Showcase as a ${setTypeLabelFor(mode)}.'),
            const SizedBox(height: 12),
            TextField(
              controller: conceptCtrl,
              decoration: const InputDecoration(
                labelText: 'Set concept (for AI metadata)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final entry = await _engine.importLocalSet(
        files: files,
        workflowMode: mode,
        prompt: conceptCtrl.text.trim(),
        upscaleEnabled: _upscale,
        autoWriteMetadata: _autoMetadata,
        subfolder: _subfolderCtrl.text.trim().isEmpty
            ? 'Gemini_HD'
            : _subfolderCtrl.text.trim(),
        portraitWidth: _portraitW,
        portraitHeight: _portraitH,
      );
      setState(() => _history = [entry, ..._history]);
    } catch (e) {
      _snack('Import failed: $e');
      _onStatus(StatusEvent('error', 1, 'Import failed: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshHistory() async {
    final h = await _engine.loadHistory();
    if (mounted) setState(() => _history = h);
  }

  Future<void> _clearHistory() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Showcase?'),
        content: const Text(
            'This removes the set list from the app. Image files stay in the app documents folder.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (go == true) {
      await _engine.saveHistory([]);
      setState(() => _history = []);
    }
  }

  void _showPathDialog(String title, String path) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(path),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              Navigator.pop(ctx);
            },
            child: const Text('Copy path'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  // Charging Animation (v86): the section drives the user's own
  // signed-in Gemini session — Neon default, Task mode — through
  // the in-page video driver; the engine owns the job.
  Future<void> _generateAnimation(String prompt, String modelId) async {
    // Video generation is Android-only in v86: the driver is the
    // Gecko content script, and Windows uses Chromium/CDP instead.
    // The section UI (gallery + ZIP) still works on Windows.
    if (defaultTargetPlatform != TargetPlatform.android) {
      _snack('Video generation ekhon Android app-e.');
      return;
    }
    await _animEngine.start(
      rawPrompt: prompt,
      modelId: modelId,
      signedIn: _isSignedIn,
    );
  }

  void _playAnimation(AnimationVideo video) {
    // No new player plugin in v86: the in-app Gecko browser plays
    // the local MP4 with its built-in HTML5 player.
    GeckoBrowser.instance.open('file://${video.localPath}');
  }

  // v141 — a finished video opens in the device-frame preview
  // (video_player inside the phone mockup, looping, muted) so he
  // sees the live wallpaper on a device; the in-app browser open
  // stays as the fallback button in the preview dialog.
  void _previewAnimationVideo(AnimationVideo video) {
    final title =
        video.title.isNotEmpty ? video.title : video.prompt;
    showDeviceVideoPreview(
      context,
      videoPath: video.localPath,
      title: title,
      onOpenInBrowser: () => _playAnimation(video),
    );
  }

  Future<void> _deleteAnimation(AnimationVideo video) async {
    await _animEngine.deleteVideo(video);
    _snack('Animation deleted.');
  }

  // v87 — per-video AI metadata + panel upload, mirroring the
  // image sets. The account picker is the same SimpleDialog the
  // image upload uses (spread + named accounts, remembered).
  Future<void> _generateAnimationMetadata(AnimationVideo video) async {
    await _animEngine.generateMetadataForVideo(video);
  }

  Future<String?> _pickPanelTarget() async {
    var target = _animUploadTarget;
    final cfg = await _engine.loadDistConfig();
    if (!mounted) return null;
    if (cfg.accounts.isEmpty) return target;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Upload to Panel'),
        children: [
          for (final t in [
            'spread',
            ...cfg.accounts.map((a) => a.name),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Row(
                children: [
                  Icon(
                    t == target
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(t == 'spread' ? 'Spread (Auto-Rotate)' : t),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null) return null;
    if (mounted) setState(() => _animUploadTarget = picked);
    return picked;
  }

  Future<void> _uploadAnimationToPanel(AnimationVideo video) async {
    final target = await _pickPanelTarget();
    if (target == null) return;
    final ok = await _animEngine.uploadVideoToPanel(video,
        targetAccount: target);
    if (!mounted) return;
    if (ok) {
      AnimationVideo? fresh;
      for (final x in _animEngine.videos) {
        if (x.id == video.id) fresh = x;
      }
      _snack('Uploaded to ${fresh?.uploadedAccount ?? target}.');
    } else {
      _snack(_animEngine.status);
    }
  }

  Future<void> _uploadAllAnimationsToPanel() async {
    if (_animEngine.videos.isEmpty) {
      _snack('No animations to upload.');
      return;
    }
    final target = await _pickPanelTarget();
    if (target == null) return;
    final done =
        await _animEngine.uploadAllToPanel(targetAccount: target);
    if (!mounted) return;
    _snack('$done/${_animEngine.videos.length} videos uploaded to Panel.');
  }

  Future<void> _exportAnimationsZip() async {
    if (_animEngine.videos.isEmpty) {
      _snack('No animations to export.');
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await _animEngine.buildVideosZip();
      final bytes = await f.readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Animations ZIP',
        fileName: p.basename(f.path),
        bytes: bytes,
      );
      if (!mounted) return;
      if (savedPath != null) {
        _showPathDialog('Animations ZIP saved', savedPath);
      } else {
        _snack('Save cancelled — the ZIP is still in the app folder.');
      }
    } catch (e) {
      _snack('ZIP failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportZip(List<SetEntry> entries) async {
    if (entries.isEmpty) {
      _snack('No sets to export.');
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await _engine.buildReadyZip(entries,
          useHubSetFolders: _useHubFolders);
      // v74: the ZIP used to land in the app's PRIVATE folder, which
      // no file manager and no Downloads can see — the user only got
      // a path dialog, so from his side the download never happened.
      // Now open the system save picker so he picks the folder
      // (Downloads) himself; the picker is the download on Android.
      final bytes = await f.readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Ready ZIP',
        fileName: p.basename(f.path),
        bytes: bytes,
      );
      if (!mounted) return;
      if (savedPath != null) {
        _showPathDialog('Ready ZIP saved', savedPath);
      } else {
        _snack('Save cancelled — the ZIP is still in the app folder.');
      }
    } catch (e) {
      _snack('ZIP failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeAllMetadata() async {
    if (_busy || _history.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final entry in _history) {
        if (entry.metadata == null || entry.metadata!.title.isEmpty) {
          await _engine.generateMetadataForEntry(entry);
        }
      }
      await _refreshHistory();
    } catch (e) {
      _snack('Metadata failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadAllToPanel() async {
    if (_busy || _history.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final entry in _history) {
        await _engine.uploadSetToPanel(entry);
      }
      await _refreshHistory();
      _snack('All sets uploaded to Panel.');
    } catch (e) {
      _snack('Panel upload failed: $e');
      _onStatus(StatusEvent('error', 4, 'Panel upload failed: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------
  // Dashboard shell: gradient header + badge navigation + tab body
  // -------------------------------------------------------------------

  void _onNavSelected(int i) {
    // v86: Studio (0) and Animation (1) are real tabs; Search /
    // Login open as routes on top. (v85: only Studio was a tab —
    // the Showcase moved under the designer.)
    if (i == 0) {
      setState(() => _tab = 0);
    } else if (i == 1) {
      setState(() => _tab = 1);
    } else if (i == 2) {
      _openImageSearch();
    } else if (i == 3) {
      _openLogin();
    }
  }

  /// Scroll the phone Studio screen down to the generated sets
  /// (v85) — called after a generation finishes, so the new set
  /// shows without hunting for it.
  void _scrollToResults() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _resultsKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut);
      }
    });
  }

  /// Scroll the phone Studio screen back up to the prompt (v85).
  void _scrollStudioToTop() {
    if (_studioScrollCtrl.hasClients) {
      _studioScrollCtrl.animateTo(0,
          duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }
  }

  Widget _navIcon(IconData icon, int badgeCount) {
    if (badgeCount <= 0) return Icon(icon);
    return Badge(
      label: Text('$badgeCount'),
      backgroundColor: kDashboardScheme.tertiary,
      textColor: Colors.white,
      child: Icon(icon),
    );
  }

  List<NavigationDestination> get _destinations => [
        const NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: 'Studio',
        ),
        const NavigationDestination(
          icon: Icon(Icons.movie_creation_outlined),
          selectedIcon: Icon(Icons.movie_creation),
          label: 'Animation',
        ),
        const NavigationDestination(
          icon: Icon(Icons.image_search_outlined),
          selectedIcon: Icon(Icons.image_search),
          label: 'Search',
        ),
        NavigationDestination(
          icon: _navIcon(Icons.account_circle_outlined, _accounts.length),
          selectedIcon: _navIcon(Icons.account_circle, _accounts.length),
          label: 'Login',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          const AuroraBackdrop(),
          SafeArea(
            child: Column(
              children: [
                _appBar(wide),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    NavigationRail(
                      selectedIndex: _tab,
                      onDestinationSelected: _onNavSelected,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final d in _destinations)
                          NavigationRailDestination(
                            icon: d.icon,
                            selectedIcon: d.selectedIcon,
                            label: Text(d.label),
                          ),
                      ],
                    ),
                Expanded(
                  child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                                  begin: const Offset(0.03, 0),
                                  end: Offset.zero)
                              .animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_tab),
                        child: _tabBody(wide),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
        ],
      ),
      // v139 — generate-main clean edge-to-edge Material 3 NavigationBar.
      bottomNavigationBar: wide
          ? null
          : Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: NavigationBar(
                height: 66,
                selectedIndex: _tab,
                onDestinationSelected: _onNavSelected,
                destinations: _destinations,
              ),
            ),
    );
  }

  Widget _tabBody(bool wide) {
    // v86: the Animation tab is its own section (prompt card on
    // top, finished videos below — same phone/wide split as
    // Studio). Search / Login are pushed routes, not tabs.
    if (_tab == 1) {
      return AnimationSection(
        engine: _animEngine,
        signedIn: _isSignedIn,
        wide: wide,
        onGenerate: _generateAnimation,
        onPlay: _previewAnimationVideo,
        onDelete: _deleteAnimation,
        onExportZip: _exportAnimationsZip,
        onMetadata: _generateAnimationMetadata,
        onUploadToPanel: _uploadAnimationToPanel,
        onUploadAllToPanel: _uploadAllAnimationsToPanel,
      );
    }
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 430, child: _designerPanel()),
          const VerticalDivider(width: 1),
          Expanded(child: _showcasePanel()),
        ],
      );
    }
    // v85: one Studio screen — the prompt + designer on top, the
    // generated sets below, in a single scroll view. The Showcase
    // tab is gone; its panel lives inline under the designer.
    return SingleChildScrollView(
      controller: _studioScrollCtrl,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _designerCard(),
          const SizedBox(height: 12),
          _showcaseInline(),
        ],
      ),
    );
  }

  /// Reference-style app bar (v111 redesign): the reference's
  /// main screen has NO title text — just the round logo and four
  /// icons on the right. So the bar is logo + 4 function icons
  /// now: Import local set, Panel upload settings, theme toggle
  /// (moved up from the deleted account strip), and a settings
  /// gear holding the account actions (Scan / Add Gmail /
  /// Verify / Switch account) + the version label. The title,
  /// subtitle and version text are gone from here; the version
  /// still shows on the Login screen ('App vX.Y.Z') and in the
  /// gear menu. The old Gemini Login icon stays out on purpose:
  /// Login is already a bottom-nav / rail destination.
  Widget _appBar(bool wide) {
    final cs = Theme.of(context).colorScheme;
    final isDark = themeModeNotifier.value == ThemeMode.dark;
    final logoSize = wide ? 24.0 : 28.0;
    final iconBox = wide ? 28.0 : 32.0;
    final iconSize = wide ? 16.0 : 18.0;
    return Container(
      key: const ValueKey('appBar'),
      padding: EdgeInsets.fromLTRB(12, wide ? 6 : 8, 12, wide ? 6 : 8),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: cs.onSurface.withValues(alpha: 0.1))),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/logo.png',
              width: logoSize,
              height: logoSize,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
          // v111 — no title column: the reference's main screen
          // shows only the logo + icons, so the bar is logo,
          // a spacer, then the four function icons.
          const Spacer(),
          IconButton(
            tooltip: 'Import local set',
            constraints:
                BoxConstraints(maxWidth: iconBox, maxHeight: iconBox),
            padding: EdgeInsets.zero,
            iconSize: iconSize,
            color: cs.onSurface,
            onPressed: _busy ? null : _importSet,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: 'Panel upload settings',
            constraints:
                BoxConstraints(maxWidth: iconBox, maxHeight: iconBox),
            padding: EdgeInsets.zero,
            iconSize: iconSize,
            color: cs.onSurface,
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PanelSettingsScreen(engine: _engine)));
            },
            icon: const Icon(Icons.cloud_upload_outlined),
          ),
          const SizedBox(width: 4),
          // v111 — theme toggle moved up from the deleted account
          // strip (same key, same tooltips, so the theme tests
          // keep finding it).
          SizedBox(
            width: 28,
            height: 28,
            child: Tooltip(
              message: isDark ? 'Light theme' : 'Dark theme',
              child: InkWell(
                key: const ValueKey('themeToggle'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => toggleTheme(),
                child: Icon(
                    isDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    size: 18,
                    color: cs.onSurface),
              ),
            ),
          ),
          // v111 — account actions behind the reference's gear
          // icon (was the strip's ⋮ menu): Scan / Add Gmail /
          // Verify / Switch account, plus the version label as a
          // disabled row (the version text left the bar itself).
          PopupMenuButton<String>(
            tooltip: 'Account actions',
            padding: EdgeInsets.zero,
            color: cs.surfaceContainer,
            icon: Icon(Icons.settings_outlined,
                size: 18, color: cs.onSurface),
            onSelected: (v) async {
              if (v == 'scan') {
                if (!_busy) await _scanAccounts();
              } else if (v == 'add') {
                _openLogin(
                    authUser: _accountMode == 'auto'
                        ? 0
                        : int.tryParse(_accountMode) ?? 0);
              } else if (v == 'verify') {
                if (!_busy) await _verifySession();
              } else if (v == 'switch') {
                _openLogin();
              }
            },
            itemBuilder: (ctx) => [
              // v111 — the session status lives here now (the
              // strip is gone): the current account, or
              // 'Not connected', as a disabled header row.
              PopupMenuItem(
                enabled: false,
                child: Text(_sessionLabel,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              ),
              const PopupMenuItem(
                value: 'scan',
                child: Row(
                  children: [
                    Icon(Icons.search, size: 18),
                    SizedBox(width: 10),
                    Text('Scan'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'add',
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18),
                    SizedBox(width: 10),
                    Text('Add Gmail'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'verify',
                child: Row(
                  children: [
                    Icon(Icons.verified_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Verify'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'switch',
                child: Row(
                  children: [
                    Icon(Icons.switch_account_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Switch account'),
                  ],
                ),
              ),
              PopupMenuItem(
                enabled: false,
                child: Text('Version 2.5.85',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statChip(IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 14, color: cs.secondary),
      label: Text(label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurface)),
      backgroundColor: cs.onSurface.withValues(alpha: 0.13),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }

  // -------------------------------------------------------------------
  // Batch queue panel (batch mode): every prompt line is one job with
  // a live status — waiting / running / done / failed — plus a Stop
  // control that lets the current set finish and skips the rest.
  // -------------------------------------------------------------------

  Widget _batchQueuePanel() {
    final prompts = _promptTexts;
    final scheme = Theme.of(context).colorScheme;
    if (prompts.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Batch mode: add one prompt per row — each row generates one full set, in order.',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    final done = _batchStatuses.where((s) => s == 'done').length;
    final running = _busy && _batchMode;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              const Text('Batch queue',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(width: 8),
              Chip(
                label: Text(_batchStatuses.isEmpty
                    ? '${prompts.length} set${prompts.length == 1 ? '' : 's'}'
                    : '$done/${prompts.length} done'),
                visualDensity: VisualDensity.compact,
                labelStyle: const TextStyle(fontSize: 11),
              ),
              const Spacer(),
              if (running)
                TextButton.icon(
                  onPressed: () => setState(() => _batchStop = true),
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('Stop after current',
                      style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: prompts.length,
              itemBuilder: (ctx, i) {
                final st = i < _batchStatuses.length
                    ? _batchStatuses[i]
                    : 'waiting';
                final (icon, color) = switch (st) {
                  'running' => (Icons.autorenew, scheme.primary),
                  'done' => (Icons.check_circle, Colors.green),
                  'failed' => (Icons.error, scheme.error),
                  _ => (Icons.schedule, Theme.of(context).colorScheme.onSurfaceVariant),
                };
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                      if (st == 'running')
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(icon, size: 16, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          prompts[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: st == 'waiting'
                                ? Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(st,
                          style: TextStyle(fontSize: 11, color: color)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // -------------------------------------------------------------------
  // Prompt rows (v112): one numbered row per prompt. Add / remove /
  // paste / clear keep the row list in sync; the batch queue panel
  // and the generation loop read _promptTexts, never the rows.
  // -------------------------------------------------------------------

  /// Fill the first empty row with [prompts] (in order), then
  /// append the rest as new rows. Used by Paste list and by the
  /// image-search prompt import. (No setState here — callers
  /// wrap it, so one rebuild covers the whole paste.)
  void _addPromptRows(List<String> prompts) {
    for (final p in prompts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      final empty = _promptCtrls.indexWhere((c) => c.text.trim().isEmpty);
      if (empty >= 0) {
        _promptCtrls[empty].text = t;
      } else {
        _promptCtrls.add(TextEditingController(text: t));
        _promptFocus.add(FocusNode());
      }
    }
    _batchStatuses = const [];
  }

  /// Add one empty row and focus it (the reference's Add prompt).
  void _addPromptRow() {
    setState(() {
      _promptCtrls.add(TextEditingController());
      _promptFocus.add(FocusNode());
      _focusedPromptIndex = _promptCtrls.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _promptFocus.last.requestFocus();
    });
  }

  /// Remove row [i] (the reference's minus button). The last row
  /// is never removed — its text is cleared instead, so there is
  /// always one prompt row to type in.
  void _removePromptRow(int i) {
    if (_promptCtrls.length <= 1) {
      setState(() {
        _promptCtrls.first.clear();
        _batchStatuses = const [];
      });
      return;
    }
    final ctrl = _promptCtrls[i];
    final node = _promptFocus[i];
    setState(() {
      _promptCtrls.removeAt(i);
      _promptFocus.removeAt(i);
      _focusedPromptIndex =
          _focusedPromptIndex.clamp(0, _promptCtrls.length - 1);
      _batchStatuses = const [];
    });
    ctrl.dispose();
    node.dispose();
  }

  /// Clear every row back to a single empty one (the reference's
  /// Clear all).
  void _clearAllPrompts() {
    final ctrls = List<TextEditingController>.from(_promptCtrls);
    final nodes = List<FocusNode>.from(_promptFocus);
    setState(() {
      _promptCtrls
        ..clear()
        ..add(TextEditingController());
      _promptFocus
        ..clear()
        ..add(FocusNode());
      _focusedPromptIndex = 0;
      _batchStatuses = const [];
    });
    for (final c in ctrls) {
      c.dispose();
    }
    for (final f in nodes) {
      f.dispose();
    }
  }

  /// Paste a list of prompts from the clipboard (the reference's
  /// Paste list): one line per row. The clipboard read can come
  /// back empty on some phones even right after copying (the v118
  /// report: the button "did nothing") — so an empty or failed
  /// read opens a paste box instead of a dead-end message: the
  /// box is a normal text field, so the OS long-press Paste works
  /// there even when the app's clipboard read does not.
  Future<void> _pastePromptList() async {
    List<String> lines = const [];
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      lines = parseBatchPrompts(data?.text ?? '');
    } catch (_) {
      lines = const [];
    }
    if (lines.isEmpty) {
      if (mounted) _showPasteListDialog();
      return;
    }
    setState(() => _addPromptRows(lines));
    _snack('${lines.length} prompt${lines.length == 1 ? '' : 's'} pasted.');
  }

  /// Paste box fallback for Paste list: one prompt per line.
  /// Long-press in the field to paste from the clipboard, then
  /// Add prompts fills one row per line.
  Future<void> _showPasteListDialog() async {
    final pasted = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => const _PasteListDialog(),
    );
    if (pasted == null || pasted.isEmpty) {
      if (pasted != null) {
        _snack('Type or paste at least one prompt.');
      }
      return;
    }
    setState(() => _addPromptRows(pasted));
    _snack(
        '${pasted.length} prompt${pasted.length == 1 ? '' : 's'} pasted.');
  }

  /// One numbered prompt row: purple number badge, the field
  /// (hint "Prompt N - describe the set concept…"), the Polish
  /// wand on the focused row, and the remove button — like the
  /// reference's Prompts card rows.
  Widget _promptRow(int i) {
    final scheme = Theme.of(context).colorScheme;
    final ctrl = _promptCtrls[i];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary,
          ),
          alignment: Alignment.center,
          child: Text(
            '${i + 1}',
            style: TextStyle(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: ctrl,
            focusNode: _promptFocus[i],
            minLines: 2,
            maxLines: 3,
            onTap: () => setState(() => _focusedPromptIndex = i),
            onChanged: (_) {
              _focusedPromptIndex = i;
              // Keep the batch queue panel in sync while typing;
              // editing the list clears the last run's marks.
              setState(() => _batchStatuses = const []);
            },
            decoration: InputDecoration(
              hintText: 'Prompt ${i + 1} - describe the set concept…',
              border: const OutlineInputBorder(),
              // v143 — the row clear (X) and the voice mic are
              // removed on his order (screenshot 21:12): only the
              // Polish wand stays, on the focused row. It polishes
              // every filled row, exactly like the old button did
              // (same Undo SnackBar). The wand is a compact 36px
              // target so it fits.
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i == _focusedPromptIndex)
                    _polishing
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2)),
                          )
                        : IconButton(
                            icon: const Icon(Icons.auto_fix_high,
                                size: 18),
                            tooltip: 'Polish prompts',
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(
                                minWidth: 36, minHeight: 36),
                            onPressed: (_busy || _polishing)
                                ? null
                                : _polishPrompt,
                          ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 24),
            tooltip: 'Remove prompt',
            onPressed: _busy ? null : () => _removePromptRow(i),
          ),
        ),
      ],
    );
  }

  // Set Designer panel
  // -------------------------------------------------------------------

  Widget _designerPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: _designerCard(),
    );
  }

  /// The designer card on its own, without a scroll view: the
  /// phone Studio screen (v85) stacks it above the generated-sets
  /// gallery in one shared scroll view, so the card must not
  /// bring its own scroll view along.
  Widget _designerCard() {
    final isSetMode =
        _mode == 'set_dual' || _mode == 'set_24h' || _mode == 'set_battery';
    final stages = isSetMode ? stagesForMode(_mode) : const <StageDef>[];
    // v112 — reference layout: the designer is three cards
    // now (Set type + Prompts + Model & Size) with the toggle
    // standing alone above them, like the reference's Batch
    // Sets screen — one Column, no scroll view.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // v111 — reference layout: the toggle stands alone
        // under the top bar, like the reference's main screen
        // (no card, no header around it). The set-type chips
        // live in their own card on top (v112).
        _imgModeToggle(),
        const SizedBox(height: 12),
      // v112 — reference layout: the Set type card sits on top
      // (his order "set type upore hobe"), like the reference's
      // Batch Sets screen — header + the five mode chips in a
      // wrap. (v113: the info paragraph under the chips is
      // hidden on his order — "Ei text gula hide rako".)
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader(Icons.layers_outlined, 'Set type'),
              const SizedBox(height: 8),
              // Mode picker (v56 redesign): the five modes, OUR
              // labels and order (v38) — in exactly TWO rows,
              // like the reference's set-type chips (v114: his
              // order "2 line a gap kome diye sundor kore rako"
              // — a Wrap flowed to 3+ rows on his phone, so the
              // rows are fixed now: single-image modes on row 1,
              // set modes on row 2, each chip Expanded so the
              // two lines hold on any width, gaps tightened to 6).
              Row(
                children: [
                  Expanded(
                      child: _modeChip('dual_single', '9:16 + Foldable',
                          Icons.devices_outlined)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _modeChip('single', 'Single 9:16',
                          Icons.image_outlined)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _modeChip('set_dual', 'Dual Set (2)',
                          Icons.view_column_outlined)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                      child: _modeChip('set_24h', '24-Hour Set (4)',
                          Icons.schedule_outlined)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _modeChip('set_battery', 'Battery Set (6)',
                          Icons.battery_charging_full)),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      // v112 — reference layout: the Prompts card (like the
      // reference's Batch Sets Prompts card) — numbered rows,
      // one prompt each, with Add prompt / Paste list / From
      // images / Clear all below them.
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader(Icons.format_list_bulleted, 'Prompts'),
              const SizedBox(height: 12),
              for (var i = 0; i < _promptCtrls.length; i++) ...[
                _promptRow(i),
                if (i < _promptCtrls.length - 1)
                  const SizedBox(height: 10),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _addPromptRow,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add prompt'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pastePromptList,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('Paste list'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _openImageSearch(promptMode: true),
                      icon: const Icon(Icons.image_search_outlined,
                          size: 18),
                      label: const Text('From images'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _clearAllPrompts,
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('Clear all'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor:
                            Theme.of(context).colorScheme.error,
                        side: BorderSide(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // v109 — reference layout: live character count
              // (total across rows, like the reference's "0/16384").
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$_totalPromptChars/16384',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              if (_batchMode) ...[
                const SizedBox(height: 8),
                _batchQueuePanel(),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: _pickReference,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(
                  _reference == null
                      ? 'Reference image (optional)'
                      : 'Reference: ${_reference!.name.length > 26 ? '${_reference!.name.substring(0, 23)}...' : _reference!.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_reference != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _reference = null),
                    child: const Text('Remove reference'),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      // v110 — reference layout: the Model & Size card (the
      // reference's Generation options, with OUR settings).
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader(Icons.tune, 'Model & Size'),
              const SizedBox(height: 8),
              _chipGroup(
                  'Variation strength',
                  _variation,
                  const {
                    'subtle': 'Subtle',
                    'clear': 'Clear',
                    'strong': 'Strong',
                  },
                  (v) => setState(() => _variation = v)),
              const SizedBox(height: 8),
              _chipGroup(
                  'Display target',
                  _displayTarget,
                  const {
                    'any': 'Any',
                    'amoled': 'AMOLED',
                    'ips': 'IPS',
                  },
                  (v) => setState(() => _displayTarget = v)),
              const SizedBox(height: 8),
              _chipGroup(
                  'Colour boost',
                  _colorBoost,
                  const {
                    'off': 'Off',
                    'subtle': 'Subtle',
                    'vivid': 'Vivid',
                    'neon': 'Neon',
                  },
                  (v) => setState(() => _colorBoost = v)),
              if (_mode == 'set_24h') ...[
                const SizedBox(height: 12),
                _dropdownRow(
                    'Story arc',
                    _storyArc,
                    const {
                      'auto': 'Auto (Smart Pick)',
                      'light': 'Light Only',
                      'bloom': 'Bloom Cycle',
                      'rhythm': 'Daily Rhythm',
                    },
                    (v) => setState(() => _storyArc = v)),
              ],
              if (_mode == 'set_battery') ...[
                const SizedBox(height: 12),
                _dropdownRow(
                    'Story arc',
                    _storyArc,
                    const {
                      'auto': 'Auto (Smart Pick)',
                      'energy': 'Energy Glow',
                      'growth': 'Growth',
                      'awaken': 'Awakening',
                    },
                    (v) => setState(() => _storyArc = v)),
              ],
              if (isSetMode) ...[
                const SizedBox(height: 4),
                _toggleRow('AI Set Director plan', _aiDirector,
                    (v) => setState(() => _aiDirector = v)),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
          // v109 — reference layout: the call-to-action is a
          // solid primary button, 56px tall (the old violet
          // gradient wrapper is gone).
          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_busy ? 'Working...' : 'Generate set'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              textStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _addToQueue,
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Add to overnight queue'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(42),
            ),
          ),
          if (_queue.isNotEmpty || _queueSummary != null) ...[
            const SizedBox(height: 8),
            _queueBar(),
          ],
          const SizedBox(height: 10),
          _stepper(),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8, top: 2),
                    child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Expanded(
                    child: Text(_statusText,
                        style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
          // v139 — Advanced settings hidden on user request (defaults stay active).
          // v139 — Log box hidden on user request.
      ],
    );
  }

  Widget _modeChip(String value, String label, IconData icon) {
    final selected = _mode == value;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: selected ? Colors.transparent : scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() {
          _mode = value;
          _storyArc = 'auto';
        }),
        child: SizedBox(
          height: 36,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    selected ? Icons.check : icon,
                    size: 14,
                    color: selected ? scheme.onPrimary : scheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// v110 — reference layout: the Text to Image / Image to Image
  /// segmented toggle. It is the same switch as the Reference
  /// image button below — Image opens the picker, Text clears the
  /// reference. No new behaviour, only the reference's control.
  Widget _imgModeToggle() {
    final scheme = Theme.of(context).colorScheme;
    final img = _reference != null;
    Widget half({
      required bool selected,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      Key? key,
    }) {
      return Expanded(
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color:
                  selected ? scheme.surfaceContainerHigh : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected)
                  Icon(Icons.check, size: 16, color: scheme.onSurface)
                else
                  Icon(icon, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                // Flexible + ellipsis: the Ahem test font is much
                // wider than Roboto — without this the half
                // overflows on narrow phones in tests.
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color:
                              selected ? scheme.onSurface : scheme.primary)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          half(
            key: const ValueKey('imgModeText'),
            selected: !img,
            icon: Icons.text_fields,
            label: 'Text to Image',
            onTap: () => setState(() => _reference = null),
          ),
          half(
            key: const ValueKey('imgModeImage'),
            selected: img,
            icon: Icons.image_outlined,
            label: 'Image to Image',
            onTap: _pickReference,
          ),
        ],
      ),
    );
  }

  /// v110 — reference layout: a card section header — the icon on
  /// a primary-tinted square + a bold title (Prompt, Model & Size).
  Widget _sectionHeader(IconData icon, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: scheme.primary, size: 17),
        ),
        const SizedBox(width: 8),
        Text(title,
            style:
                const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
      ],
    );
  }

  /// v110 — reference layout: one labelled chip group (Variation /
  /// Display target / Colour boost). Replaces the old one-line
  /// dialog pickers — one tap picks, like the reference's chips.
  /// Rows are Wraps, never Rows (the Ahem test font overflows Rows).
  Widget _chipGroup(String label, String value,
      Map<String, String> options, ValueChanged<String> onChanged) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final e in options.entries)
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                label: Text(e.value),
                selected: value == e.key,
                selectedColor: scheme.primary,
                backgroundColor: scheme.surfaceContainer,
                checkmarkColor: scheme.onPrimary,
                labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: value == e.key
                        ? scheme.onPrimary
                        : scheme.onSurface),
                side: BorderSide(
                    color: value == e.key
                        ? Colors.transparent
                        : scheme.outlineVariant),
                onSelected: (_) => onChanged(e.key),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stepper() {
    const labels = ['Generate', 'Anchor Sync', 'Stages', 'Metadata'];
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Column(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: _busy && i == _activeStep
                    ? Theme.of(context).colorScheme.primary
                    : i < _activeStep ||
                            (!_busy && _statusText.startsWith('Ready in'))
                        ? Colors.green
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                // v95 — the number is white on the coloured steps,
                // but the idle step sits on a pale surface in light
                // mode, so it takes the secondary text colour there.
                child: Text('${i + 1}',
                    style: TextStyle(
                        fontSize: 11,
                        color: _busy && i == _activeStep ||
                                i < _activeStep ||
                                (!_busy &&
                                    _statusText.startsWith('Ready in'))
                            ? Colors.white
                            : Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
              ),
              const SizedBox(height: 3),
              SizedBox(
                width: 64,
                child: Text(labels[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10)),
              ),
            ],
          ),
          if (i < 3)
            const Expanded(
                child: Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Divider(),
            )),
        ],
      ],
    );
  }

  Widget _dropdownRow(String label, String value, Map<String, String> options,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
              width: 86,
              child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              value: value,
              isDense: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: options.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sizeField(String label, int value, ValueChanged<int> onChanged) {
    return TextFormField(
      initialValue: '$value',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
          labelText: label, border: const OutlineInputBorder(), isDense: true),
      onChanged: (t) {
        final v = int.tryParse(t);
        if (v != null && v > 0) onChanged(v);
      },
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  // -------------------------------------------------------------------
  // Showcase panel
  // -------------------------------------------------------------------

  Future<void> _setShowcaseCols(int cols) async {
    final next = cols.clamp(1, 6);
    setState(() => _showcaseCols = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('showcaseGridCols', next);
  }

  /// v139 — "- 3 +" column stepper matching generate-main's Results header.
  Widget _showcaseZoomStepper() {
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(icon, size: 17),
          onPressed: onTap,
        );
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(Icons.remove_outlined, 'Fewer columns (larger cards)',
              _showcaseCols > 1 ? () => _setShowcaseCols(_showcaseCols - 1) : null),
          SizedBox(
            width: 22,
            child: Center(
              child: Text('$_showcaseCols',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ),
          step(Icons.add_outlined, 'More columns (smaller cards)',
              _showcaseCols < 6 ? () => _setShowcaseCols(_showcaseCols + 1) : null),
        ],
      ),
    );
  }

  List<String> _pendingSlotLabels() {
    switch (_mode) {
      case 'dual_single':
        return const ['Wallpaper', 'Landscape'];
      case 'single':
        return const ['Wallpaper'];
      case 'set_dual':
        return const ['Lock', 'Home'];
      case 'set_battery':
        return const ['0%', '20%', '40%', '60%', '80%', 'Charging'];
      case 'set_24h':
      default:
        return const ['Morning', 'Afternoon', 'Evening', 'Night'];
    }
  }

  /// v139 — Live slot-by-slot processing Set card matching generate-main
  /// (dark rounded 9:16 tiles with centered violet spinner + label under each).
  Widget _processingShowcaseCard() {
    final scheme = Theme.of(context).colorScheme;
    final activePrompt =
        _promptCtrls.isNotEmpty ? _promptCtrls.first.text.trim() : '';
    final slots = _pendingSlotLabels();
    final title = activePrompt.isEmpty
        ? 'Set ${_history.length + 1} - ${setTypeLabelFor(_mode)}'
        : 'Set ${_history.length + 1} - $activePrompt';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '0/${slots.length}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            if (_statusText.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (ctx, constraints) {
                final count = _showcaseCols.clamp(1, 6);
                final cellW =
                    (constraints.maxWidth - (count - 1) * 10) / count;
                final imgH = cellW / 0.60;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: slots.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: cellW / (imgH + 26),
                  ),
                  itemBuilder: (ctx, i) => Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: cellW,
                        height: imgH,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        slots[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _showcaseContent({required bool shrinkWrap}) {
    if (_history.isEmpty && !_busy) {
      return Center(child: _showcaseEmptyState());
    }
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _history.length + (_busy ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (_busy && i == 0) return _processingShowcaseCard();
        final entry = _history[_busy ? i - 1 : i];
        return SetCard(
          entry: entry,
          engine: _engine,
          gridCols: _showcaseCols,
          onChanged: _refreshHistory,
          snack: _snack,
        );
      },
    );
  }

  Widget _showcasePanel() {
    return Column(
      children: [
        _showcaseHeader(),
        Expanded(child: _showcaseContent(shrinkWrap: false)),
      ],
    );
  }

  /// Phone inline gallery (v85): the Showcase is no longer a tab
  /// — the generated sets stack below the designer in the Studio
  /// scroll view. The list is shrink-wrapped and never scrolls on
  /// its own; the outer scroll view owns the scrolling.
  Widget _showcaseInline() {
    return Column(
      key: _resultsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _showcaseHeader(),
        _showcaseContent(shrinkWrap: true),
      ],
    );
  }

  /// Showcase header (v85): title row + stat chips + the three
  /// actions. Shared by the wide panel and the phone inline
  /// gallery below the designer.
  Widget _showcaseHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.grid_view_outlined,
                  size: 18, color: Color(0xFFC9C2FF)),
              const SizedBox(width: 7),
              // v140 — the title flexes (ellipsis): in the test font
              // 'Showcase' is 126px and the header overflowed a
              // 320px phone by 31px (stepper 108 + clear 40 + icon
              // 18 + gaps leave only ~95px for the title).
              const Flexible(
                child: Text('Showcase',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              if (_history.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: kDashboardScheme.tertiary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${_history.length}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ],
              const Spacer(),
              _showcaseZoomStepper(),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Clear history',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: _history.isEmpty ? null : _clearHistory,
                icon: const Icon(Icons.delete_outline, size: 17),
              ),
            ],
          ),
          // v83: the stat chips moved out of the old hero header
          // into the Showcase header, where they describe the
          // library they sit above (sets / Gmails / output size).
          const SizedBox(height: 6),
          // v85: Wrap, not Row — the inline phone gallery is 24px
          // narrower than the old Showcase tab (the Studio scroll
          // view adds its own 12px padding), and the three chips
          // overflowed a 360px phone by 143px.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _statChip(Icons.grid_view_outlined,
                  '${_history.length} sets'),
              _statChip(Icons.alternate_email,
                  '${_accounts.length} Gmail'),
              _statChip(Icons.photo_size_select_large_outlined,
                  '${_portraitW}x$_portraitH JPG'),
            ],
          ),
          // v57: the three actions are hidden while the
          // Showcase is empty — they were all disabled then,
          // showing as three greyed-out buttons.
          if (_history.isNotEmpty)
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      textStyle: const TextStyle(fontSize: 12.5),
                    ),
                    onPressed: _busy ? null : _writeAllMetadata,
                  icon: const Icon(Icons.description_outlined, size: 15),
                  label: const Text('Metadata (all)'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed:
                      _history.isEmpty ? null : () => _exportZip(_history),
                  icon: const Icon(Icons.archive_outlined, size: 15),
                  label: const Text('Ready ZIP'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed:
                      _busy || _history.isEmpty ? null : _uploadAllToPanel,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 15),
                  label: const Text('Upload to Panel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The empty-gallery body, without Expanded/Center — the caller
  /// adds those (v85).
  Widget _showcaseEmptyState() {
    return Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: const Color(0xFF37335F),
                    borderRadius: BorderRadius.circular(22),
                    border:
                        Border.all(color: const Color(0xFF4A4480)),
                  ),
                  child: const Icon(Icons.grid_view_outlined,
                      size: 34, color: Color(0xFFC9C2FF)),
                ),
                const SizedBox(height: 16),
                const Text('No sets yet',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                    'Sign in with Gemini, write a prompt and Generate.',
                    textAlign: TextAlign.center,
                    // v99 — was hardcoded grey, faint on the light
                    // empty-state card.
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant)),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _scrollStudioToTop,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create your first set'),
                ),
              ],
            ),
    );
  }
}

/// Paste box for Paste list (v119): the dialog owns its controller
/// so it is disposed with the dialog, never while the field is
/// still on screen. Pops the parsed lines, or null on Cancel.
class _PasteListDialog extends StatefulWidget {
  const _PasteListDialog();

  @override
  State<_PasteListDialog> createState() => _PasteListDialogState();
}

class _PasteListDialogState extends State<_PasteListDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste prompts'),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          minLines: 5,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'One prompt per line…',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(parseBatchPrompts(_ctrl.text)),
          child: const Text('Add prompts'),
        ),
      ],
    );
  }
}

/// One finished set in the Showcase.
class SetCard extends StatefulWidget {
  final SetEntry entry;
  final StudioEngine engine;
  final int gridCols;
  final Future<void> Function() onChanged;
  final void Function(String) snack;
  const SetCard({
    super.key,
    required this.entry,
    required this.engine,
    this.gridCols = 3,
    required this.onChanged,
    required this.snack,
  });

  @override
  State<SetCard> createState() => _SetCardState();
}

class _SetCardState extends State<SetCard> {
  bool _working = false;
  String _uploadTarget = 'spread';

  /// v96 — the metadata card is compact by default (2-line
  /// description, one scrollable tag row); tap to expand.
  bool _metaExpanded = false;

  Future<void> _run(Future<void> Function() fn, String failPrefix) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await fn();
      await widget.onChanged();
    } catch (e) {
      widget.snack('$failPrefix: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _regenerateAll() async {
    await _run(() async {
      for (final img in widget.entry.images) {
        await widget.engine.regenerateStage(widget.entry, img);
      }
    }, 'Regenerate failed');
  }

  Future<void> _uploadToPanel() async {
    // v42: the card no longer carries a permanent Panel target row;
    // the target is picked here, on the cloud tap, and remembered.
    var target = _uploadTarget;
    final cfg = await widget.engine.loadDistConfig();
    if (!mounted) return;
    if (cfg.accounts.isNotEmpty) {
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Upload to Panel'),
          children: [
            for (final t in [
              'spread',
              ...cfg.accounts.map((a) => a.name),
            ])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, t),
                child: Row(
                  children: [
                    Icon(
                      t == target
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(t == 'spread' ? 'Spread (Auto-Rotate)' : t),
                  ],
                ),
              ),
          ],
        ),
      );
      if (picked == null) return;
      target = picked;
      if (mounted) setState(() => _uploadTarget = target);
    }
    await _run(() async {
      final r = await widget.engine
          .uploadSetToPanel(widget.entry, targetAccount: target);
      widget.snack('Uploaded to ${r.accountName} (key ${r.firebaseKey})');
    }, 'Panel upload failed');
  }

  Future<void> _confirmDelete() async {
    final entry = widget.entry;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this set?'),
        content: Text(
            'The set is removed from the Showcase and its ${entry.images.length} image files are deleted from this device. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final history = await widget.engine.loadHistory();
      history.removeWhere((h) => h.id == entry.id);
      await widget.engine.saveHistory(history);
      for (final img in entry.images) {
        final f = File(img.localPath);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }, 'Delete failed');
  }

  /// One hashtag chip, shared by the collapsed (one scrollable
  /// row) and expanded (wrapped) tag layouts.
  Widget _tagChip(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF12121B),
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('#$tag',
          style:
              const TextStyle(fontSize: 13, color: Color(0xFFC9C9D2))),
    );
  }

  /// Inner metadata card in the reference showcase design: title +
  /// category pill + AI sparkle, the model line, the description and
  /// the hashtag chips.
  /// v96 — compact by default (about half the old height): the
  /// description shows 2 lines and the tags one scrollable row;
  /// "Aro dekho" expands to the full description + wrapped tags.
  Widget _metaCard(SetEntry entry, SetMetadata? meta) {
    if (meta == null ||
        (meta.title.isEmpty && meta.description.isEmpty && meta.tags.isEmpty)) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text('No metadata yet',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13.5)),
            ),
            FilledButton.tonalIcon(
              onPressed: _working
                  ? null
                  : () => _run(() async {
                        await widget.engine.generateMetadataForEntry(entry);
                      }, 'Metadata failed'),
              icon: const Icon(Icons.auto_awesome, size: 15),
              label: const Text('AI Metadata'),
            ),
          ],
        ),
      );
    }
    final expanded = _metaExpanded;
    // v96 — the toggle only appears when something is actually
    // hidden: a description longer than ~2 lines, or more tags
    // than fit one row.
    final showToggle =
        meta.description.length > 120 || meta.tags.length > 5;
    return Container(
      key: const ValueKey('metaCard'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(meta.title,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700)),
              ),
              if (meta.category.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7A68E0),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(meta.category.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Colors.white)),
                ),
              ],
              IconButton(
                tooltip: 'Rewrite with AI',
                visualDensity: VisualDensity.compact,
                onPressed: _working
                    ? null
                    : () => _run(() async {
                          await widget.engine.generateMetadataForEntry(entry);
                        }, 'Metadata failed'),
                icon: Icon(Icons.auto_awesome,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('gemini-web (cookie)',
              style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          if (meta.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(meta.description,
                maxLines: expanded ? null : 2,
                overflow:
                    expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: Theme.of(context).colorScheme.onSurface)),
          ],
          if (meta.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            if (expanded)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in meta.tags) _tagChip(tag)],
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < meta.tags.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _tagChip(meta.tags[i]),
                    ],
                  ],
                ),
              ),
          ],
          if (showToggle) ...[
            const SizedBox(height: 8),
            GestureDetector(
              key: const ValueKey('metaExpandToggle'),
              onTap: () => setState(() => _metaExpanded = !_metaExpanded),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(expanded ? 'Kom dekho' : 'Aro dekho',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(width: 2),
                  Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Reference-design image grid: equal columns of stage thumbnails
  /// with circular overlay actions (preview / regenerate / view) and
  /// the stage label underneath.
  Widget _imageGrid(SetEntry entry) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final count = widget.gridCols.clamp(1, 6);
        final cellW = (constraints.maxWidth - (count - 1) * 10) / count;
        final imgH = cellW / 0.60;
        final btn = cellW < 80 ? 27.0 : 34.0;
        final iconSize = cellW < 80 ? 14.0 : 17.0;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: entry.images.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: cellW / (imgH + 28),
          ),
          itemBuilder: (ctx, i) {
            final img = entry.images[i];
            final file = File(img.localPath);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => _openLightbox(img),
                  child: SizedBox(
                    height: imgH,
                    width: cellW,
                    child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: file.existsSync()
                            ? Image.file(file, fit: BoxFit.cover)
                            : Container(
                                color: Colors.black26,
                                child:
                                    const Icon(Icons.broken_image_outlined),
                              ),
                      ),
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Row(
                          children: [
                            _overlayButton(
                              Icons.smartphone_outlined,
                              btn,
                              iconSize,
                              () => _openSimulator(entry, initialIndex: i),
                            ),
                            const SizedBox(width: 5),
                            _overlayButton(
                              Icons.refresh,
                              btn,
                              iconSize,
                              _working
                                  ? null
                                  : () => _run(() async {
                                        await widget.engine
                                            .regenerateStage(entry, img);
                                      }, 'Regenerate failed'),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 6,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: _overlayButton(
                            Icons.fact_check_outlined,
                            btn,
                            iconSize,
                            () => _openOriginality(entry, img),
                          ),
                        ),
                      ),
                    ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (img.hdUrl != null) ...[
                      Icon(Icons.link, size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                    ],
                    Expanded(
                      child: Text(img.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _overlayButton(
      IconData icon, double size, double iconSize, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0x8C000000),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: iconSize, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final meta = entry.metadata;
    return Card(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header (reference showcase design): the prompt as the
            // title, then regenerate / upload / delete icon actions
            // and the finished-stage count (e.g. 4/4).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      entry.prompt.isEmpty ? entry.setTypeLabel : entry.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700,
                          height: 1.25),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Regenerate whole set',
                  visualDensity: VisualDensity.compact,
                  onPressed: _working ? null : _regenerateAll,
                  icon: Icon(Icons.refresh,
                      size: 21, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                IconButton(
                  tooltip: 'Upload to Panel',
                  visualDensity: VisualDensity.compact,
                  onPressed: _working ? null : _uploadToPanel,
                  icon: Icon(Icons.cloud_upload_outlined,
                      size: 21, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                IconButton(
                  tooltip: 'Delete set',
                  visualDensity: VisualDensity.compact,
                  onPressed: _working ? null : _confirmDelete,
                  icon: const Icon(Icons.delete_outline,
                      size: 21, color: Color(0xFFE5534B)),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(
                      '${entry.images.length}/${entry.images.length}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            if (entry.uploadedToPanel != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Chip(
                  avatar: const Icon(Icons.check_circle_outline, size: 14),
                  label: Text(
                      'Queued on ${entry.uploadedToPanel!['accountName']}',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
            const SizedBox(height: 12),
            _metaCard(entry, meta),
            const SizedBox(height: 14),
            _imageGrid(entry),
            if (_working)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openOriginality(SetEntry entry, SetImage img) async {
    final prefs = await SharedPreferences.getInstance();
    final target = prefs.getInt('i2pSimilarity') ?? 20;
    final ref = ReferenceStore.lookup(entry.prompt);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OriginalityCheckScreen(
        generatedFile: File(img.localPath),
        generatedLabel: img.label,
        referenceBytes: ref?.bytes,
        referenceLabel: ref?.label,
        targetSimilarity: target,
        onLessSimilar: (bytes, reduced) async {
          final options = PromptOptions()..similarity = reduced;
          return generatePromptChecked(
            bytes: bytes,
            name: 'reference.jpg',
            mime: 'image/jpeg',
            options: options,
          );
        },
      ),
    ));
  }

  void _openLightbox(SetImage img) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${img.badge} - ${img.width}x${img.height} JPG - ${(img.byteSize / 1048576).toStringAsFixed(2)} MB',
                        style: const TextStyle(fontSize: 13)),
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Flexible(
              child: File(img.localPath).existsSync()
                  ? Image.file(File(img.localPath), fit: BoxFit.contain)
                  : const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('File missing on this device.'),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 6,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: img.localPath));
                      widget.snack('Image path copied');
                    },
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('Copy path'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _run(() async {
                      await widget.engine.regenerateStage(widget.entry, img);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }, 'Regenerate failed'),
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text('Regenerate this stage'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _openOriginality(widget.entry, img);
                    },
                    icon: const Icon(Icons.fact_check_outlined, size: 15),
                    label: const Text('Originality check'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSimulator(SetEntry entry, {int initialIndex = 0}) {
    if (entry.images.isEmpty) return;
    final safeIdx = initialIndex.clamp(0, entry.images.length - 1);
    final img = entry.images[safeIdx];
    final title = (entry.metadata?.title.isNotEmpty ?? false)
        ? entry.metadata!.title
        : (entry.prompt.isNotEmpty ? entry.prompt : entry.setTypeLabel);
    showDevicePreview(
      context,
      imageUrl: img.localPath,
      title: title,
      initialIndex: safeIdx,
      stages: [
        for (final s in entry.images)
          (
            imageUrl: s.localPath,
            label: s.label.isNotEmpty ? s.label : s.exactFilename,
          ),
      ],
    );
  }

}
