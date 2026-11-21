// v120 markers: Animation section is Studio-clean — the prompt
// card holds just the prompt + Generate, Model/Style/Duration/
// switches live in their own Settings card, the Polish wand sits
// inside the field, and video cards are one compact row.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v120: prompt card + Settings card split', () {
    final anim =
        File('lib/animation_screen.dart').readAsStringSync();
    expect(anim, contains('Widget _settingsCard()'));
    expect(anim, contains("Text('Settings'"));
    expect(anim, contains('Icons.tune_outlined'));
    // The prompt card no longer carries the settings rows.
    final promptCard =
        anim.substring(0, anim.indexOf('Widget _settingsCard()'));
    expect(promptCard, isNot(contains('animModelPicker')));
    expect(promptCard, isNot(contains('animStylePicker')));
    expect(promptCard, isNot(contains('animTaskSwitch')));
    expect(promptCard, isNot(contains('animSeamlessSwitch')));
  });

  test('v120: Polish wand inside the field, video cards compact',
      () {
    final anim =
        File('lib/animation_screen.dart').readAsStringSync();
    expect(anim, contains("tooltip: 'Polish prompt'"));
    expect(anim, contains('Icons.auto_fix_high'));
    // The old Polish row + helper line are gone (the tooltip on the
    // wand keeps the words 'Polish prompt' — that is the icon, not
    // a button label).
    expect(anim,
        isNot(contains("label: Text(_polishing ? 'Polishing…' : 'Polish prompt')")));
    expect(anim, isNot(contains('Gemini prompt-ta sajiye debe')));
    // One compact row per video: no ListTile + action row.
    expect(anim, isNot(contains('ListTile(')));
    expect(anim, contains('Widget _animIconAction('));
    expect(anim, contains("key: ValueKey('animPlay-"));
    // The Queued account rides in the single spec line.
    expect(anim, contains("text: ' · Queued on \${v.uploadedAccount}'"));
  });
}
