// v45: descriptions must never mention the set type / set behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';

void main() {
  group('stripSetTypeMentions', () {
    test('drops the 24-hour sentence, keeps the scene sentence', () {
      const input =
          'A sleek black panther stalks through a neon jungle at midnight. '
          'This 24-hour set transitions smoothly from twilight blues to deep night shadows.';
      expect(GeminiApi.stripSetTypeMentions(input),
          'A sleek black panther stalks through a neon jungle at midnight.');
    });

    test('drops the battery-label sentence', () {
      const input = 'A glowing dragon coils over neon peaks. '
          'This battery set grows brighter with every charge level.';
      expect(GeminiApi.stripSetTypeMentions(input),
          'A glowing dragon coils over neon peaks.');
    });

    test('leaves a clean description untouched', () {
      const input =
          'A serene mountain lake at dawn with soft mist and glassy reflections.';
      expect(GeminiApi.stripSetTypeMentions(input), input);
    });

    test('sunset and a wolf pack are not set mentions', () {
      const input =
          'A wolf pack under a huge sunset sky, warm golden light everywhere.';
      expect(GeminiApi.stripSetTypeMentions(input), input);
    });

    test('all-set text falls back to phrase stripping', () {
      const input =
          'This 24-hour set transitions smoothly from twilight blues to deep night shadows.';
      final out = GeminiApi.stripSetTypeMentions(input);
      expect(out.toLowerCase(), isNot(contains('24')));
      expect(out.toLowerCase(), isNot(contains('set')));
      expect(out, contains('twilight blues'));
    });
  });
}
