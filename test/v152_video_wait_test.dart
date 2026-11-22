// v152 — driver waits while Gemini renders; truncated MP4 chip
// detection. Live 2026-11-22 12:35–12:37: the driver typed the
// prompt, Gemini rendered the 10s MP4 ("fire_magnetic_…" card),
// but the app failed at step `creating` — the wait loop broke on
// the FIRST poll with no "Stop response" while the page showed
// "2/3 steps", ~2 min before the MP4 rendered; and the chip
// detector needed a visible ".mp4", which a truncated name lacks.
//
// The wait decision lives in content.js (JS, no Dart equivalent),
// so this file tests it two ways:
//  (A) marker assertions on the shipped content.js — the fix is
//      present and the old bare break is gone; always runs.
//  (B) behavioural: the pure `videoWaitDecision` + `chipStem`
//      functions are extracted from the shipped file and executed
//      under Node with a scenario matrix. Skipped when Node is not
//      available (CI runners ship it); the markers in (A) still run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _contentJs() {
  final f = File(
      'android/app/src/main/assets/ais_cookies/content.js');
  if (!f.existsSync()) {
    fail('content.js not found at ${f.path} — run flutter test from '
        'the package root.');
  }
  return f.readAsStringSync();
}

/// Extract a `const <name> = ...;` top-level function source from
/// [src] by brace counting from the first `{` after `=>`.
String _extractFn(String src, String name) {
  final start = src.indexOf('const $name');
  if (start < 0) fail('content.js has no const $name');
  final arrow = src.indexOf('=>', start);
  final open = src.indexOf('{', arrow);
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
  return '${src.substring(start, i)};';
}

bool _hasNode() {
  try {
    final r = Process.runSync('which', ['node']);
    return r.exitCode == 0 &&
        (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

void main() {
  final js = _contentJs();

  group('v152 markers in content.js', () {
    test('wait decision is a pure function with an idle limit', () {
      expect(js, contains('const videoWaitDecision'));
      expect(js, contains('IDLE_LIMIT'));
      expect(js, contains('idlePolls'));
      expect(js, contains('STEP_RE'));
      // "2/3 steps" / "Step 2 of 3" both count as still rendering.
      expect(js, contains('steps?'));
    });

    test('old break on first Stop-absence is gone', () {
      expect(
          js,
          isNot(contains(
              'else if (sawStop || Date.now() >= deadline)')));
    });

    test('outer bound kept: the wait can never run forever', () {
      expect(js, contains('videoWaitMs'));
      expect(js, contains('hardDeadline'));
      expect(js, contains('while (Date.now() < hardDeadline'));
    });

    test('truncated MP4 chip detection is present', () {
      expect(js, contains('findTruncatedMp4Chip'));
      expect(js, contains('chipStem'));
      expect(js, contains('seenChipStems'));
      expect(js, contains('isMp4Label'));
    });

    test('full-name .mp4 path is intact', () {
      expect(js, contains('const mp4Name'));
      expect(js, contains('findMp4Chip'));
      expect(js, contains('seenChipNames'));
    });
  });

  group('v152 wait logic under Node', skip: _hasNode() ? null : 'node not available', () {
    test('decision matrix + chip stems', () async {
      final decision = _extractFn(js, 'videoWaitDecision');
      final stem = _extractFn(js, 'chipStem');
      final driver = '$decision\n$stem\n'
          r'''
const cases = [
  ['first Stop-absence, step 2/3 present', {stopPresent:false, stepPresent:true, pageChanged:false, idlePolls:0, idleLimit:4, followUps:0, hasNewImage:false}, 'wait'],
  ['Stop-absence, page changed', {stopPresent:false, stepPresent:false, pageChanged:true, idlePolls:2, idleLimit:4, followUps:0, hasNewImage:false}, 'wait'],
  ['Stop present', {stopPresent:true, stepPresent:false, pageChanged:false, idlePolls:0, idleLimit:4, followUps:0, hasNewImage:false}, 'wait'],
  ['3 idle polls', {stopPresent:false, stepPresent:false, pageChanged:false, idlePolls:3, idleLimit:4, followUps:0, hasNewImage:false}, 'wait'],
  ['4 idle polls, no image', {stopPresent:false, stepPresent:false, pageChanged:false, idlePolls:4, idleLimit:4, followUps:0, hasNewImage:false}, 'fail'],
  ['4 idle polls, new image, followUps 0', {stopPresent:false, stepPresent:false, pageChanged:false, idlePolls:4, idleLimit:4, followUps:0, hasNewImage:true}, 'followup'],
  ['4 idle polls, new image, followUps 2', {stopPresent:false, stepPresent:false, pageChanged:false, idlePolls:4, idleLimit:4, followUps:2, hasNewImage:true}, 'fail'],
  ['4 idle polls, step present', {stopPresent:false, stepPresent:true, pageChanged:false, idlePolls:4, idleLimit:4, followUps:0, hasNewImage:false}, 'wait'],
];
let bad = 0;
for (const [name, input, want] of cases) {
  const got = videoWaitDecision(input);
  if (got !== want) { console.log('FAIL decision ' + name + ': got ' + got + ', want ' + want); bad++; }
}
const fake = (t) => ({ textContent: t });
const stemCases = [
  ['fire_magnetic_… MP4 Open', 'fire_magnetic_'],
  ['fire_magnetic_charging.mp4 MP4 Open', 'fire_magnetic_charging.mp4'],
  ['MP4', ''],
];
for (const [text, want] of stemCases) {
  const got = chipStem(fake(text));
  if (got !== want) { console.log('FAIL stem ' + JSON.stringify(text) + ': got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); bad++; }
}
if (bad) { console.log(bad + ' v152 JS checks failed'); process.exit(1); }
console.log('ALL V152 JS CHECKS PASSED');
''';
      final tmp = await Directory.systemTemp
          .createTemp('v152-wait-');
      try {
        final file = File('${tmp.path}/v152_driver.js');
        await file.writeAsString(driver);
        final r = await Process.run('node', [file.path]);
        expect(r.exitCode, 0,
            reason: 'node driver failed:\n${r.stdout}\n${r.stderr}');
        expect(r.stdout as String, contains('ALL V152 JS CHECKS PASSED'));
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });
}
