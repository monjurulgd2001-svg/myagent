// v153 — Windows-only voice prompt.
//
// The mic was removed on the user's order in v143, and Android
// keeps that removal. Windows gets it back through the tree's own
// speech_to_text dependency (its Windows implementation,
// speech_to_text_windows, is already resolved in pubspec.lock).
// These tests cover the gate + the never-throws contract: on a
// host without a speech recogniser, listenOnce must come back
// null instead of crashing the app.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/voice_prompt.dart';

void main() {
  test('mic is a Windows-only control', () {
    expect(VoicePrompt.isSupportedOn(TargetPlatform.windows), isTrue);
    expect(VoicePrompt.isSupportedOn(TargetPlatform.android), isFalse);
    expect(VoicePrompt.isSupportedOn(TargetPlatform.linux), isFalse);
    expect(VoicePrompt.isSupportedOn(TargetPlatform.macOS), isFalse);
  });

  test('listenOnce returns null (never throws) without a recogniser',
      () async {
    final out = await VoicePrompt().listenOnce(
      timeout: const Duration(seconds: 2),
    );
    expect(out, isNull);
  });
}
