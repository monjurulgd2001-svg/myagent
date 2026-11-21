// Constants ported 1:1 from the extension's background.js:
// story arcs, variation strengths, default stage templates, Zedge rules.
import 'dart:math' as math;

import 'models.dart';

const int kPortraitWidth = 1620;
const int kPortraitHeight = 2880;
const int kLandscapeWidth = 2800;
const int kLandscapeHeight = 2400;
const int kMaxZedgeBytes = 8 * 1024 * 1024;
const int kSafeZedgeTargetBytes = 8150000;
const int kMinZedgeWidth = 1620;
const int kMinZedgeHeight = 2880;
const int kMaxZedgeMegapixels = 25000000;

const List<String> kZedgeCategories = [
  'ANIMALS',
  'ANIME',
  'CARS_N_VEHICLES',
  'COMICS',
  'DESIGNS',
  'DRAWINGS',
  'ENTERTAINMENT',
  'FUNNY',
  'GAMES',
  'HOLIDAYS',
  'LOVE',
  'MUSIC',
  'NATURE',
  'PATTERNS',
  'PEOPLE',
  'SAYINGS',
  'SPACE',
  'SPIRITUAL',
  'SPORTS',
  'TECHNOLOGY',
];

const String kNoTextGuard =
    ', no text, no letters, no numbers, no symbols, no icons, no watermark';
const String kProFinishSuffix =
    ', one strong focal point, clean uncluttered composition, professional wallpaper finish';

/// Zedge rules (v81, from the user's 24h + battery rules PDFs):
/// the main subject stays centered in every stage so the artwork
/// scales across screen sizes. The engine appends this to the
/// anchor and to every 24h/battery chain prompt.
const String kCenteredSubjectClause =
    ', keep the main subject centered in the frame';

/// Charging is a UNIQUE version, not just 100% brightness
/// (battery rules PDF): the same scene at full brightness plus a
/// power motif. The engine appends this only to the charging stage.
const String kChargingMotifClause =
    ', charging state: the same scene at full brightness with a unique power motif - glowing energy flowing into the subject as if it is charging, a subtle charging glow, distinct from the full-brightness stage';

/// v82: Auto Cinematic Scene finish — the "better than the rules"
/// layer for 24h/battery sets. The rules PDFs say what must stay
/// the same; this is what makes the scene itself look premium:
/// cinematic depth, volumetric light, refined grading. The engine
/// appends it to the anchor and to every 24h/battery chain prompt.
const String kCinematicSceneSuffix =
    ', cinematic premium wallpaper look, photorealistic intricate detail, rich atmospheric depth, volumetric light and subtle haze, refined cinematic color grading, tack-sharp focus on the hero';

const String kDefaultNegativePrompt =
    'no text, no letters, no numbers, no percentage signs, no battery icons, '
    'no UI widgets, no clock, no watermark, no signature, no logo, no blurry '
    'details, no deformed anatomy';

/// Foldable adaptation prompt (v58 backend-only, rules text from
/// generate-main v80): the ZIP's Single Landscape variant, word for
/// word except the trailing no-text guard — the engine appends the
/// guard + pro finish itself. It used to be one short sentence;
/// the ZIP's full rules text carries the 7:6 frame, the 12%/6%
/// safe margins, the quiet upper third for clock/widgets, and the
/// do-not list (crop/stretch/zoom/duplicate/mirror/new elements).
const String kFoldableAdaptationPrompt =
    'extend this portrait wallpaper outward into a wider landscape frame for foldable and tablet screens (7:6, slightly wider than tall), this is the very same artwork continued sideways, not a new picture, keep the exact same subject identity, geometry, pose, scale, materials, color palette, lighting direction, rendering style and mood - it must be recognizably the same wallpaper at thumbnail size, keep the original portrait composition intact in the middle and continue the existing background, environment and atmosphere naturally to the left and right with seamless matching detail, perspective and light, hero centered horizontally, hero mass slightly below center, whole hero inside the frame with at least 12 percent safe margin on the left and right edges and 6 percent on the top and bottom, quiet low-detail upper third for the clock and widgets, do not crop the subject, do not stretch or squash, do not zoom in, do not duplicate or mirror the subject, do not add new structures or elements the reference does not contain, no borders, no letterbox bars, no blurred side fills';

