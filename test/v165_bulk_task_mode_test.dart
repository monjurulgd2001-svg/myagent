// v165 — bulk line 2+ driver Task-mode fix. Live 2026-11-23 00:13:
// a 2-line bulk run finished line 1, then line 2 failed
// "(task_mode) Task mode pelam na". The driver reuses one headless
// tab; on the finished task thread the composer shows a mode-picker
// dropdown ("Open mode picker, currently Gemini…") and NO exact
// "Task" pill, so the old one-shot pill lookup failed at once.
// The fix (content.js + windows_video_driver_script.dart, kept
// identical): pill, then the mode-picker menu, then a fresh chat
// ("New Chat" — each bulk line is its own task thread anyway) and
// one more try on the fresh composer. The task_mode error still
// names the actual picker contents in the button dump.
//
// Tested two ways (v152 pattern):
//  (A) marker assertions on both shipped scripts — always runs.
//  (B) behavioural: the Task-mode helper block is extracted from
//      each script and executed under Node against a fake DOM with
//      a virtual clock (all driver waits run instantly). Skipped
//      when Node is unavailable; the markers in (A) still run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _contentJs() => File(
        'android/app/src/main/assets/ais_cookies/content.js')
    .readAsStringSync();

String _windowsJs() {
  final src =
      File('lib/windows_video_driver_script.dart').readAsStringSync();
  final start = src.indexOf("r'''");
  if (start < 0) {
    fail('windows_video_driver_script.dart has no raw string');
  }
  final open = start + 4;
  final close = src.indexOf("'''", open);
  if (close < 0) {
    fail('windows_video_driver_script.dart raw string not closed');
  }
  return src.substring(open, close);
}

/// The Task-mode helper block: from `const norm` through the end
/// of `async function ensureTaskMode` (brace counting from its
/// opening brace). The block is self-contained except for `sleep`
/// and `document`, which the Node harness provides.
String _helperBlock(String src) {
  final start = src.indexOf('const norm = ');
  if (start < 0) fail('script has no norm helper');
  final fnStart = src.indexOf('async function ensureTaskMode()', start);
  if (fnStart < 0) fail('script has no ensureTaskMode');
  final open = src.indexOf('{', fnStart);
  var depth = 0;
  var i = open;
  while (i < src.length) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) {
        i++;
        break;
      }
    }
    i++;
  }
  if (depth != 0) fail('ensureTaskMode braces do not balance');
  return src.substring(start, i);
}

