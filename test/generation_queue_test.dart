// Overnight queue (v47): persistence round-trip and the
// running->pending reset that lets an interrupted overnight run
// resume after the app or phone restarts.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/generation_queue.dart';

void main() {
  test('queue item survives a JSON round-trip with every field', () {
    final item = QueueItem(
      id: 'abc-0',
      prompt: 'a marble fox under aurora light',
      negativePrompt: 'no text',
      workflowMode: 'set_24h',
      customStages: ['dawn', null, 'dusk', null],
      storyArc: 'light',
      variationStrength: 'bold',
      displayTarget: 'amoled',
      colorBoost: 'vivid',
      aiDirectorEnabled: true,
      autoWriteMetadata: false,
      includeFoldableCompanion: true,
      landscapePrompt: 'wide please',
      forceImagePrefix: false,
      upscaleEnabled: false,
      useExactZedgeNames: false,
      subfolder: 'MySets',
      portraitWidth: 1440,
      portraitHeight: 2560,
      landscapeWidth: 2000,
      landscapeHeight: 1800,
      status: 'failed',
      error: 'boom',
      createdAtMs: 12345,
    );
    final back = QueueItem.fromJson(item.toJson());
    expect(back.id, item.id);
    expect(back.prompt, item.prompt);
    expect(back.negativePrompt, item.negativePrompt);
    expect(back.workflowMode, item.workflowMode);
    expect(back.customStages, item.customStages);
    expect(back.storyArc, item.storyArc);
    expect(back.variationStrength, item.variationStrength);
    expect(back.displayTarget, item.displayTarget);
    expect(back.colorBoost, item.colorBoost);
    expect(back.aiDirectorEnabled, item.aiDirectorEnabled);
    expect(back.autoWriteMetadata, item.autoWriteMetadata);
    expect(back.includeFoldableCompanion, item.includeFoldableCompanion);
    expect(back.landscapePrompt, item.landscapePrompt);
    expect(back.forceImagePrefix, item.forceImagePrefix);
    expect(back.upscaleEnabled, item.upscaleEnabled);
    expect(back.useExactZedgeNames, item.useExactZedgeNames);
    expect(back.subfolder, item.subfolder);
    expect(back.portraitWidth, item.portraitWidth);
    expect(back.portraitHeight, item.portraitHeight);
    expect(back.landscapeWidth, item.landscapeWidth);
    expect(back.landscapeHeight, item.landscapeHeight);
    expect(back.status, item.status);
    expect(back.error, item.error);
    expect(back.createdAtMs, item.createdAtMs);
  });

  test('a list encodes and decodes; a stuck running item resets to pending',
      () {
    final raw = QueueItem.encodeList([
      QueueItem(id: '1', prompt: 'one', workflowMode: 'single'),
      QueueItem(
          id: '2',
          prompt: 'two',
          workflowMode: 'set_battery',
          status: 'running'),
      QueueItem(
          id: '3', prompt: 'three', workflowMode: 'set_dual', status: 'done'),
    ]);
    final back = QueueItem.decodeList(raw);
    expect(back.length, 3);
    expect(back[0].status, 'pending');
    expect(back[1].status, 'pending',
        reason: 'the process died mid-run, so the item must be resumable');
    expect(back[2].status, 'done');
  });

  test('corrupt or missing storage decodes to an empty queue', () {
    expect(QueueItem.decodeList(null), isEmpty);
    expect(QueueItem.decodeList(''), isEmpty);
    expect(QueueItem.decodeList('not json'), isEmpty);
    expect(QueueItem.decodeList('{"a":1}'), isEmpty);
  });

  test('mode labels match the designer chips', () {
    String label(String mode) =>
        QueueItem(id: 'x', prompt: 'p', workflowMode: mode).modeLabel;
    expect(label('dual_single'), '9:16 + Foldable');
    expect(label('single'), 'Single 9:16');
    expect(label('set_dual'), 'Dual Set (2)');
    expect(label('set_24h'), '24-Hour Set (4)');
    expect(label('set_battery'), 'Battery Set (6)');
  });

  test('fromJson fills defaults for a sparse map', () {
    final item = QueueItem.fromJson({'id': '9', 'prompt': 'hi'});
    expect(item.workflowMode, 'single');
    expect(item.status, 'pending');
    expect(item.subfolder, 'Gemini_HD');
    expect(item.upscaleEnabled, isTrue);
    expect(item.portraitWidth, 1620);
    expect(item.portraitHeight, 2880);
  });
}
