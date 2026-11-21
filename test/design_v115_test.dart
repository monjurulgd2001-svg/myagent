// v115 markers: the Polish control is a wand icon INSIDE the
// focused prompt row (his order "Polish prompts ta prompts box a
// vitore raka jaito sudu icon") — the old button below the grid
// is gone, and only the listening indicator remains there.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v115: Polish wand icon lives in the focused prompt row',
      () async {
    final main = await File('lib/main.dart').readAsString();
    expect(main, contains("tooltip: 'Polish prompts'"));
    expect(main, contains('Icons.auto_fix_high'));
    expect(main, contains('if (i == _focusedPromptIndex)'));
    // The wand polishes every filled row, like the old button.
    expect(main, contains('onPressed: (_busy || _polishing)'));
    // No Polish button text anywhere in the designer.
    expect(main, isNot(contains("'Polish prompt'")));
    expect(main, isNot(contains('AI rewrites your idea')));
  });

  test('v115: suffix icons are compact so three fit in the field',
      () async {
    final main = await File('lib/main.dart').readAsString();
    expect(main, contains('minWidth: 36, minHeight: 36'));
    expect(main, contains('padding: const EdgeInsets.all(8)'));
    // A spinner replaces the wand while polishing.
    expect(main, contains('CircularProgressIndicator('));
  });
}
