// v118 — sign-in: verify-before-save + a Test failure that says
// WHAT the verify page actually was.
// The bug: every sign-in / Test / Refresh saved the fresh jar BEFORE
// verifying it, so one bad harvest overwrote the working saved login
// — and the failure then said only "Could not find SNlM0e", the same
// message for a dead cookie, a consent page, a bot check, and a
// stale/mixed jar. v118 proves the jar first (getSession's
// verifyHeader), stores it only once it works, and diagnoses the
// page when the token is missing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';

void main() {
  group('v118: diagnoseSessionPage names the page that came back', () {
    test('consent page', () {
      final d = GeminiApi.diagnoseSessionPage(
          '<html><head><title>Before you continue</title></head>'
          '<body><a href="https://consent.google.com">consent</a>'
          '</body></html>');
      expect(d, contains('consent page'));
    });

    test('bot check page', () {
      final d = GeminiApi.diagnoseSessionPage(
          '<html><body>Our systems have detected unusual traffic '
          'from your computer network. Please try again.</body></html>');
      expect(d, contains('bot check'));
    });

    test('Google sign-in page (dead cookies)', () {
      final d = GeminiApi.diagnoseSessionPage(
          '<html><body><form action="https://accounts.google.com/signin">'
          'Sign in to continue to Gemini</form></body></html>');
      expect(d, contains('sign-in page'));
      expect(d, contains('signed out'));
    });

    test('signed-in page with an email but no token (stale/mixed jar)',
        () {
      final d = GeminiApi.diagnoseSessionPage(
          '<html><body>"oPEP7c":"monjurulgd2001@gmail.com" some app '
          'markup with no session token anywhere</body></html>');
      expect(d, contains('monjurulgd2001@gmail.com'));
      expect(d, contains('stale or mixed'));
    });

    test('garbage page reports its length and no token', () {
      const page = '<html><body>nothing here</body></html>';
      final d = GeminiApi.diagnoseSessionPage(page);
      expect(d, contains('no session token at all'));
      expect(d, contains('${page.length} chars'));
    });
  });

  group('v118: verify-before-save markers', () {
    test('getSession takes a verify-only header and diagnoses the page',
        () async {
      final api = await File('lib/gemini_api.dart').readAsString();
      expect(api, contains('String? verifyHeader'));
      expect(api, contains('verifyHeader ??'));
      expect(api, contains('diagnoseSessionPage(html)'));
      // Rotation absorption must not touch the store on a
      // verify-only call.
      expect(api, contains('if (verifyHeader == null)'));
    });

    test('login screen proves the jar before saving it', () async {
      final src = await File('lib/login_screen.dart').readAsString();
      // All four entry points go through the verify-first finish.
      expect(src, contains('_verifyAndFinish(headerToSave: header)'));
      expect(src, contains('_verifyAndFinish(headerToSave: headerToSave)'));
      expect(src, contains('verifyHeader: headerToSave'));
      expect(src, contains('verify-before-save'));
      // The old save-then-verify order and its message are gone.
      expect(src, isNot(contains('Cookies saved. Verifying')));
      expect(
          src,
          isNot(contains(
              'await SessionStore.saveCookieForUser(_authUser, header);\n      if (mounted) setState(() => _cookieCtrl.text = header);\n      await _verifyAndFinish();')));
    });
  });
}
