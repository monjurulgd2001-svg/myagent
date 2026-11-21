// Voice prompt (v51): locale choice and dictation appending are
// pure helpers, so they are unit-tested here. The recogniser
// itself (speech_to_text + the phone's engine) cannot run in a
// widget test — the widget test only checks the mic button is
// present and that tapping it without a recogniser fails softly
// with a SnackBar instead of crashing.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/voice_prompt.dart';

void main() {
  test('chooseVoiceLocale prefers the system locale when offered', () {
    expect(
        chooseVoiceLocale(
            systemLocaleId: 'bn_BD',
            available: const ['en_US', 'bn_BD', 'hi_IN']),
        'bn_BD');
  });

  test('chooseVoiceLocale falls back to en_US, then first available', () {
    expect(
        chooseVoiceLocale(
            systemLocaleId: 'bn_BD',
            available: const ['en_US', 'fr_FR']),
        'en_US');
    expect(
        chooseVoiceLocale(
            systemLocaleId: 'bn_BD', available: const ['fr_FR', 'de_DE']),
        'fr_FR');
    expect(
        chooseVoiceLocale(systemLocaleId: null, available: const []), isNull);
  });

  test('appendDictation starts the field and trims', () {
    expect(appendDictation('', '  a fox in forest  ', batch: false),
        'a fox in forest');
    expect(appendDictation('', 'a fox', batch: true), 'a fox');
  });

  test('appendDictation joins with a space in single mode', () {
    expect(appendDictation('a fox', 'in forest', batch: false),
        'a fox in forest');
  });

  test('appendDictation starts a new line per chunk in batch mode', () {
    expect(appendDictation('a fox', 'calm sea', batch: true),
        'a fox\ncalm sea');
  });

  test('appendDictation ignores an empty chunk', () {
    expect(appendDictation('a fox', '   ', batch: false), 'a fox');
  });
}
