// v75: a frozen network must fail loudly, never hang the
// generation forever while the foreground notification claims
// it is still running.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:http/http.dart' as http;

/// A client whose requests never complete — what a frozen
/// radio (Doze / HiOS on lock) looks like to the app.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

void main() {
  test('callStreamGenerate times out instead of hanging forever', () async {
    final api = GeminiApi(
      client: _HangingClient(),
      rpcTimeout: const Duration(milliseconds: 200),
    );
    const session = GeminiSession(
      authUser: 0,
      email: 'test@example.com',
      at: 'test-at',
      bl: '',
      fSid: '',
      cookieHeader: '',
      fetchedAtMs: 0,
    );
    await expectLater(
      api.callStreamGenerate(prompt: 'test prompt', session: session),
      throwsA(isA<TimeoutException>()),
    );
  });
}
