// v153 — Windows animation driver (headless Chrome over CDP).
//
// The driver script is the Android content.js video driver
// (v86–v152) with ONLY its transport changed: the extension port
// is gone, events go into window.__ghsVideoOutbox and the app
// polls window.__ghsVideoTake(). The logic must therefore stay
// identical to Android's — these tests prove it three ways:
//  (A) marker assertions on the shipped script (transport swapped,
//      logic present, no extension calls left);
//  (B) Dart parsing: the outbox JSON the page produces becomes the
//      engine's video_* requests (incl. malformed payloads);
//  (C) behavioural: the pure `videoWaitDecision` + `chipStem`
//      functions are extracted from the shipped script and executed
//      under Node with a scenario matrix (same approach as the
//      v152 test on content.js). Skipped when Node is unavailable;
//      the markers in (A) still run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/windows_video_driver.dart';

/// The JS inside lib/windows_video_driver_script.dart (the Dart
/// header comment above it is prose, not driver code).
String _driverJs() {
  final src =
      File('lib/windows_video_driver_script.dart').readAsStringSync();
  final start = src.indexOf("r'''");
  if (start < 0) fail('windows_video_driver_script.dart has no raw string');
  final open = start + 4;
  final close = src.indexOf("'''", open);
  if (close < 0) fail('windows_video_driver_script.dart raw string not closed');
  return src.substring(open, close);
}

String _contentJs() =>
    File('android/app/src/main/assets/ais_cookies/content.js')
        .readAsStringSync();