const Map<String, String> kVariationStrengths = {
  'subtle':
      'Relight the reference image so it matches the ABSOLUTE lighting state described above - treat the stated lit-area, brightness, bloom and shadow values as exact targets to hit, not as a nudge from the reference. The change must be clearly noticeable side by side. Keep the exact same subject, objects, background, layout, composition, framing and art style: nothing may be added, removed or rearranged.',
  'clear':
      'This is a relighting edit, not a copy: rebuild the light and atmosphere of the reference image until it matches the ABSOLUTE state described above - hit the stated lit-area percentage, brightness, bloom radius and shadow depth exactly, even if that means a large jump from the reference. The result must be immediately distinguishable at a glance from any other stage. Keep the exact same subject, objects, background, layout, composition, framing and art style: nothing may be added, removed or rearranged.',
  'strong':
      'Dramatically relight the reference image to the ABSOLUTE state described above: push the stated lit-area percentage, brightness, bloom radius and shadow depth to the limit - bold light direction and color temperature, intense glow and bloom, thick atmosphere - an unmistakable transformation that can never be confused with a neighbouring stage. Keep the exact same subject, objects, background, layout, composition and framing: absolutely nothing may be added, removed or rearranged.',
};

const Map<String, List<String>> kStoryArcs24h = {
  'light': [
    ', 6 am dawn: key light low on the horizon from the left at about 10 degrees elevation, roughly 3000K rose-gold color temperature, long soft shadows stretching to the right, low-lying mist, cool blue shadow tones, high-key gentle contrast, fresh tranquil mood',
    ', 1 pm midday: key light almost straight overhead at about 80 degrees elevation, roughly 5600K neutral white daylight, short hard shadows directly under the subject, no mist, maximum color saturation and micro-detail, bright high-contrast clarity',
    ', 6 pm golden hour: key light raking in low from the right at about 8 degrees elevation, roughly 2200K amber-orange color temperature, long dramatic shadows falling to the left, warm haze and strong rim light tracing every edge, glowing low-sun flare',
    ', 11 pm night: no sun, only cool moonlight from high behind at roughly 7500K deep indigo, about 70 percent of the frame in deep shadow, silver specular highlights on edges only, soft local glow from the scene own light sources, low-key nocturnal calm',
  ],
  'bloom': [
    ', soft dawn light, the subject newly awakening, delicate buds beginning to open, rose-gold glow, misty fresh atmosphere',
    ', harsh midday sun, the subject in full bloom at its peak, vivid saturated colors lit brightly, intense vitality',
    ', ember-orange sunset light, the subject mature and complete, warm glowing rim light on its form, rich dramatic warmth',
    ', cold moonlight, the subject at rest gently closed, silver highlights on its silhouette, deep blue calm',
  ],
  'rhythm': [
    ', soft pale dawn light, the scene calm and nearly empty, misty quiet atmosphere, gentle stillness',
    ', harsh bright midday light, the scene alive with movement, sharp shadows, vivid energetic clarity',
    ', ember-orange evening light, long dramatic shadows, warm glowing atmosphere as the light fades',
    ', cold blue moonlight, the scene asleep and empty, deep shadows, silent tranquil mood',
  ],
};

