import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:gemini_hd_studio/chromium_browser.dart';
import 'package:gemini_hd_studio/chromium_studio_browser.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';
import 'package:gemini_hd_studio/gecko_signin.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/image_search.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/session_store.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:gemini_hd_studio/studio_constants.dart';
import 'package:gemini_hd_studio/image_service.dart';
import 'package:gemini_hd_studio/originality.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  _originalityTests();
  _imagePipelineTests();
  testWidgets('App boots to the Studio home screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // Wide surface -> the two-panel desktop layout, both panels visible.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Zedge Studio'), findsWidgets);
    expect(find.text('Set Designer'), findsOneWidget);
    // v85: 'Showcase' is only the gallery header now — the nav
    // tab is gone, the sets live under the designer.
    expect(find.text('Showcase'), findsOneWidget);
    // v30 (user order): the Image to Prompt / Search images shortcut
    // buttons were removed from the Set Designer — the Search tab in
    // the bottom nav is the entry point now.
    expect(find.text('Image to Prompt'), findsNothing);
    expect(find.text('Search images'), findsNothing);
  });

  testWidgets('Overnight queue: add from the designer, open the queue page',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.byType(TextField).first, 'a marble fox under aurora light');
    final addBtn = find.text('Add to overnight queue');
    await tester.ensureVisible(addBtn);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(addBtn);
    await tester.pump(const Duration(milliseconds: 300));
    final bar = find.textContaining('Overnight queue: 1 pending');
    expect(bar, findsOneWidget);
    await tester.ensureVisible(bar);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(bar);
    // This app's route transition needs a few pumped frames to
    // fully enter in the fake-async zone.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Overnight Queue'), findsOneWidget);
    expect(find.text('a marble fox under aurora light'), findsOneWidget);
    expect(find.text('Start queue (1 pending)'), findsOneWidget);
  });

  testWidgets('Polish prompt button guards an empty prompt', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    final btn = find.text('Polish prompt');
    expect(btn, findsOneWidget);
    await tester.ensureVisible(btn);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(btn);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Write a prompt first.'), findsOneWidget);
  });

  // v51 voice prompt: the mic button shows on Android, and when
  // the recogniser reports unavailable (mocked here — widget
  // tests have no speech plugin) tapping it fails softly with a
  // SnackBar instead of crashing.
  testWidgets('Voice prompt mic button fails softly without a recogniser',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return false;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    final mic = find.byTooltip('Speak your prompt');
    expect(mic, findsOneWidget);
    await tester.ensureVisible(mic);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(mic);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Voice input is not available on this device.'),
        findsOneWidget);
  });

  test('Cookie paste normalisation handles header + bare values', () {
    final header = SessionStore.normalisePastedCookies(
        '__Secure-1PSID=abc123; __Secure-1PSIDTS=xyz789');
    expect(header, contains('__Secure-1PSID=abc123'));
    expect(header, contains('__Secure-1PSIDTS=xyz789'));
    final bare = SessionStore.normalisePastedCookies('abc123\nxyz789');
    expect(bare, contains('__Secure-1PSID=abc123'));
    expect(SessionStore.cookieHeaderLooksLoggedIn(header), isTrue);
    expect(SessionStore.cookieHeaderLooksLoggedIn('foo=bar'), isFalse);
  });

  test('Zedge dimension rules enforce the 1620x2880 minimum', () {
    final d = normalizeZedgeDimensions(1080, 1920);
    expect(d.width, greaterThanOrEqualTo(1620));
    expect(d.height, greaterThanOrEqualTo(2880));
    final ok = normalizeZedgeDimensions(1620, 2880);
    expect(ok.width, 1620);
    expect(ok.height, 2880);
  });

  test('parseStreamGenerateResponse extracts image url + text', () {
    final api = GeminiApi();
    final inner = jsonEncode([
      null,
      ['conv1', 'resp1'],
      null,
      null,
      [
        ['choice1', ['Hello world answer'], null, null,
          ['https://lh3.googleusercontent.com/gg-dl/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd=s1024']]
      ]
    ]);
    final line = jsonEncode([
      ['wrb.fr', null, inner]
    ]);
    final raw = ")]}'\n123\n$line\n";
    final parsed = api.parseStreamGenerateResponse(raw);
    expect(parsed.assistantText, 'Hello world answer');
    expect(parsed.urls.length, 1);
    expect(parsed.urls.first, startsWith('https://lh3.googleusercontent.com/gg-dl/'));
    // The URL must come back EXACTLY as issued, size suffix
    // included — the v19/v20 bug was returning the stripped base,
    // whose every reconstruction the CDN refused with HTTP 403.
    expect(
        parsed.urls.first,
        'https://lh3.googleusercontent.com/gg-dl/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd=s1024');
    // excluded urls are filtered by base key
    final parsed2 = api.parseStreamGenerateResponse(raw, excludeUrls: parsed.urls);
    expect(parsed2.urls, isEmpty);
  });

  test('extractJsonMapFromReply finds balanced JSON in prose', () {
    final api = GeminiApi();
    final m = api.extractJsonMapFromReply(
        'Sure! {"title": "Alpine Lake", "tags": ["lake"], "category": "NATURE", "description": "Nice."} done');
    expect(m?['title'], 'Alpine Lake');
    expect(m?['category'], 'NATURE');
  });

  // ---- Mobile responsiveness: no RenderFlex overflow on phones ----
  for (final size in const [Size(320, 568), Size(360, 640), Size(390, 844)]) {
    testWidgets('Home screen fits phone size $size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const GeminiHdStudioApp());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      // Open the Advanced settings (dropdowns, size fields, toggles)
      // inside the Studio tab's designer card.
      await tester.ensureVisible(find.text('Advanced settings'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Advanced settings'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      // v85: the gallery is inline below the designer on the same
      // Studio screen — scroll down to it and make sure it renders
      // cleanly at this size too.
      await tester.ensureVisible(find.text('Create your first set'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      // v57: an empty Showcase hides the (disabled) action row and
      // shows the designed empty state instead.
      expect(find.text('Metadata (all)'), findsNothing);
      expect(find.text('Create your first set'), findsOneWidget);
    });
  }

  testWidgets('SetCard + set preview fit a 320px phone', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = SetEntry(
      id: 't1',
      prompt: 'A very long prompt about neon mountains at dusk over a lake',
      workflowMode: 'set_dual',
      setTypeLabel: 'Dual Set (Lock + Home)',
      setFolderName: 'set-01',
      createdAtIso: '2026-11-08T01:00:00.000',
      metadata: SetMetadata(
        title: 'Neon Mountain Dusk',
        tags: ['neon', 'mountain', 'dusk', 'lake', 'amoled', 'dark'],
        category: 'NATURE',
        description: 'A neon mountain scene at dusk.',
      ),
      images: [
        SetImage(
          localPath: '/nonexistent/lock.jpg',
          exactFilename: 'lock.jpg',
          zipName: '01-lock.jpg',
          distSlot: 'lock',
          role: 'lock',
          label: 'Lock Screen',
          badge: 'LOCK',
          slotIndex: 0,
          stageKey: 'lock',
          width: 1620,
          height: 2880,
          byteSize: 3 * 1024 * 1024,
        ),
        SetImage(
          localPath: '/nonexistent/home.jpg',
          exactFilename: 'home.jpg',
          zipName: '02-home.jpg',
          distSlot: 'home',
          role: 'home',
          label: 'Home Screen',
          badge: 'HOME',
          slotIndex: 1,
          stageKey: 'home',
          width: 1620,
          height: 2880,
          byteSize: 3 * 1024 * 1024,
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetCard(
            entry: entry,
            engine: StudioEngine(),
            onChanged: () async {},
            snack: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    // v42 (user order): the card's bottom Panel target dropdown and
    // Upload to Panel button are gone too — panel upload lives on
    // the header cloud icon, which asks for the target on tap.
    expect(find.text('Upload to Panel'), findsNothing);
    expect(find.text('Panel target'), findsNothing);
    // v29 (user order): the per-set action row is hidden — Preview
    // set / Edit metadata / Ready ZIP / Copy title / Copy tags.
    expect(find.text('Preview set'), findsNothing);
    expect(find.text('Edit metadata'), findsNothing);
    expect(find.text('Ready ZIP'), findsNothing);
    expect(find.text('Copy title'), findsNothing);
    expect(find.text('Copy tags'), findsNothing);
  });

  test('Image search URL builders encode the query', () {
    expect(googleImagesSearchUrl('neon mountain'),
        contains('google.com/search?tbm=isch'));
    expect(googleImagesSearchUrl('neon mountain'),
        contains('q=neon%20mountain'));
    expect(pinterestSearchUrl('amoled wallpaper'),
        'https://www.pinterest.com/search/pins/?q=amoled%20wallpaper');
  });

  test('parseImageCandidates filters, dedupes and ranks biggest first', () {
    final raw = jsonEncode([
      {'url': 'https://example.com/og.jpg', 'w': 0, 'h': 0},
      {'url': 'https://example.com/big.jpg', 'w': 1200, 'h': 1600},
      {'url': 'https://example.com/icon.png', 'w': 64, 'h': 64},
      {'url': 'data:image/png;base64,AAAA', 'w': 800, 'h': 800},
      {'url': 'https://example.com/big.jpg', 'w': 1200, 'h': 1600},
      {'url': 'https://example.com/mid.jpg', 'w': 600, 'h': 800},
      {'url': 'https://example.com/thin.jpg', 'w': 120, 'h': 900},
    ]);
    final c = parseImageCandidates(raw);
    expect(c.length, 3);
    expect(c[0].url, 'https://example.com/big.jpg');
    expect(c[1].url, 'https://example.com/mid.jpg');
    expect(c[2].url, 'https://example.com/og.jpg');
    expect(parseImageCandidates('not json'), isEmpty);
    expect(parseImageCandidates(null), isEmpty);
  });

  test('cleanGeneratedPrompt strips labels, quotes and extra paragraphs',
      () {
    expect(
      GeminiApi.cleanGeneratedPrompt(
          'Prompt: "A neon mountain at dusk, ultra detailed"\n\nHope this helps!'),
      'A neon mountain at dusk, ultra detailed',
    );
    expect(
      GeminiApi.cleanGeneratedPrompt('```\nA calm lake at dawn\n```'),
      'A calm lake at dawn',
    );
    expect(GeminiApi.cleanGeneratedPrompt('   '), isEmpty);
  });

  test('session html parsing finds email + token presence', () {
    expect(
        GeminiApi.extractEmailFromHtml('"oPEP7c":"user.name@gmail.com"'),
        'user.name@gmail.com');
    expect(GeminiApi.isQuotaOrLimitFailure(429, ''), isTrue);
    expect(GeminiApi.isQuotaOrLimitFailure(200, 'You reached your limit'), isTrue);
    expect(GeminiApi.isQuotaOrLimitFailure(200, 'all good'), isFalse);
  });

  test('Similarity target: stays/changes follow the percent', () {
    expect(GeminiApi.staysForSimilarity(20),
        ['Subject type', 'Style & medium']);
    expect(GeminiApi.changesForSimilarity(20).length, 9);
    expect(GeminiApi.staysForSimilarity(60).length, 7);
    expect(GeminiApi.staysForSimilarity(90).length, 11);
    expect(GeminiApi.changesForSimilarity(90), isEmpty);
    expect(GeminiApi.similarityLabel(20), 'Fresh new picture');
    expect(GeminiApi.similarityLabel(45), 'Inspired');
    expect(GeminiApi.similarityLabel(60), 'Balanced');
    expect(GeminiApi.similarityLabel(90), 'Near copy');
  });

  test('buildImageToPromptInstruction embeds target + format + rules', () {
    final s = GeminiApi.buildImageToPromptInstruction(
        similarity: 45, styleNote: 'extra neon');
    expect(s, contains('SIMILARITY TARGET: 45% (Inspired)'));
    expect(s, contains('STAYS THE SAME: Subject type'));
    expect(s, contains('WILL CHANGE:'));
    expect(s, contains('120-200 words'));
    expect(s, contains('[PROMPT]'));
    expect(s, contains('Also follow this style note: extra neon'));
  });

  test('cleanGeneratedPrompt extracts the [PROMPT] block', () {
    expect(
      GeminiApi.cleanGeneratedPrompt(
          'Here you go:\n[PROMPT]\nA neon lake at dusk, ultra detailed\n[/PROMPT]\nDone!'),
      'A neon lake at dusk, ultra detailed',
    );
  });

  test('promptSimilarity: identical high, unrelated zero', () {
    expect(
        GeminiApi.promptSimilarity(
            'neon mountain lake dusk', 'neon mountain lake dusk'),
        1.0);
    expect(
        GeminiApi.promptSimilarity(
            'neon mountain lake dusk', 'underwater coral reef city'),
        0.0);
    final near = GeminiApi.promptSimilarity(
        'neon mountain lake at dusk with violet sky',
        'neon mountain lake at dusk with violet clouds');
    expect(near, greaterThan(0.5));
  });

  test('parseSelectionUrls dedupes, keeps order, drops non-http', () {
    expect(
      parseSelectionUrls(
          '["https://a.com/1.jpg","https://b.com/2.jpg","https://a.com/1.jpg","data:image/png;base64,x"]'),
      ['https://a.com/1.jpg', 'https://b.com/2.jpg'],
    );
    expect(parseSelectionUrls('not json'), isEmpty);
    expect(parseSelectionUrls(null), isEmpty);
  });

  test('unsplash + lexica search urls', () {
    expect(unsplashSearchUrl('neon cat'),
        'https://unsplash.com/s/photos/neon%20cat');
    expect(lexicaSearchUrl('neon cat'), 'https://lexica.art/?q=neon+cat');
  });

  test('absorbSetCookies rotates 1PSIDTS and keeps the rest of the jar',
      () {
    const jar = '__Secure-1PSID=AAA; __Secure-1PSIDTS=OLD; SID=BBB';
    final out = SessionStore.absorbSetCookies(jar,
        '__Secure-1PSIDTS=NEWTS; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT; Secure; HttpOnly');
    expect(out, contains('__Secure-1PSIDTS=NEWTS'));
    expect(out, contains('__Secure-1PSID=AAA'));
    expect(out, contains('SID=BBB'));
    expect(out, isNot(contains('OLD')));
  });

  test('absorbSetCookies handles comma-joined headers with Expires dates',
      () {
    const jar = '__Secure-1PSID=AAA; __Secure-1PSIDTS=OLD';
    final out = SessionStore.absorbSetCookies(jar,
        '__Secure-1PSIDTS=T2; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Path=/, NID=xyz123; Expires=Thu, 01 May 2031 07:28:00 GMT; Path=/');
    expect(out, contains('__Secure-1PSIDTS=T2'));
    expect(out, contains('NID=xyz123'));
    expect(out, contains('__Secure-1PSID=AAA'));
  });

  test('absorbSetCookies adds new cookies and honours deletions', () {
    const jar = '__Secure-1PSID=AAA; OLDCOOKIE=zzz';
    final out = SessionStore.absorbSetCookies(jar,
        'NEWCOOKIE=fresh; Path=/, OLDCOOKIE=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/');
    expect(out, contains('NEWCOOKIE=fresh'));
    expect(out, isNot(contains('OLDCOOKIE')));
    expect(SessionStore.absorbSetCookies(jar, null), jar);
    expect(SessionStore.absorbSetCookies(jar, ''), jar);
  });

  test('auto-renew setting defaults ON and persists', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SessionStore.loadAutoRenew(), isTrue);
    await SessionStore.saveAutoRenew(false);
    expect(await SessionStore.loadAutoRenew(), isFalse);
    await SessionStore.saveAutoRenew(true);
    expect(await SessionStore.loadAutoRenew(), isTrue);
  });

  test('parseBatchPrompts: one non-empty line = one job, trimmed', () {
    expect(parseBatchPrompts('  neon lake \n\nmountain dusk\n   \ncalm sea'),
        ['neon lake', 'mountain dusk', 'calm sea']);
    expect(parseBatchPrompts(''), isEmpty);
    expect(parseBatchPrompts('\n\n'), isEmpty);
    expect(parseBatchPrompts('single'), ['single']);
  });

  test('Mobile + desktop user agents are distinct and well-formed', () {
    expect(GeminiApi.mobileUserAgent, contains('Mobile'));
    expect(GeminiApi.mobileUserAgent, contains('Android'));
    expect(GeminiApi.chromeUserAgent, isNot(contains('Mobile')));
    expect(GeminiApi.mobileUserAgent, isNot(GeminiApi.chromeUserAgent));
  });

  testWidgets('Batch mode shows the live queue panel', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // Turn batch on (keyed — the background-mode switch shares
    // the screen since v77, so Switch.first no longer means Batch).
    await tester
        .tap(find.byKey(const ValueKey('batchSwitch')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Batch mode: write one prompt per line — each line generates one full set, in order.'),
        findsOneWidget);
    // Type three job lines into the prompt field (first TextField).
    await tester.enterText(
        find.byType(TextField).first, 'neon lake\nmountain dusk\ncalm sea');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Batch queue'), findsOneWidget);
    expect(find.text('3 sets'), findsOneWidget);
    expect(find.text('neon lake'), findsWidgets);
    expect(find.text('mountain dusk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Image to Prompt home: Browser / Prompts / Options cards',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: ImageSearchScreen(promptMode: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Image to Prompt'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('External browser — Chrome / Firefox'),
        findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('How it works'), findsOneWidget);
    expect(find.text('Prompts'), findsOneWidget);
    expect(find.text('0 ready'), findsOneWidget);
    expect(find.text('No prompts yet'), findsOneWidget);
    expect(find.text('Options'), findsOneWidget);
    expect(find.text('Auto-add to Prompts list'), findsOneWidget);
    expect(find.text('Auto - browser sign-in, else saved'), findsOneWidget);
    expect(find.text('Similarity target'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Note: the pushed Browser page is a link-bridge panel (no
    // embedded web view); it needs platform channels to exercise,
    // so it is covered by the on-device runs instead.
  });

  group('GeckoSignIn.headerFromCookiesJson', () {
    test('keeps only session cookie names, joins as a header', () {
      final json = jsonEncode([
        {
          'name': '__Secure-1PSID',
          'value': 'psid-value',
          'domain': '.google.com'
        },
        {
          'name': '__Secure-1PSIDTS',
          'value': 'ts-value',
          'domain': '.google.com'
        },
        {'name': 'CONSENT', 'value': 'yes', 'domain': '.google.com'},
        {'name': 'OGPC', 'value': 'x', 'domain': '.google.com'},
        {'name': 'SID', 'value': 'sid-value', 'domain': '.google.com'},
        {'name': 'NID', 'value': '', 'domain': '.google.com'},
      ]);
      final header = GeckoSignIn.headerFromCookiesJson(json);
      expect(
          header,
          '__Secure-1PSID=psid-value; __Secure-1PSIDTS=ts-value; '
          'SID=sid-value');
      expect(SessionStore.cookieHeaderLooksLoggedIn(header), isTrue);
    });

    test('empty, garbage and non-list input yield an empty header', () {
      expect(GeckoSignIn.headerFromCookiesJson(null), '');
      expect(GeckoSignIn.headerFromCookiesJson(''), '');
      expect(GeckoSignIn.headerFromCookiesJson('not json'), '');
      expect(GeckoSignIn.headerFromCookiesJson('{"name":"SID"}'), '');
      expect(GeckoSignIn.headerFromCookiesJson('[]'), '');
    });
  });

  group('GeckoBrowser.parseRequests', () {
    test('splits the extension wrapper into per-action requests', () {
      final payload = jsonEncode({
        'type': 'q',
        'page': 'https://www.pinterest.com/search/pins/?q=cat',
        'title': 'Pinterest',
        'q': [
          jsonEncode({
            'action': 'select',
            'images': [
              {'src': 'https://i.pinimg.com/a.jpg', 'hi': 'https://i.pinimg.com/big-a.jpg', 'alt': 'Cat'},
            ],
          }),
          jsonEncode({
            'action': 'generate_basket',
            'images': [],
          }),
          'not json at all',
          jsonEncode({
            'action': 'unselect',
            'images': [
              {'src': ''},
              {'src': 'https://i.pinimg.com/b.jpg'},
            ],
          }),
        ],
      });
      final reqs = GeckoBrowser.parseRequests(payload);
      expect(reqs, hasLength(3));
      expect(reqs[0].action, 'select');
      expect(reqs[0].images.single.src, 'https://i.pinimg.com/a.jpg');
      expect(reqs[0].images.single.hi, 'https://i.pinimg.com/big-a.jpg');
      expect(reqs[0].page, contains('pinterest.com'));
      expect(reqs[1].action, 'generate_basket');
      expect(reqs[1].images, isEmpty);
      expect(reqs[2].action, 'unselect');
      expect(reqs[2].images.single.src, 'https://i.pinimg.com/b.jpg');
    });

    test('garbage payload yields no requests', () {
      expect(GeckoBrowser.parseRequests('nope'), isEmpty);
      expect(GeckoBrowser.parseRequests('{}'), isEmpty);
    });
  });

  group('StreamGenerate current wire format', () {
    test('buildGenerateFrame produces the 81-slot frame', () {
      final content = ['a red barn at dusk', 0, null, null, null, null, 0];
      final f = GeminiApi.buildGenerateFrame(content, 'UUID-1');
      expect(f.length, 81);
      expect(f[0], content);
      expect(f[1], ['en']);
      expect(f[2], ['', '', '', null, null, null, null, null, null, '']);
      expect(f[6], [1]);
      expect(f[7], 1); // streaming flag
      expect(f[10], 1);
      expect(f[17], [[0]]);
      expect(f[27], 1);
      expect(f[30], [4]);
      expect(f[41], [1]);
      expect(f[59], 'UUID-1');
      expect(f[61], isEmpty);
      expect(f[68], 1);
      expect(f[79], 1);
      expect(f[80], 1);
    });

    test('parser surfaces the server error code (1037 usage limit)',
        () {
      final payload = jsonEncode([
        null,
        ['c_1', 'r_1'],
        null,
        null,
        [
          ['rc_1', ['']]
        ]
      ]);
      final entry = [
        'wrb.fr',
        null,
        payload,
        null,
        null,
        [
          null,
          null,
          [
            [null, [1037]]
          ]
        ]
      ];
      final raw = ")]}'\n${jsonEncode([entry])}\n";
      final parsed = GeminiApi().parseStreamGenerateResponse(raw);
      expect(parsed.errorCode, 1037);
      expect(parsed.urls, isEmpty);
    });

    test('parser still extracts text + image urls from a good reply',
        () {
      const img =
          'https://lh3.googleusercontent.com/gg/ABC123def456GHI789jkl012MNO345pqr678STU901vwx234YZ';
      final payload = jsonEncode([
        null,
        ['c_1', 'r_1'],
        null,
        null,
        [
          [
            'rc_1',
            ['Here is your image'],
            null,
            null,
            [
              [img]
            ]
          ]
        ]
      ]);
      final raw = ")]}'\n${jsonEncode([
            ['wrb.fr', null, payload]
          ])}\n";
      final parsed = GeminiApi().parseStreamGenerateResponse(raw);
      expect(parsed.errorCode, isNull);
      expect(parsed.assistantText, 'Here is your image');
      expect(parsed.urls, contains(img));
    });
  });

  group('GeminiApi.downloadCandidates', () {
    test('issued url first, verbatim, for a preview-suffixed gg-dl url',
        () {
      const issued =
          'https://lh3.googleusercontent.com/gg-dl/AbCdEf=s1024-rj';
      expect(GeminiApi.downloadCandidates(issued), [
        issued,
        'https://lh3.googleusercontent.com/gg-dl/AbCdEf=d-I?alr=yes',
        'https://lh3.googleusercontent.com/gg-dl/AbCdEf=s2048-rj',
        'https://lh3.googleusercontent.com/gg-dl/AbCdEf',
        'https://lh3.googleusercontent.com/gg-dl/AbCdEf=s0',
      ]);
    });

    test('plain =s1024 suffix is replaced, not stacked, in derived forms',
        () {
      const issued = 'https://lh3.googleusercontent.com/gg-dl/XyZ=s1024';
      final c = GeminiApi.downloadCandidates(issued);
      expect(c.first, issued);
      expect(c,
          contains('https://lh3.googleusercontent.com/gg-dl/XyZ=s2048-rj'));
      expect(
          c,
          isNot(contains(
              'https://lh3.googleusercontent.com/gg-dl/XyZ=s1024=s2048-rj')));
    });

    test('no suffix: bare token is the issued form, then derived forms',
        () {
      const issued = 'https://lh3.googleusercontent.com/gg/ABC123';
      expect(GeminiApi.downloadCandidates(issued), [
        issued,
        'https://lh3.googleusercontent.com/gg/ABC123=d-I?alr=yes',
        'https://lh3.googleusercontent.com/gg/ABC123=s2048-rj',
        'https://lh3.googleusercontent.com/gg/ABC123=s1024-rj',
        'https://lh3.googleusercontent.com/gg/ABC123=s0',
      ]);
    });

    test('issued download form keeps its query; base strips it', () {
      const issued =
          'https://lh3.googleusercontent.com/gg-dl/Q9=d-I?alr=yes';
      final c = GeminiApi.downloadCandidates(issued);
      expect(c.first, issued);
      expect(c.length, c.toSet().length);
      expect(
          c, contains('https://lh3.googleusercontent.com/gg-dl/Q9=s2048-rj'));
    });
  });

  group('ChromiumStudioBrowser.adapt', () {
    test('maps a CDP overlay request to the shared model', () {
      const r = WebImageRequest(
        'capture',
        [
          WebImageRef('capture:image:abc', 'Video frame', 0, 0, meta: {
            'kind': 'video',
            'rect': {'x': 1, 'y': 2, 'w': 300, 'h': 200},
            'frac': {'x': 0.1, 'y': 0.1, 'w': 0.5, 'h': 0.4},
          }),
        ],
        'https://www.pinterest.com/pin/1/',
        'Pin',
        'SESSION-1',
      );
      final a = ChromiumStudioBrowser.adapt(r);
      expect(a.action, 'capture');
      expect(a.page, 'https://www.pinterest.com/pin/1/');
      expect(a.sessionId, 'SESSION-1');
      expect(a.images.single.kind, 'video');
      expect((a.images.single.meta['rect'] as Map)['w'], 300);
    });

    test('ChromiumBrowser.isGeminiAppTitle separates app from sign-in',
        () {
      expect(ChromiumBrowser.isGeminiAppTitle('Google Gemini'), isTrue);
      expect(
          ChromiumBrowser.isGeminiAppTitle('Google Gemini - Google Chrome'),
          isTrue);
      expect(
          ChromiumBrowser.isGeminiAppTitle('Sign in - Google Accounts'),
          isFalse);
      expect(ChromiumBrowser.isGeminiAppTitle('Pinterest'), isFalse);
    });
  });
}

Uint8List _solidPng(int r, int g, int b, {int w = 64, int h = 64}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return img.encodePng(im);
}

void _imagePipelineTests() {
  group('Image pipeline (v28 no-freeze)', () {
    test('resizeToJpg runs off-thread and returns an exact-size JPG',
        () async {
      final prepared =
          await ImageService().resizeToJpg(_solidPng(90, 120, 200), 90, 160);
      expect(prepared.width, 90);
      expect(prepared.height, 160);
      // JPEG magic bytes.
      expect(prepared.bytes[0], 0xFF);
      expect(prepared.bytes[1], 0xD8);
      expect(prepared.bytes.length, greaterThan(100));
    });
    test('resizeToJpg rejects undecodable bytes', () async {
      await expectLater(
        ImageService().resizeToJpg(Uint8List.fromList([1, 2, 3, 4]), 90, 160),
        throwsA(anything),
      );
    });
  });
}

void _originalityTests() {
  group('Originality pixel analysis', () {
    test('identical pictures read as a near-total copy', () {
      final a = _solidPng(200, 40, 40);
      final r = analyzeOriginality(a, a);
      expect(r.similarity, greaterThan(95));
      expect(r.creative, lessThan(5));
    });
    test('dominant colours of solid pictures are exact', () {
      final r =
          analyzeOriginality(_solidPng(220, 30, 30), _solidPng(30, 30, 220));
      expect(hexOf(r.refColors.first), '#DC1E1E');
      expect(hexOf(r.genColors.first), '#1E1EDC');
    });
    test('different textured pictures read as mostly creative', () {
      Uint8List warm() {
        final im = img.Image(width: 64, height: 64);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            if (y < 32 && x < 32) {
              im.setPixelRgb(x, y, 230, 40, 30);
            } else if (y < 32) {
              im.setPixelRgb(x, y, 240, 140, 20);
            } else if (x < 32) {
              im.setPixelRgb(x, y, 120, 20, 20);
            } else {
              im.setPixelRgb(x, y, 240, 200, 60);
            }
          }
        }
        return img.encodePng(im);
      }

      Uint8List cool() {
        final im = img.Image(width: 64, height: 64);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            if ((x ~/ 8) % 2 == 0) {
              im.setPixelRgb(x, y, 20, 40, 160);
            } else {
              im.setPixelRgb(x, y, 20, 140, 140);
            }
          }
        }
        return img.encodePng(im);
      }

      final r = analyzeOriginality(warm(), cool());
      expect(r.similarity, lessThan(45));
    });
    test('inverted halves read as different composition', () {
      Uint8List halves(bool flip) {
        final im = img.Image(width: 64, height: 64);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            final white = (x < 32) != flip;
            im.setPixelRgb(x, y, white ? 255 : 0, white ? 255 : 0,
                white ? 255 : 0);
          }
        }
        return img.encodePng(im);
      }

      final r = analyzeOriginality(halves(false), halves(true));
      expect(r.composition, lessThan(30));
    });
    test('reference store links a prompt to its picture', () {
      ReferenceStore.remember('  a   prompt ', _solidPng(1, 2, 3), 'ref.png');
      expect(ReferenceStore.lookup('a prompt')?.label, 'ref.png');
      expect(ReferenceStore.lookup('unknown'), isNull);
    });
  });
}
