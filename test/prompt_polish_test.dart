// AI Prompt Polish (v48, rules strengthened in v50): the instruction
// must carry the user's idea through untouched, demand the craft
// details that make a prompt production-ready, and forbid set
// behaviour (the engine adds stage directions itself). v50 adds:
// the polished concept must be fully original (never common,
// similar or copyrighted) and the image must contain none of the
// banned artefacts (text/numbers/%, battery/clock/UI, watermark,
// signature, logo, blur).
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';

void main() {
  test('polish instruction embeds the idea and the craft rules', () {
    final s = GeminiApi.buildPolishInstruction('a fox in forest');
    expect(s, contains('IDEA: a fox in forest'));
    expect(s, contains('Keep the exact same subject and concept'));
    expect(s, contains('vertical 9:16 phone wallpaper'));
    expect(s, contains('colour palette'));
    expect(s, contains('60-110 words'));
    expect(s, contains('Output ONLY the polished prompt'));
  });

  test('polish instruction forbids set behaviour and image text', () {
    final s = GeminiApi.buildPolishInstruction('neon city rain');
    expect(s, contains('Do NOT mention multiple images, sets, collections'));
    expect(s, contains('time-of-day changes or battery levels'));
    expect(s, contains('No text, letters, numbers, percentage signs'));
  });

  // v50: originality + the full banned-artefact list the user ordered
  // into Polish (new concept, never common/similar/copyrighted; no
  // %, battery/clock/UI, signature, blur).
  test('polish instruction demands an original concept and bans all artefacts', () {
    final s = GeminiApi.buildPolishInstruction('a fox in forest');
    expect(s, contains('fully original, new-concept design'));
    expect(s, contains('Never a common, generic or copy-like version'));
    expect(s, contains('never similar to popular or existing designs'));
    expect(s, contains('never a copyrighted element'));
    expect(s, contains('percentage signs (%)'));
    expect(s, contains('battery icons'));
    expect(s, contains('UI widgets'));
    expect(s, contains('clocks or clock faces'));
    expect(s, contains('signatures'));
    expect(s, contains('No blurry, soft or out-of-focus details'));
  });

  test('polish instruction trims the idea', () {
    final s = GeminiApi.buildPolishInstruction('  calm sea  ');
    expect(s, contains('IDEA: calm sea'));
  });
}
