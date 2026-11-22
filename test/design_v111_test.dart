// v111 — reference top chrome (his 2026-11-20 "Same design to
// hoyni design same koro"): the Studio screen is the reference's
// main screen — logo + four icons only (no title/subtitle/version
// text, no account strip), the Text / Image toggle standing alone
// under the top bar, the set-type chips inside the Model & Size
// card, and the Prompt field showing the placeholder instead of
// a label. All OUR functions stay: Import, Panel settings, theme
// toggle, and the account actions (Scan / Add Gmail / Verify /
// Switch account) behind the gear icon; the version shows on
// Login and in the gear menu. Nothing is faked (no model /
// resolution / format / aspect-ratio controls — fixed Gemini web,
// 9:16, 1620x2880 JPG by the Zedge spec; no seed).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v111: app bar is logo + icons, no title or strip', () async {
    final main = await File('lib/main.dart').readAsString();
    // No title column, no version text, no strip in the bar.
    expect(main, isNot(contains("Text('Zedge Studio'")));
    expect(main, isNot(contains("Text('Wallpaper Set Designer'")));
    // (The version Text lives in the gear menu — asserted below —
    // so it must NOT be asserted absent from the whole file.)
    expect(main, isNot(contains('Version 2.5.45')));
    expect(main, isNot(contains('_accountStrip')));
    // The four function icons are there.
    expect(main, contains("'Import local set'"));
    expect(main, contains("'Panel upload settings'"));
    expect(main, contains("const ValueKey('themeToggle')"));
    expect(main, contains("Icons.settings_outlined"));
    // Account actions + version live in the gear menu.
    expect(main, contains("'Switch account'"));
    expect(main, contains("Text('Version 2.5.99'"));
    expect(main, contains('_sessionLabel'));
  });

  test('v111: toggle stands alone, Set type in Model & Size', () async {
    final main = await File('lib/main.dart').readAsString();
    expect(main, contains('_imgModeToggle()'));
    expect(main, isNot(contains("const Text('Set Designer'")));
    expect(main, isNot(contains('JPG · ≤8MB')));
    expect(main, contains("'Set type'"));
    expect(main, contains("_modeChip('dual_single'"));
    expect(main, contains("_modeChip('set_battery'"));
    // Prompt rows: numbered hints, no label (v112).
    expect(main, contains('describe the set concept'));
    expect(main, isNot(contains(": 'Prompt',")));
  });
}