bool _hasNode() {
  try {
    final r = Process.runSync('which', ['node']);
    return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Node driver: fake DOM + virtual clock, then the scenario
/// matrix. [block] is the extracted helper block for one script.
String _nodeDriver(String block) => '''
// v165 Node harness: fake DOM + virtual clock (all driver waits
// run instantly — Date.now is patched, sleep advances it).
let now = 1000000;
Date.now = () => now;
const sleep = async (ms) => { now += ms; };

function makeEl(o) {
  const el = {
    textContent: o.text || '',
    className: o.cls || '',
    isConnected: true,
    _aria: o.aria || {},
    _ph: o.placeholder || '',
    _vis: o.visible !== false,
    _click: o.onClick || null,
    getAttribute(name) {
      if (name === 'placeholder') return this._ph;
      if (name === 'data-placeholder') return '';
      if (name === 'aria-label') return this._aria['aria-label'] || '';
      if (name === 'aria-pressed') return this._aria['aria-pressed'] || '';
      if (name === 'aria-selected') return this._aria['aria-selected'] || '';
      if (name === 'title') return this._aria['title'] || '';
      return '';
    },
    getBoundingClientRect() {
      return this._vis
        ? { width: 100, height: 30, top: 0, left: 0 }
        : { width: 0, height: 0, top: 0, left: 0 };
    },
    click() { if (this._click) this._click(); },
    contains(other) { return false; },
    closest() { return null; },
  };
  return el;
}

const page = { buttons: [], editors: [], options: [] };
const document = {
  querySelectorAll(sel) {
    if (sel.indexOf('contenteditable') >= 0) return page.editors;
    if (sel.indexOf('menuitem') >= 0) return page.options;
    return page.buttons;
  },
};
const clicks = { pill: 0, taskOption: 0, newChat: 0, picker: 0 };

function taskPill() {
  const pill = makeEl({ text: 'Task', aria: { 'aria-pressed': 'false' } });
  pill._click = () => { clicks.pill++; pill._aria['aria-pressed'] = 'true'; };
  return pill;
}
function modePicker(label, menuOptions) {
  let menuOpen = false;
  const picker = makeEl({ text: 'GeminiNeon', aria: { 'aria-label': 'Open mode picker, currently ' + label } });
  picker._click = () => {
    clicks.picker++;
    menuOpen = !menuOpen;
    page.options.forEach((o) => { o._vis = menuOpen; });
  };
  page.options = menuOptions.map((t) => {
    const opt = makeEl({ text: t, visible: false });
    opt._click = () => {
      if (t === 'Task') {
        clicks.taskOption++;
        picker._aria['aria-label'] = 'Open mode picker, currently Task';
        page.editors.forEach((e) => { e._ph = 'Describe a task'; });
      }
      menuOpen = false;
      page.options.forEach((o) => { o._vis = false; });
    };
    return opt;
  });
  return picker;
}
function newChatBtn() {
  const btn = makeEl({ text: 'New Chat' });
  btn._click = () => {
    clicks.newChat++;
    page.buttons = freshChatButtons();
    page.editors = [makeEl({ placeholder: 'Ask Gemini' })];
    page.options = [];
  };
  return btn;
}
function freshChatButtons() {
  return [
    makeEl({ text: 'Main menu' }),
    taskPill(),
    makeEl({ text: 'Neon', aria: { 'aria-label': 'Open model picker' } }),
    makeEl({ text: 'Upload & tools' }),
    makeEl({ text: 'Dictate (^⇧D)' }),
    newChatBtn(),
  ];
}
function finishedThreadButtons(pickerLabel, menuOptions) {
  return [
    makeEl({ text: 'Main menu' }),
    modePicker(pickerLabel, menuOptions),
    makeEl({ text: 'Expand' }),
    makeEl({ text: 'Copy prompt' }),
    makeEl({ text: 'Edit' }),
    makeEl({ text: 'Scroll to bottom' }),
    makeEl({ text: 'Upload & tools' }),
    makeEl({ text: 'Dictate (^⇧D)' }),
    newChatBtn(),
    makeEl({ text: 'Complete' }),
    makeEl({ text: 'Open menu for conversation actions' }),
  ];
}
function reset(buttons, editorPh) {
  page.buttons = buttons;
  page.editors = [makeEl({ placeholder: editorPh })];
  clicks.pill = 0; clicks.taskOption = 0; clicks.newChat = 0; clicks.picker = 0;
  now = 1000000;
}
function check(cond, msg) { if (!cond) throw new Error(msg); }

$block

async function main() {
  // A: fresh chat — the pill path (regression pin for v90).
  reset(freshChatButtons(), 'Ask Gemini');
  check(await ensureTaskMode() === true, 'A: fresh chat must enter Task mode');
  check(clicks.pill === 1, 'A: Task pill must be clicked once');
  check(clicks.newChat === 0, 'A: New Chat must not be used');

  // B: the live failure — finished task thread, Task via the mode
  // picker (buttons copied from the user's 2026-11-23 dump).
  reset(finishedThreadButtons('Gemini', ['Chat', 'Task']), 'Ask Gemini');
  check(await ensureTaskMode() === true, 'B: finished thread must enter Task mode via picker');
  check(clicks.taskOption === 1, 'B: Task option must be picked from the menu');
  check(clicks.newChat === 0, 'B: New Chat must not be needed when the picker has Task');

  // C: picker has no Task — New Chat escape, then the fresh pill.
  reset(finishedThreadButtons('Gemini', ['Chat', 'Gemini']), 'Ask Gemini');
  check(await ensureTaskMode() === true, 'C: no Task in picker must fall through to New Chat');
  check(clicks.newChat === 1, 'C: New Chat must be clicked once');
  check(clicks.pill === 1, 'C: fresh-chat Task pill must be clicked');

  // D: genuinely nothing — no pill, no picker, no New Chat.
  page.buttons = [makeEl({ text: 'Main menu' }), makeEl({ text: 'Upload & tools' }), makeEl({ text: 'Dictate (^⇧D)' })];
  page.editors = [makeEl({ placeholder: 'Ask Gemini' })];
  page.options = [];
  clicks.pill = 0; clicks.taskOption = 0; clicks.newChat = 0; clicks.picker = 0;
  now = 1000000;
  check(await ensureTaskMode() === false, 'D: no pill, no picker, no New Chat must return false');

  // E: already in Task mode via the picker label — no clicks.
  reset(finishedThreadButtons('Task', ['Chat', 'Task']), 'Describe a task');
  check(await ensureTaskMode() === true, 'E: picker already on Task must return true');
  check(clicks.pill === 0 && clicks.picker === 0 && clicks.newChat === 0, 'E: nothing must be clicked when already in Task mode');

  console.log('ALL V165 JS CHECKS PASSED');
}
main().catch((e) => { console.error('FAIL: ' + (e && e.message || e)); process.exit(1); });
''';

void main() {
  final android = _contentJs();
  final windows = _windowsJs();

  group('v165 markers in both driver scripts', () {
    test('picker + fresh-chat paths are present', () {
      for (final js in [android, windows]) {
        expect(js, contains('pickTaskFromModePicker'));
        expect(js, contains('ensureTaskModeOnce'));
        expect(js, contains("findBtn(['New Chat'])"));
        expect(js, contains("findBtn(['mode picker'])"));
        expect(js, contains(r'currently\s+task'));
      }
    });

    test('old one-shot pill lookup is gone', () {
      for (final js in [android, windows]) {
        expect(js, isNot(contains('if (!pill) return false;')));
      }
    });

    test('task_mode error path is intact (still names the dump)', () {
      for (final js in [android, windows]) {
        expect(js, contains('__notask__'));
        expect(
            js,
            contains(
                'Task mode pelam na — Task mode chara animation hobe na.'));
        expect(js, contains('dumpButtons()'));
      }
    });

    test('no Chat fallback reintroduced', () {
      // onJob still throws __notask__ when Task mode cannot be
      // entered; the error is never swallowed into a chat send.
      for (final js in [android, windows]) {
        expect(js, contains("if (!inTask) throw new Error('__notask__');"));
      }
    });

    test('helper blocks are identical across the two scripts', () {
      expect(_helperBlock(android), _helperBlock(windows));
    });
  });

  group('v165 Task-mode logic under Node',
      skip: _hasNode() ? null : 'node not available', () {
    test('scenario matrix on content.js', () async {
      final driver = _nodeDriver(_helperBlock(android));
      final tmp =
          await Directory.systemTemp.createTemp('v165-task-mode-');
      try {
        final file = File('${tmp.path}/v165_driver.js');
        await file.writeAsString(driver);
        final r = await Process.run('node', [file.path]);
        expect(r.exitCode, 0,
            reason: 'node driver failed:\n${r.stdout}\n${r.stderr}');
        expect(r.stdout as String,
            contains('ALL V165 JS CHECKS PASSED'));
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });

    test('scenario matrix on windows_video_driver_script.dart',
        () async {
      final driver = _nodeDriver(_helperBlock(windows));
      final tmp =
          await Directory.systemTemp.createTemp('v165-task-mode-');
      try {
        final file = File('${tmp.path}/v165_driver_win.js');
        await file.writeAsString(driver);
        final r = await Process.run('node', [file.path]);
        expect(r.exitCode, 0,
            reason: 'node driver failed:\n${r.stdout}\n${r.stderr}');
        expect(r.stdout as String,
            contains('ALL V165 JS CHECKS PASSED'));
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });
}
