// Voice prompt (v51): speak the wallpaper idea instead of typing
// it. The phone's own speech recogniser does the listening
// (speech_to_text); this file owns the recogniser lifecycle plus the
// two pure helpers the UI and the tests share. The transcript lands
// in the Designer prompt field, and from there Polish (v48/v50)
// turns it into a detailed pro prompt — so speaking Bangla works
// too: the recogniser hears it, Polish rewrites it in English.
// The mic button only shows on Android: speech_to_text has no
// Windows implementation, and this project ships Android +
// Windows only (no iOS folder), so the button is platform-gated
// in main.dart and the recogniser is never touched on Windows.
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Pick the recogniser locale: the phone's own system locale when
/// the recogniser offers it, else US English when offered, else the
/// first available locale, else null (the caller then passes no
/// locale and the recogniser uses its own default).
String? chooseVoiceLocale({
  String? systemLocaleId,
  required List<String> available,
}) {
  if (available.isEmpty) return null;
  if (systemLocaleId != null && available.contains(systemLocaleId)) {
    return systemLocaleId;
  }
  if (available.contains('en_US')) return 'en_US';
  return available.first;
}

/// Append a dictated chunk to the prompt field text. Single mode
/// joins with a space; batch mode starts a new line per chunk so
/// each dictation becomes its own set line. Empty chunks change
/// nothing, and surrounding whitespace is trimmed.
String appendDictation(String current, String spoken,
    {required bool batch}) {
  final text = spoken.trim();
  if (text.isEmpty) return current;
  final base = current.trim();
  if (base.isEmpty) return text;
  return batch ? '$base\n$text' : '$base $text';
}

/// Thin wrapper around the platform speech recogniser. [start]
/// returns (true, null) once listening, or (false, message) with a
/// user-facing reason when voice input cannot start (no recogniser,
/// no permission, no plugin on this platform). Errors mid-session
/// go to [onFailure]; the end of a session arrives via [onStatus]
/// ('done' / 'notListening').
class VoicePromptController {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool get isListening => _speech.isListening;

  Future<(bool, String?)> start({
    required void Function(String transcript, bool isFinal) onResult,
    required void Function(String message) onFailure,
    required void Function(String status) onStatus,
  }) async {
    try {
      final available = await _speech.initialize(
        onError: (e) => onFailure(_errorMessage(e.errorMsg)),
        onStatus: onStatus,
      );
      if (!available) {
        return (false, 'Voice input is not available on this device.');
      }
      final system = await _speech.systemLocale();
      final locales = await _speech.locales();
      final localeId = chooseVoiceLocale(
        systemLocaleId: system?.localeId,
        available: locales.map((l) => l.localeId).toList(),
      );
      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          listenFor: const Duration(minutes: 2),
          pauseFor: const Duration(seconds: 5),
        ),
        onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      );
      return (true, null);
    } catch (_) {
      // Missing plugin / no recogniser on this device or build:
      // voice is an optional input, never a crash.
      return (false, 'Voice input is not available on this device.');
    }
  }

  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  String _errorMessage(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('not-allowed') ||
        m.contains('denied') ||
        m.contains('permission')) {
      return 'Microphone permission is off — allow it in Settings to speak your prompt.';
    }
    return 'Voice input stopped: $msg';
  }
}
