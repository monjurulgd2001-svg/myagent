// v80/v81: the four modes' rules prompts, matched against the
// generate-main ZIP (image_Generator.zip) the user sent —
// SetTypes.variants + SetArcs + the Single Landscape variant —
// then corrected in v81 to the OFFICIAL Zedge rules PDFs the user
// sent (24-hour-wallpaper-rules.pdf, battery_rules_bangla.pdf):
//   - 24h 'light' arc = the precise light spec (hour, light angle
//     and elevation, Kelvin, shadow length and direction) — the
//     ZIP's soft texts were too vague, so only light, color and
//     atmosphere change, never the scene.
//   - Battery 'energy' arc = the precise charge-level ladder
//     (lit %, halo, bloom, shadow) — same reason.
//   - Battery 'growth' arc keeps the subject at its usual size
//     and position; only its glow blooms (wilting at low, full
//     bloom at full). 'awaken' keeps the usual pose; only the
//     glow aura changes. Charging gets its own power-motif clause.
//   - The no-text guard is appended by the engine, never baked into
//     the constants.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/studio_constants.dart';

void main() {
  test('24h light arc is the precise light spec from the Zedge rules', () {
    final light = kStoryArcs24h['light']!;
    expect(light.length, 4);
    expect(
        light[0],
        ', 6 am dawn: key light low on the horizon from the left at about 10 degrees elevation, roughly 3000K rose-gold color temperature, long soft shadows stretching to the right, low-lying mist, cool blue shadow tones, high-key gentle contrast, fresh tranquil mood');
    expect(
        light[1],
        ', 1 pm midday: key light almost straight overhead at about 80 degrees elevation, roughly 5600K neutral white daylight, short hard shadows directly under the subject, no mist, maximum color saturation and micro-detail, bright high-contrast clarity');
    expect(
        light[2],
        ', 6 pm golden hour: key light raking in low from the right at about 8 degrees elevation, roughly 2200K amber-orange color temperature, long dramatic shadows falling to the left, warm haze and strong rim light tracing every edge, glowing low-sun flare');
    expect(
        light[3],
        ', 11 pm night: no sun, only cool moonlight from high behind at roughly 7500K deep indigo, about 70 percent of the frame in deep shadow, silver specular highlights on edges only, soft local glow from the scene own light sources, low-key nocturnal calm');
    // The arc and the StageDef fallback carry the same precise texts.
    for (var i = 0; i < 4; i++) {
      expect(light[i], k24hStages[i].promptSuffix);
    }
  });

  test('24h stages carry the precise variant texts as fallback', () {
    expect(k24hStages.length, 4);
    expect(k24hStages[0].promptSuffix, contains('6 am dawn'));
    expect(k24hStages[0].promptSuffix, contains('3000K rose-gold'));
    expect(k24hStages[1].promptSuffix, contains('1 pm midday'));
    expect(k24hStages[2].promptSuffix, contains('6 pm golden hour'));
    expect(k24hStages[3].promptSuffix, contains('11 pm night'));
    expect(k24hStages[3].promptSuffix, contains('7500K deep indigo'));
  });

  test('battery energy arc is the charge-level ladder from the Zedge rules',
      () {
    final energy = kStoryArcsBattery['energy']!;
    expect(energy.length, 6);
    expect(
        energy[0],
        ', charge level 0 of 100: the scene is almost completely dark, about 5 percent of the frame carries any light, a single dim ember of its own glow hue no larger than a coin, no bloom, no light spill, deep crushed black shadows filling the rest of the frame');
    expect(
        energy[5],
        ', charge level 100 of 100: the whole frame is flooded with light at maximum output, the glow core is blown out pure white at its center with saturated hue at its rim, extreme bloom covering the entire frame, strong star-burst flare, glowing atmospheric haze everywhere, zero dark areas anywhere in the image');
    // The arc and the StageDef fallback carry the same ladder texts.
    for (var i = 0; i < 6; i++) {
      expect(energy[i], kBatteryStages[i].promptSuffix);
    }
  });

  test('battery growth arc keeps size and position, only the glow blooms',
      () {
    final growth = kStoryArcsBattery['growth']!;
    expect(growth.length, 6);
    for (final s in growth) {
      expect(s, contains('usual size and position'));
      expect(s, isNot(contains('monumental')));
      expect(s, isNot(contains('sprouting')));
      expect(s, isNot(contains('filling most of the frame')));
    }
    expect(growth[0], contains('tightly folded as if wilting'));
    expect(growth[5], contains('in full bloom'));
  });

  test('battery awaken arc keeps the pose, only the glow aura changes', () {
    final awaken = kStoryArcsBattery['awaken']!;
    expect(awaken.length, 6);
    for (final s in awaken) {
      expect(s, contains('usual pose'));
      expect(s, isNot(contains('motion trails')));
      expect(s, isNot(contains('stirring awake with gentle motion')));
      expect(s, isNot(contains('active and dynamic')));
    }
    expect(awaken[0], contains('dormant and perfectly still'));
    expect(awaken[5], contains('at peak glow'));
  });

  test('Zedge rules clauses: centered subject and charging power motif', () {
    expect(kCenteredSubjectClause, contains('centered in the frame'));
    expect(kChargingMotifClause, contains('power motif'));
    expect(kChargingMotifClause, contains('as if it is charging'));
    expect(kChargingMotifClause, contains('distinct from the full-brightness'));
  });

  test('battery stages carry the charge-level ladder as fallback', () {
    expect(kBatteryStages.length, 6);
    expect(kBatteryStages[0].promptSuffix,
        contains('charge level 0 of 100'));
    expect(kBatteryStages[0].promptSuffix, contains('no larger than a coin'));
    expect(kBatteryStages[5].promptSuffix,
        contains('charge level 100 of 100'));
    expect(kBatteryStages[5].promptSuffix, contains('zero dark areas'));
  });

  test('dual stages keep the ZIP lock/home framing texts', () {
    expect(kDualStages.length, 2);
    expect(kDualStages[0].promptSuffix, contains('macro close-up'));
    expect(kDualStages[0].promptSuffix,
        contains('hero fills about 80 percent'));
    expect(kDualStages[1].transitionInstruction,
        contains('wide establishing view'));
    expect(kDualStages[1].transitionInstruction,
        contains('about 30 percent of the frame height'));
  });

  test('foldable prompt is the ZIP Landscape variant rules text', () {
    expect(kFoldableAdaptationPrompt, contains('(7:6, slightly wider than tall)'));
    expect(kFoldableAdaptationPrompt,
        contains('12 percent safe margin on the left and right edges'));
    expect(kFoldableAdaptationPrompt,
        contains('quiet low-detail upper third for the clock and widgets'));
    expect(kFoldableAdaptationPrompt, contains('do not crop the subject'));
    expect(kFoldableAdaptationPrompt, contains('no blurred side fills'));
    // The guard is appended by the engine, not baked into the constant.
    expect(kFoldableAdaptationPrompt, isNot(contains('no text, no letters')));
  });

  test('no arc or stage text bakes in the no-text guard', () {
    for (final stages in [
      ...kStoryArcs24h.values,
      ...kStoryArcsBattery.values,
    ]) {
      for (final s in stages) {
        expect(s, isNot(contains('no text, no letters')));
      }
    }
    for (final st in [...k24hStages, ...kBatteryStages, ...kDualStages]) {
      expect(st.promptSuffix, isNot(contains('no text, no letters')));
      expect(st.transitionInstruction, isNot(contains('no text, no letters')));
    }
  });

  test('arc smart-picks default to light and energy', () {
    expect(suggest24hArc('a mountain lake'), 'light');
    expect(suggest24hArc('a rose garden'), 'bloom');
    // NOTE: 'city street' would pick 'bloom', not 'rhythm' — the ZIP's
    // matcher is plain substring contains, and 'street' contains
    // 'tree'. Same quirk in both codebases, kept identical on purpose.
    expect(suggest24hArc('a city street'), 'bloom');
    expect(suggest24hArc('a busy city market'), 'rhythm');
    expect(suggestBatteryArc('a glowing crystal'), 'growth');
    expect(suggestBatteryArc('a phoenix'), 'awaken');
    expect(suggestBatteryArc('a neon ring'), 'energy');
  });
}
