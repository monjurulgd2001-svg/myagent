// v153 — voice prompt (Windows only).
//
// The mic was removed on the user's order in v143 (main.dart: the
// row clear X and voice mic went together) — Android keeps that
// removal exactly. On Windows the mic comes back: the tree already
// depends on speech_to_text ^7.4.0, and its Windows implementation
// (speech_to_text_windows, the package's declared default_package
// for Windows) is already resolved in pubspec.lock, so this wires
// a real cross-platform speech path — no new dependency, no stub.
//
// The helper never throws: no mic, no permission, or no recogniser
// all come back as null, and the UI just leaves the field as-is.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoicePrompt {
  VoicePrompt({stt.SpeechToText? speech}) : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;

  /// The mic is a Windows-only control (Android keeps the v143
  /// removal). Pure, so the UI gate is unit-testable.
  static bool isSupportedOn(TargetPlatform platform) =>
      platform == TargetPlatform.windows;

  /// Listens once and returns the recognised words, or null when
  /// speech is unavailable / nothing was heard / the user stayed
  /// silent. Completes on the final result, or after [timeout]
  /// with whatever was heard so far ('' counts as nothing).
  Future<String?> listenOnce({
    Duration timeout = const Duration(seconds: 30),
    String localeId = 'en-US',
  }) async {
    try {
      final available = await _speech.initialize(
        onStatus: (_) {},
        onError: (_) {},
      );
      if (!available) return null;
      final done = Completer<String?>();
      var heard = '';
      Timer? timer;
      timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete(heard.isEmpty ? null : heard);
        unawaited(_speech.stop());
      });
      await _speech.listen(
        onResult: (r) {
          heard = r.recognizedWords;
          if (r.finalResult && !done.isCompleted) {
            timer?.cancel();
            done.complete(heard.isEmpty ? null : heard);
            unawaited(_speech.stop());
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenFor: timeout,
          pauseFor: const Duration(seconds: 3),
          localeId: localeId,
        ),
      );
      final out = await done.future;
      timer.cancel();
      return out;
    } catch (_) {
      try {
        await _speech.cancel();
      } catch (_) {}
      return null;
    }
  }
}
