// v112 — reference Batch Sets cards (his 2026-11-21 screenshots):
// the Set type card sits on top ("set type upore hobe"), the
// prompt input is the numbered Prompts card (Add prompt / Paste
// list / From images / Clear all). The prompt list is a real
// row model — one row = one prompt = one set — and two or more
// non-empty rows IS batch mode (the Batch switch is gone).
// Mode chips keep OUR labels/order (v38); the Set type info
// paragraph is written from OUR engine's rules (v81).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v112: Set type card on top, Prompts card below it', () async {
    final main = await File('lib/main.dart').readAsString();
    // Set type card: header + chips (v113: the info paragraph
    // under the chips is hidden on his order).
    expect(main,
        contains("_sectionHeader(Icons.layers_outlined, 'Set type')"));
    expect(main, isNot(contains('_modeInfo()')));
    expect(main, isNot(contains('A neutral anchor image is generated first')));
    // Prompts card: header + numbered rows + the four buttons.
    expect(main,
        contains("_sectionHeader(Icons.format_list_bulleted, 'Prompts')"));
    expect(main, contains('describe the set concept'));
    expect(main, contains("const Text('Add prompt')"));
    expect(main, contains("const Text('Paste list')"));
    expect(main, contains("const Text('From images')"));
    expect(main, contains("const Text('Clear all')"));
    // Order: Set type comes before Prompts in the designer.
    final setType =
        main.indexOf("_sectionHeader(Icons.layers_outlined, 'Set type')");
    final prompts = main.indexOf(
        "_sectionHeader(Icons.format_list_bulleted, 'Prompts')");
    expect(setType, lessThan(prompts));
  });

  test('v112: prompt rows are a real list, batch is derived', () async {
    final main = await File('lib/main.dart').readAsString();
    expect(main, contains('final List<TextEditingController> _promptCtrls'));
    expect(main, contains('List<String> get _promptTexts'));
    expect(main, contains('bool get _batchMode => _promptTexts.length > 1'));
    expect(main, contains('Widget _promptRow(int i)'));
    expect(main, contains("tooltip: 'Remove prompt'"));
    expect(main, contains('Future<void> _pastePromptList()'));
    expect(main, contains('void _clearAllPrompts()'));
    // The single-field model and the Batch switch are gone.
    expect(main, isNot(contains('final TextEditingController _promptCtrl')));
    expect(main, isNot(contains('bool _batchMode = false')));
    expect(main, isNot(contains("const ValueKey('batchSwitch')")));
    expect(main, isNot(contains("'Prompts (1 line = 1 set)'")));
  });
}
