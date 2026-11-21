// v114 markers: the Set type chips sit in exactly TWO fixed rows
// (his order "Set type gula 2 line a gap kome diye sundor kore
// raka jaito"), each chip Expanded, gaps tightened to 6 — a Wrap
// flowed to 3+ rows on his phone. The chip itself is slimmer
// (12px label, 16px avatar) and the label scales down instead of
// overflowing on narrow screens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v114: Set type chips in two fixed Expanded rows, tight gaps',
      () async {
    final main =
        await File('lib/main.dart').readAsString();
    // Two rows, not a Wrap: row 1 = single-image modes, row 2 =
    // set modes, labels/order unchanged (v38).
    expect(main, contains("Expanded(\n                      child: _modeChip('dual_single', '9:16 + Foldable',"));
    expect(main, contains("Expanded(\n                      child: _modeChip('single', 'Single 9:16',"));
    expect(main, contains("Expanded(\n                      child: _modeChip('set_dual', 'Dual Set (2)',"));
    expect(main, contains("Expanded(\n                      child: _modeChip('set_24h', '24-Hour Set (4)',"));
    expect(main, contains("Expanded(\n                      child: _modeChip('set_battery', 'Battery Set (6)',"));
    // Tight gaps: 6px between chips and between the two rows.
    expect(main, contains('const SizedBox(width: 6)'));
    expect(main, contains('const SizedBox(height: 6)'));
  });

  test('v114: chip slimmer, label scales down instead of overflowing',
      () async {
    final main =
        await File('lib/main.dart').readAsString();
    expect(main, contains('fontSize: 12,'));
    expect(main, contains('size: 16,'));
    expect(main, contains('FittedBox('));
    expect(main, contains('fit: BoxFit.scaleDown,'));
    // v139 — the chip is a fixed 36px tall box with 6px side
    // padding (was a padded 8/6 chip).
    expect(main, contains('height: 36,'));
    expect(main,
        contains('padding: const EdgeInsets.symmetric(horizontal: 6),'));
  });
}