const Map<String, List<String>> kStoryArcsBattery = {
  'energy': [
    ', charge level 0 of 100: the scene is almost completely dark, about 5 percent of the frame carries any light, a single dim ember of its own glow hue no larger than a coin, no bloom, no light spill, deep crushed black shadows filling the rest of the frame',
    ', charge level 20 of 100: about 20 percent of the frame is lit, the glow is a thin low-intensity core with a tight halo roughly twice its own size, faint light spill on the nearest surface only, the outer two thirds of the frame still sit in deep shadow',
    ', charge level 40 of 100: about 40 percent of the frame is lit, the glow core is clearly brighter and its halo now reaches roughly a quarter of the frame width, visible light rays and reflections on mid-distance surfaces, shadows softened to dark grey but the frame edges stay dark',
    ', charge level 60 of 100: about 60 percent of the frame is lit and roughly two stops brighter than the previous stage, the glow core is burning hot with a wide bloom reaching half the frame width, strong rays and reflections across the whole mid-ground, only the frame corners remain dark',
    ', charge level 80 of 100: about 80 percent of the frame is lit and clearly brighter again, the glow core is near-white hot at its center, heavy bloom with visible lens flare and volumetric light beams crossing the frame, bright haze filling the air, barely any shadow left except thin contact shadows',
    ', charge level 100 of 100: the whole frame is flooded with light at maximum output, the glow core is blown out pure white at its center with saturated hue at its rim, extreme bloom covering the entire frame, strong star-burst flare, glowing atmospheric haze everywhere, zero dark areas anywhere in the image',
  ],
  'growth': [
    ', charge 0 of 100: the subject at its usual size and position in near-darkness, its glow tightly folded as if wilting, about 5 percent of the frame lit by one faint ember of its own glow hue',
    ', charge 20 of 100: the subject at its usual size and position, its glow beginning to open, about 20 percent of the frame lit, the same hue a thin core with a tight halo, the rest in deep shadow',
    ', charge 40 of 100: the subject at its usual size and position, its glow half open, about 40 percent of the frame lit, the identical hue brighter with a halo a quarter of the frame wide, rays and reflections appearing',
    ', charge 60 of 100: the subject at its usual size and position, its glow mostly open and two stops brighter, the same hue burning hot, bloom across half the frame, only corners dark',
    ', charge 80 of 100: the subject at its usual size and position, its glow nearly fully open, about 80 percent of the frame lit, the unchanged hue near-white hot, heavy bloom, flare and volumetric beams',
    ', charge 100 of 100: the subject at its usual size and position in full bloom, the whole image flooded at maximum output in the same hue, blown out white core, extreme bloom, star-burst flare, zero dark areas',
  ],
  'awaken': [
    ', charge 0 of 100: the subject dormant and perfectly still in its usual pose, about 5 percent of the frame lit by a dying ember of its own glow hue, no bloom, crushed black surroundings',
    ', charge 20 of 100: the subject still in its usual pose, about 20 percent of the frame lit, one thin crack of the same hue with a tight halo breaking the dark, everything else in deep shadow',
    ', charge 40 of 100: the subject still in its usual pose, its glow aura gently spreading, about 40 percent of the frame lit, the identical hue spreading, halo a quarter of the frame wide, rays and reflections at mid distance',
    ', charge 60 of 100: the subject still in its usual pose, its glow aura strong and bright, about 60 percent of the frame lit and two stops brighter, the same hue burning hot, bloom across half the frame, only corners dark',
    ', charge 80 of 100: the subject still in its usual pose, its glow aura intensely bright, about 80 percent of the frame lit, the unchanged hue near-white hot, heavy bloom, lens flare, volumetric beams, energy streaming off its form',
    ', charge 100 of 100: the subject still in its usual pose at peak glow, the whole frame flooded at maximum output in the exact same hue, blown out white core, extreme bloom and star-burst flare, zero dark areas',
  ],
};

String suggest24hArc(String prompt) {
  final p = prompt.toLowerCase();
  const bloomWords = [
    'flower',
    'lotus',
    'bloom',
    'blossom',
    'plant',
    'tree',
    'leaf',
    'leaves',
    'garden',
    'petal',
    'rose',
    'nature',
    'forest',
    'flora'
  ];
  if (bloomWords.any(p.contains)) return 'bloom';
  const rhythmWords = [
    'city',
    'street',
    'urban',
    'people',
    'crowd',
    'market',
    'traffic',
    'cafe',
    'town',
    'village',
    'lifestyle'
  ];
  if (rhythmWords.any(p.contains)) return 'rhythm';
  return 'light';
}

