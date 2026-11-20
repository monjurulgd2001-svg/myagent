// Ready ZIP (v74): buildReadyZip packs a set's images, the
// per-set prompt text and metadata.json into a valid ZIP file.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/models.dart';
import 'package:gemini_hd_studio/studio_engine.dart';

void main() {
  test('buildReadyZip packs images, prompts and metadata', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = await Directory.systemTemp.createTemp('ready-zip-');
    addTearDown(() => tmp.delete(recursive: true));
    // path_provider has no host implementation — point the
    // documents dir at the temp folder.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tmp.path;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final img1 = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3, 4]);
    final img2 = File('${tmp.path}/b.jpg')..writeAsBytesSync([5, 6, 7, 8]);
    SetImage shot(String path, String name, String stage) => SetImage(
          localPath: path,
          exactFilename: name,
          zipName: name,
          distSlot: '',
          role: '',
          label: '',
          badge: '',
          slotIndex: 0,
          stageKey: '',
          stagePrompt: stage,
        );
    final entry = SetEntry(
      id: 's1',
      prompt: 'frozen glass dunes',
      workflowMode: 'set_dual',
      setTypeLabel: 'Dual Set (2)',
      setFolderName: 'frozen-glass-dunes',
      createdAtIso: '2026-11-13',
      metadata: SetMetadata(
        file: 'set-01/image.jpg',
        title: 'Frozen Glass Dunes',
        tags: ['frozen', 'glass'],
        category: 'Nature',
        description: 'Icy blue dunes',
      ),
      images: [
        shot(img1.path, 'frozen-glass-dunes-1.jpg', 'stage one'),
        shot(img2.path, 'frozen-glass-dunes-2.jpg', 'stage two'),
      ],
    );
    final zipFile = await StudioEngine().buildReadyZip([entry]);
    expect(await zipFile.exists(), isTrue);
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.map((f) => f.name).toList();
    expect(names, contains('set-01/frozen-glass-dunes-1.jpg'));
    expect(names, contains('set-01/frozen-glass-dunes-2.jpg'));
    expect(names, contains('prompts/set-01-wallpaper.txt'));
    expect(names, contains('metadata.json'));
    final meta = jsonDecode(
      utf8.decode(archive.files
          .firstWhere((f) => f.name == 'metadata.json')
          .content as List<int>),
    ) as List;
    expect(meta.length, 1);
    expect(meta.first['title'], 'Frozen Glass Dunes');
    expect(meta.first['tags'], ['frozen', 'glass']);
  });
}