/// Extract a `const <name> = ...;` top-level function source from
/// [src] by brace counting from the first `{` after `=>`.
String _extractFn(String src, String name) {
  final start = src.indexOf('const $name');
  if (start < 0) fail('script has no const $name');
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
    return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

void main() {
  final js = _driverJs();
  final android = _contentJs();

  group('v153 markers in windows_video_driver_script.dart', () {
    test('transport swapped: outbox + take + start + cancel', () {
      expect(js, contains('__ghsVideoTake'));
      expect(js, contains('__ghsVideoStart'));
      expect(js, contains('__ghsVideoCancel'));
      expect(js, contains('const outbox = []'));
      // __ghsVideoStart reports back so the Dart side knows the
      // job actually started (an arrow returning undefined would
      // read as "never started").
      expect(js, contains("return 'ok'"));
    });

    test('no extension transport left in the driver JS', () {
      expect(js, isNot(contains('browser.runtime')));
      expect(js, isNot(contains('port.postMessage')));
      expect(js, isNot(contains('port.onMessage')));
      expect(js, isNot(contains('port.onDisconnect')));
      expect(js, isNot(contains('backendFetch(')));
      expect(js, isNot(contains('sessionPage(')));
    });

    test('v152 wait + chip logic present', () {
      expect(js, contains('const videoWaitDecision'));
      expect(js, contains('IDLE_LIMIT'));
      expect(js, contains('chipStem'));
      expect(js, contains('findTruncatedMp4Chip'));
      expect(js, contains('ensureModel'));
      expect(js, contains('ensureTaskMode'));
    });
  });

  group('v153 driver logic is byte-identical to Android', () {
    test('videoWaitDecision + onJob + ensureModel match content.js', () {
      for (final name in ['videoWaitDecision', 'chipStem']) {
        expect(_extractFn(js, name), _extractFn(android, name));
      }
      String fn2(String src, String sig) {
        final i = src.indexOf(sig);
        final o = src.indexOf('{', i);
        var d = 0;
        var j = o;
        while (j < src.length) {
          if (src[j] == '{') d++;
          if (src[j] == '}') {
            d--;
            if (d == 0) return src.substring(i, j + 1);
          }
          j++;
        }
        fail('no $sig');
      }

      expect(fn2(js, 'async function onJob(m)'),
          fn2(android, 'async function onJob(m)'));
      expect(fn2(js, 'async function ensureModel(modelId)'),
          fn2(android, 'async function ensureModel(modelId)'));
    });
  });

  group('v153 parseOutbox (Dart side)', () {
    test('video_progress / video_ready / video_error round-trip', () {
      const take = '{"q": ['
          '"{\\"action\\":\\"video_progress\\",\\"data\\":{\\"phase\\":\\"creating\\",\\"jobId\\":\\"j1\\",\\"message\\":\\"Video banacche\\"}}", '
          '"{\\"action\\":\\"video_ready\\",\\"data\\":{\\"jobId\\":\\"j1\\",\\"url\\":\\"https://example.invalid/v.mp4\\",\\"durationSec\\":10,\\"width\\":1620,\\"height\\":2880}}", '
          '"{\\"action\\":\\"video_error\\",\\"data\\":{\\"jobId\\":\\"j1\\",\\"step\\":\\"typing\\",\\"message\\":\\"Prompt box-e lekha bosheni\\"}}"'
          ']}';
      final reqs = WindowsVideoDriver.parseOutbox(take);
      expect(reqs.map((r) => r.action),
          ['video_progress', 'video_ready', 'video_error']);
      expect(reqs[0].data['phase'], 'creating');
      expect(reqs[1].data['url'], 'https://example.invalid/v.mp4');
      expect(reqs[1].data['durationSec'], 10);
      expect(reqs[2].data['step'], 'typing');
      // All three carry the job id, so the engine can match them
      // to the running job (and ignore late ones).
      expect(reqs.every((r) => r.data['jobId'] == 'j1'), isTrue);
    });

    test('malformed / empty outbox yields nothing, never throws', () {
      expect(WindowsVideoDriver.parseOutbox(null), isEmpty);
      expect(WindowsVideoDriver.parseOutbox(''), isEmpty);
      expect(WindowsVideoDriver.parseOutbox('{"q":[]}'), isEmpty);
      expect(WindowsVideoDriver.parseOutbox('not json'), isEmpty);
      expect(WindowsVideoDriver.parseOutbox('{"q": ["{bad json"]}'),
          isEmpty);
    });

    test('non-video actions still parse (engine ignores them)', () {
      final reqs = WindowsVideoDriver.parseOutbox(
          '{"q": ["{\\"action\\":\\"single\\",\\"images\\":[]}"]}');
      expect(reqs, hasLength(1));
      expect(reqs.first.action, 'single');
    });
  });

  group('v153 parseCookieHeader (login seeding)', () {
    test('splits name=value pairs, keeps = inside values', () {
      final cs = WindowsVideoDriver.parseCookieHeader(
          '__Secure-1PSID=abc123; __Secure-1PSIDTS=sidts; NID=xyz==');
      expect(cs.map((c) => c.name),
          ['__Secure-1PSID', '__Secure-1PSIDTS', 'NID']);
      expect(cs[2].value, 'xyz==');
    });

    test('skips empty / valueless parts', () {
      expect(
          WindowsVideoDriver.parseCookieHeader('  ; foo; bar=; a=b '),
          hasLength(1));
    });
  });

  group('v153 videoWaitDecision under Node (shipped script)', () {
    test('idle limit + truncated chip stem behave like Android', () {
      if (!_hasNode()) {
        // ignore: avoid_print
        print('Node not available — skipping behavioural check.');
        return;
      }
      final fn = '${_extractFn(js, 'videoWaitDecision')}\n'
          '${_extractFn(js, 'chipStem')}';
      final probe = '''
$fn
const assert = require('assert');
const base = { stopPresent: false, stepPresent: false, pageChanged: false, idlePolls: 0, idleLimit: 4, followUps: 0, hasNewImage: false };
// Stop visible, steps visible, or the page changing all mean wait.
assert.strictEqual(videoWaitDecision({...base, stopPresent: true}), 'wait');
assert.strictEqual(videoWaitDecision({...base, stepPresent: true}), 'wait');
assert.strictEqual(videoWaitDecision({...base, pageChanged: true}), 'wait');
// Fewer than 4 idle polls: still wait (the v152 fix — the old
// code failed on the FIRST such poll).
assert.strictEqual(videoWaitDecision({...base, idlePolls: 3}), 'wait');
// 4 idle polls and nothing new: over.
assert.strictEqual(videoWaitDecision({...base, idlePolls: 4}), 'fail');
// 4 idle polls but a new keyframe image appeared: follow up.
assert.strictEqual(videoWaitDecision({...base, idlePolls: 4, hasNewImage: true}), 'followup');
// A truncated chip card yields its stem for the new-video check.
const card = { textContent: 'fire_magnetic_… MP4 Open' };
assert.strictEqual(chipStem(card), 'fire_magnetic_');
console.log('NODE_BEHAVIOUR_OK');
''';
      final f = File('/tmp/v153_wait_probe.js')..writeAsStringSync(probe);
      final r = Process.runSync('node', [f.path]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout.toString(), contains('NODE_BEHAVIOUR_OK'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