String suggestBatteryArc(String prompt) {
  final p = prompt.toLowerCase();
  const growthWords = [
    'flower',
    'plant',
    'tree',
    'seed',
    'leaf',
    'garden',
    'crystal',
    'bloom',
    'nature',
    'lotus'
  ];
  if (growthWords.any(p.contains)) return 'growth';
  const awakenWords = [
    'creature',
    'dragon',
    'animal',
    'being',
    'spirit',
    'robot',
    'phoenix',
    'bird',
    'beast'
  ];
  if (awakenWords.any(p.contains)) return 'awaken';
  return 'energy';
}

String buildNegativeGuard(String negativePrompt) {
  final custom = negativePrompt.trim();
  if (custom.isEmpty || custom == kDefaultNegativePrompt) {
    return custom.isEmpty ? kNoTextGuard : ', strictly avoid: $custom';
  }
  return '$kNoTextGuard, strictly avoid / negative prompt: $custom';
}

String buildStyleSuffix(String displayTarget, String colorBoost) {
  var out = '';
  if (displayTarget == 'amoled') {
    out +=
        ', high contrast, vivid luminous colors, optimized for AMOLED displays';
  } else if (displayTarget == 'ips') {
    out +=
        ', balanced brightness, natural color reproduction, optimized for IPS displays';
  }
  if (colorBoost == 'subtle') {
    out += ', subtly enhanced color richness';
  } else if (colorBoost == 'vivid') {
    out += ', vivid rich colors with enhanced saturation';
  } else if (colorBoost == 'neon') {
    out += ', bold electrifying colors, striking chromatic intensity';
  }
  return out;
}

String buildImagePrompt(
    String rawPrompt, String aspectRatio, bool forceImagePrefix) {
  var prompt = rawPrompt.trim();
  final hasImageVerb = RegExp(
          r'^(generate|create|draw|make|paint|render|design)\s+(an?\s+)?(image|picture|photo|illustration|art|wallpaper)',
          caseSensitive: false)
      .hasMatch(prompt);
  if (forceImagePrefix && !hasImageVerb) {
    prompt = 'Generate an image of: $prompt';
  }
  if (aspectRatio.isNotEmpty &&
      aspectRatio != 'auto' &&
      !prompt.toLowerCase().contains('aspect ratio')) {
    prompt = '$prompt (aspect ratio $aspectRatio)';
  }
  return prompt;
}

/// Enforces the Zedge size rules exactly like normalizeZedgeDimensions().
({int width, int height}) normalizeZedgeDimensions(int width, int height,
    {bool enforce = true}) {
  var w = width == 0 ? kPortraitWidth : width;
  var h = height == 0 ? kPortraitHeight : height;
  if (enforce) {
    if (w < kMinZedgeWidth || h < kMinZedgeHeight) {
      final scaleW = kMinZedgeWidth / w;
      final scaleH = kMinZedgeHeight / h;
      final scale = scaleW > scaleH ? scaleW : scaleH;
      w = (w * scale).round();
      if (w < kMinZedgeWidth) w = kMinZedgeWidth;
      h = (h * scale).round();
      if (h < kMinZedgeHeight) h = kMinZedgeHeight;
    }
    if (w * h >= kMaxZedgeMegapixels) {
      final downScale = math.sqrt(24500000 / (w * h));
      w = (w * downScale).floor();
      if (w < kMinZedgeWidth) w = kMinZedgeWidth;
      h = (h * downScale).floor();
      if (h < kMinZedgeHeight) h = kMinZedgeHeight;
    }
  }
  return (width: w, height: h);
}

