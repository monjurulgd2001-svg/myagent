// v119 markers: Paste list opens a paste box when the clipboard
// read comes back empty (or throws), instead of a dead-end message.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v119: paste-box fallback exists in main.dart', () {
    final main =
        File('lib/main.dart').readAsStringSync();
    expect(main, contains('Future<void> _showPasteListDialog()'));
    expect(main, contains("const Text('Paste prompts')"));
    expect(main, contains("const Text('Add prompts')"));
    expect(main, contains('class _PasteListDialog extends StatefulWidget'));
    expect(main, contains('class _PasteListDialogState'));
    // The dead-end message is gone: an empty read now opens the box.
    expect(main, isNot(contains('Clipboard has no prompt list to paste.')));
    // The clipboard read is guarded — a throw must not kill the tap.
    expect(main, contains('catch (_)'));
  });
}
