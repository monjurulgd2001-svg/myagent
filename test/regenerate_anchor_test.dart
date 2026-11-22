// v79: regenerate must not re-download the anchor from its stored
// URL — Gemini's signed CDN URLs expire, so regenerating an older
// set 403d on every candidate form (his 2026-11-14 screenshot).
// The anchor already lives on disk as the set's first image, and a
// download failure must stay short enough to read in a dialog.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/gemini_api.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';
import 'package:http/http.dart' as http;

/// A CDN that refuses everything with Google's 403 error page.
class _Always403Client extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    const body = '<html><head><title>Error 403 (Forbidden)!!1</title></head>'
        '<body><style>*{margin:0;padding:0}html,code{font:15px/22px arial,sans-serif}</style></body></html>';
    final bytes = body.codeUnits;
    return http.StreamedResponse(Stream.value(bytes), 403,
        headers: {'content-type': 'text/html'});
  }
}

const _session = GeminiSession(
  authUser: 0,
  email: 'test@example.com',
  at: 'test-at',
  bl: '',
  fSid: '',
  cookieHeader: '',
  fetchedAtMs: 0,
);

SetEntry _entryWithFirstImage(String localPath) => SetEntry(
      id: 't1',
      prompt: 'test prompt',
      workflowMode: 'single',
      setTypeLabel: 'Single',
      setFolderName: 'set-01',
      anchorHdUrl:
          'https://lh3.googleusercontent.com/rd-gg-dl/expired-token=s0',
      createdAtIso: '2026-11-14T00:00:00',
      images: [
        SetImage(
          localPath: localPath,
          exactFilename: 'anchor.jpg',
          zipName: 'anchor.jpg',
          distSlot: '',
          role: '',
          label: 'Anchor',
          badge: '',
          slotIndex: 0,
          stageKey: 'anchor',
        ),
      ],
    );

void main() {
  test('fetchHdBlob failure stays short and names the 403', () async {
    final api = GeminiApi(client: _Always403Client());
    const issued =
        'https://lh3.googleusercontent.com/rd-gg-dl/abc123=s1024-rj';
    Object? caught;
    try {
      await api.fetchHdBlob(issued, _session);
    } catch (e) {
      caught = e;
    }
    expect(caught, isNotNull);
    final msg = caught.toString();
    expect(msg, contains('rd-gg-dl'));
    expect(msg, contains('403'));
    expect(msg, contains('meyad'));
    expect(msg.length, lessThan(400));
  });

  test('readLocalAnchorBytes prefers the file on disk', () async {
    final dir = await Directory.systemTemp.createTemp('anchor_test');
    try {
      final file = File('${dir.path}/anchor.jpg');
      await file.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);
      final bytes =
          await StudioEngine.readLocalAnchorBytes(_entryWithFirstImage(file.path));
      expect(bytes, isNotNull);
      expect(bytes!.length, 4);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('readLocalAnchorBytes returns null when the file is gone', () async {
    expect(
      await StudioEngine.readLocalAnchorBytes(
          _entryWithFirstImage('/nope/missing-anchor.jpg')),
      isNull,
    );
  });

  test('readLocalAnchorBytes returns null for an empty set', () async {
    final entry = SetEntry(
      id: 't2',
      prompt: 'test prompt',
      workflowMode: 'single',
      setTypeLabel: 'Single',
      setFolderName: 'set-02',
      createdAtIso: '2026-11-14T00:00:00',
      images: [],
    );
    expect(await StudioEngine.readLocalAnchorBytes(entry), isNull);
  });
}