const List<StageDef> kDualStages = [
  StageDef(
    key: 'lock',
    distSlot: 'lock',
    zipName: 'lock.jpg',
    slotIndex: 1,
    role: 'dual_lock',
    badge: 'Lock Screen (1/2)',
    shortLabel: 'Lock',
    exactFilename: 'WP_Dual_1_LockScreen.jpg',
    isAnchor: true,
    promptSuffix:
        ', lock screen framing: macro close-up, the hero fills about 80 percent of the frame height, shallow depth of field with a softly blurred background, striking fine surface detail, hero mass in the lower two thirds',
  ),
  StageDef(
    key: 'home',
    distSlot: 'home',
    zipName: 'home.jpg',
    slotIndex: 2,
    role: 'dual_home',
    badge: 'Home Screen (2/2)',
    shortLabel: 'Home',
    exactFilename: 'WP_Dual_2_HomeScreen.jpg',
    transitionInstruction:
        ', home screen framing: wide establishing view of the same scene pulled far back, the hero now occupies only about 30 percent of the frame height and sits low, deep focus, generous calm negative space and quiet low-detail area across the upper half for icons and widgets',
  ),
];

const List<StageDef> k24hStages = [
  StageDef(
    key: 'morning',
    distSlot: 'morning',
    zipName: 'morning.jpg',
    slotIndex: 1,
    role: 'time_morning',
    badge: 'Morning (1/4)',
    shortLabel: 'Morning',
    exactFilename: 'WP_24Hour_1_Morning.jpg',
    isAnchor: true,
    promptSuffix:
        ', 6 am dawn: key light low on the horizon from the left at about 10 degrees elevation, roughly 3000K rose-gold color temperature, long soft shadows stretching to the right, low-lying mist, cool blue shadow tones, high-key gentle contrast, fresh tranquil mood',
  ),
  StageDef(
    key: 'afternoon',
    distSlot: 'afternoon',
    zipName: 'afternoon.jpg',
    slotIndex: 2,
    role: 'time_afternoon',
    badge: 'Afternoon (2/4)',
    shortLabel: 'Afternoon',
    exactFilename: 'WP_24Hour_2_Afternoon.jpg',
    promptSuffix:
        ', 1 pm midday: key light almost straight overhead at about 80 degrees elevation, roughly 5600K neutral white daylight, short hard shadows directly under the subject, no mist, maximum color saturation and micro-detail, bright high-contrast clarity',
  ),
  StageDef(
    key: 'evening',
    distSlot: 'evening',
    zipName: 'evening.jpg',
    slotIndex: 3,
    role: 'time_evening',
    badge: 'Evening (3/4)',
    shortLabel: 'Evening',
    exactFilename: 'WP_24Hour_3_Evening.jpg',
    promptSuffix:
        ', 6 pm golden hour: key light raking in low from the right at about 8 degrees elevation, roughly 2200K amber-orange color temperature, long dramatic shadows falling to the left, warm haze and strong rim light tracing every edge, glowing low-sun flare',
  ),
  StageDef(
    key: 'night',
    distSlot: 'night',
    zipName: 'night.jpg',
    slotIndex: 4,
    role: 'time_night',
    badge: 'Night (4/4)',
    shortLabel: 'Night',
    exactFilename: 'WP_24Hour_4_Night.jpg',
    promptSuffix:
        ', 11 pm night: no sun, only cool moonlight from high behind at roughly 7500K deep indigo, about 70 percent of the frame in deep shadow, silver specular highlights on edges only, soft local glow from the scene own light sources, low-key nocturnal calm',
  ),
];

