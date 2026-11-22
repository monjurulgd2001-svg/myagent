// v109 — reference-layout redesign (his 2026-11-20 screenshots of
// the MH-style layout): the picked mode chip shows a check, the
// Generate buttons are solid primary 56px tall, prompt fields show
// a live character count, and cards use the roomier 16px padding.
// Features are unchanged — only the layout language moved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v109: Studio follows the reference layout', () async {
    final main = await File('lib/main.dart').readAsString();
    // Picked mode chip shows a check (reference set-type chips).
    expect(main, contains('selected ? Icons.check : icon'));
    // Solid primary Generate CTA, 56px tall (gradient gone).
    expect(main, contains("Text(_busy ? 'Working...' : 'Generate set')"));
    expect(main, contains('minimumSize: const Size.fromHeight(56)'));
    expect(main, isNot(contains('kAccentGradient')));
    // Live character count under the prompt field.
    expect(main, contains("'\$_totalPromptChars/16384'"));
    // Roomier designer card padding.
    expect(main, contains('padding: const EdgeInsets.all(16)'));
  });

  test('v109: Animation card follows the reference layout', () async {
    final anim =
        await File('lib/animation_screen.dart').readAsString();
    expect(anim, contains('BorderRadius.circular(20)'));
    expect(anim, contains("'\${_promptCtrl.text.length}/16384'"));
    // v163 — the label is dynamic now (one line = 'Generate
    // animation', several lines = 'Generate N animations'), but
    // the single-line label and the 56px button are unchanged.
    expect(anim, contains("'Generate animation'"));
    expect(anim, contains("'Generate \${bulkLines.length} animations'"));
    expect(anim, contains('minimumSize: const Size.fromHeight(56)'));
  });

  test('v109: Image-to-Prompt cards use the roomier padding', () async {
    final search = await File('lib/image_search.dart').readAsString();
    expect(search, contains('padding: const EdgeInsets.all(16)'));
  });
}
