// v110 — FULL reference UI/UX (his 2026-11-20 "Full ui ux design
// amon cacci fully customize"): the Studio screen is the
// reference's main screen — Text to Image / Image to Image
// segmented toggle, a Prompt card, a Model & Size card with the
// tuning options as chip groups — and the Image-to-Prompt Options
// card uses the roomier padding. All OUR features and labels are
// kept; nothing is faked (no model / resolution / format /
// aspect-ratio controls — the engine is fixed Gemini web, 9:16,
// 1620x2880 JPG by the Zedge spec; no seed — the engine takes none).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v110: Studio is the reference main screen', () async {
    final main = await File('lib/main.dart').readAsString();
    // Segmented Text / Image toggle (same switch as the
    // Reference image button).
    expect(main, contains("'Text to Image'"));
    expect(main, contains("'Image to Image'"));
    expect(main, contains('_imgModeToggle'));
    expect(main, contains("const ValueKey('imgModeText')"));
    expect(main, contains("const ValueKey('imgModeImage')"));
    // The cards (v112: the Set Designer card is gone — the
    // toggle stands alone, the set-type chips live in their own
    // Set type card on top, and the prompt input is the
    // numbered Prompts card).
    expect(main, isNot(contains("const Text('Set Designer'")));
    expect(main,
        contains("_sectionHeader(Icons.format_list_bulleted, 'Prompts')"));
    expect(main, contains("_sectionHeader(Icons.tune, 'Model & Size')"));
    expect(main, contains("'Set type'"));
    // Reference prompt hint + N/16384 counter.
    expect(main, contains('describe the set concept'));
    // Tuning as chip groups (the old dialog pickers are gone).
    expect(main, contains("'Variation strength'"));
    expect(main, contains("'Display target'"));
    expect(main, contains("'Colour boost'"));
    expect(main, contains('_chipGroup'));
    expect(main, isNot(contains('_tuningRow')));
    expect(main, isNot(contains('_miniDropdown')));
    // Reference button + Generate CTA survive the split.
    expect(main, contains("'Reference image (optional)'"));
    expect(main, contains("Text(_busy ? 'Working...' : 'Generate set')"));
  });

  test('v110: Animation counter matches the reference format', () async {
    final anim = await File('lib/animation_screen.dart').readAsString();
    expect(anim, contains('/16384'));
  });

  test('v110: Image-to-Prompt Options card uses the roomier padding',
      () async {
    final search = await File('lib/image_search.dart').readAsString();
    expect(search, contains('padding: const EdgeInsets.all(16)'));
  });
}