const List<StageDef> kBatteryStages = [
  StageDef(
    key: 'critical',
    distSlot: 'critical',
    zipName: '0.jpg',
    slotIndex: 1,
    role: 'battery_l1',
    badge: 'Level 1: 0-20% Critical',
    shortLabel: '0% (Critical)',
    exactFilename: 'WP_Battery_Level1_Critical.jpg',
    promptSuffix:
        ', charge level 0 of 100: the scene is almost completely dark, about 5 percent of the frame carries any light, a single dim ember of its own glow hue no larger than a coin, no bloom, no light spill, deep crushed black shadows filling the rest of the frame',
  ),
  StageDef(
    key: 'low',
    distSlot: 'low',
    zipName: '20.jpg',
    slotIndex: 2,
    role: 'battery_l2',
    badge: 'Level 2: 21-40% Low',
    shortLabel: '20% (Low)',
    exactFilename: 'WP_Battery_Level2_Low.jpg',
    promptSuffix:
        ', charge level 20 of 100: about 20 percent of the frame is lit, the glow is a thin low-intensity core with a tight halo roughly twice its own size, faint light spill on the nearest surface only, the outer two thirds of the frame still sit in deep shadow',
  ),
  StageDef(
    key: 'mid',
    distSlot: 'mid',
    zipName: '40.jpg',
    slotIndex: 3,
    role: 'battery_l3',
    badge: 'Level 3: 41-60% Mid',
    shortLabel: '40% (Mid)',
    exactFilename: 'WP_Battery_Level3_Mid.jpg',
    isAnchor: true,
    promptSuffix:
        ', charge level 40 of 100: about 40 percent of the frame is lit, the glow core is clearly brighter and its halo now reaches roughly a quarter of the frame width, visible light rays and reflections on mid-distance surfaces, shadows softened to dark grey but the frame edges stay dark',
  ),
  StageDef(
    key: 'high',
    distSlot: 'high',
    zipName: '60.jpg',
    slotIndex: 4,
    role: 'battery_l4',
    badge: 'Level 4: 61-80% High',
    shortLabel: '60% (High)',
    exactFilename: 'WP_Battery_Level4_High.jpg',
    promptSuffix:
        ', charge level 60 of 100: about 60 percent of the frame is lit and roughly two stops brighter than the previous stage, the glow core is burning hot with a wide bloom reaching half the frame width, strong rays and reflections across the whole mid-ground, only the frame corners remain dark',
  ),
  StageDef(
    key: 'full',
    distSlot: 'full',
    zipName: '80.jpg',
    slotIndex: 5,
    role: 'battery_l5',
    badge: 'Level 5: 81-100% Full',
    shortLabel: '80% (Full)',
    exactFilename: 'WP_Battery_Level5_Full.jpg',
    promptSuffix:
        ', charge level 80 of 100: about 80 percent of the frame is lit and clearly brighter again, the glow core is near-white hot at its center, heavy bloom with visible lens flare and volumetric light beams crossing the frame, bright haze filling the air, barely any shadow left except thin contact shadows',
  ),
  StageDef(
    key: 'charging',
    distSlot: 'charging',
    zipName: '100.jpg',
    slotIndex: 6,
    role: 'battery_charging',
    badge: 'Charging (100% Active)',
    shortLabel: '100% (Charging)',
    exactFilename: 'WP_Battery_Charging.jpg',
    promptSuffix:
        ', charge level 100 of 100: the whole frame is flooded with light at maximum output, the glow core is blown out pure white at its center with saturated hue at its rim, extreme bloom covering the entire frame, strong star-burst flare, glowing atmospheric haze everywhere, zero dark areas anywhere in the image',
  ),
];

List<StageDef> stagesForMode(String workflowMode) {
  switch (workflowMode) {
    case 'set_dual':
      return kDualStages;
    case 'set_battery':
      return kBatteryStages;
    case 'set_24h':
    default:
      return k24hStages;
  }
}

String setTypeLabelFor(String workflowMode) {
  switch (workflowMode) {
    case 'set_dual':
      return 'Dual Wallpaper Set (2 JPGs)';
    case 'set_battery':
      return 'Battery Level Wallpaper Set (6 JPGs)';
    case 'single':
      return 'Single Wallpaper';
    case 'img2img_file':
      return 'Imported / Reference Set';
    case 'set_24h':
    default:
      return '24-Hour Wallpaper Set (4 JPGs)';
  }
}

String slugify(String input, {int maxLen = 32}) {
  var s = input.toLowerCase().replaceAll(RegExp(r'\.[^.]+$'), '');
  s = s
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.length > maxLen) s = s.substring(0, maxLen);
  return s.isEmpty ? 'wallpaper_set' : s;
}
