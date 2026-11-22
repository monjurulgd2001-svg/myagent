// v82: Auto Cinematic Scene — any prompt, even two words, is
// expanded into one rich cinematic scene before the anchor is
// made, and a cinematic finish layer is appended to the anchor
// and to every 24h/battery chain prompt. The expansion stays
// NEUTRAL (no time-of-day bias for 24h, no charge bias for
// battery) so it never fights the stage directions, and a failed
// expansion falls back to the raw prompt in the engine.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/studio_constants.dart';

void main() {
  test('24h expansion keeps the idea and stays time-neutral', () {
    final instruction =
        GeminiApi.buildSceneExpansionInstruction('a mountain lake', 'set_24h');
    expect(instruction, contains('a mountain lake'));
    expect(instruction, contains('cinematic'));
    expect(instruction, contains('24-hour set'));
    expect(instruction, contains('do NOT describe any time of day'));
    expect(instruction, contains('morning, midday, evening, night'));
    expect(instruction, contains('Output ONLY the scene description'));
    expect(instruction, isNot(contains('charge level')));
    expect(instruction, isNot(contains('battery-level')));
  });

  test('battery expansion keeps the idea and stays charge-neutral', () {
    final instruction = GeminiApi.buildSceneExpansionInstruction(
        'a glowing crystal', 'set_battery');
    expect(instruction, contains('a glowing crystal'));
    expect(instruction, contains('cinematic'));
    expect(instruction, contains('battery-level set'));
    expect(instruction, contains('ONE clear glow or energy element'));
    expect(instruction, contains('do NOT describe any charge level'));
    expect(instruction, contains('Output ONLY the scene description'));
    expect(instruction, isNot(contains('time of day')));
    expect(instruction, isNot(contains('sunrise')));
  });

  test('both expansions demand one centered vertical scene', () {
    for (final mode in ['set_24h', 'set_battery']) {
      final instruction =
          GeminiApi.buildSceneExpansionInstruction('a rose garden', mode);
      expect(instruction, contains('vertical 9:16'));
      expect(instruction, contains('main subject centered'));
      expect(instruction, contains('40-70 words'));
      expect(instruction, contains('Do NOT mention multiple images'));
    }
  });

  test('cinematic finish suffix is the better-than-rules look', () {
    expect(kCinematicSceneSuffix, contains('cinematic premium wallpaper'));
    expect(kCinematicSceneSuffix, contains('photorealistic intricate detail'));
    expect(kCinematicSceneSuffix, contains('volumetric light'));
    expect(kCinematicSceneSuffix, contains('cinematic color grading'));
    expect(kCinematicSceneSuffix, contains('tack-sharp focus on the hero'));
  });
}
