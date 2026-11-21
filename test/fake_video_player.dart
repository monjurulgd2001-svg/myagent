import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// v141 — test fake for the video_player platform: the real
/// Android/iOS player is not registered in flutter_test, so the
/// device-frame video preview's VideoPlayerController is driven by
/// this fake instead. It pretends the MP4 initialises instantly
/// (1620x2880, 1s) and records every call the dialog makes.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  /// When true, createWithOptions throws (player init failure path).
  bool failCreate = false;

  DataSource? lastDataSource;
  final List<String> calls = [];
  int _nextPlayerId = 1;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('create');
    if (failCreate) {
      throw PlatformException(code: 'error', message: 'no player');
    }
    lastDataSource = options.dataSource;
    return _nextPlayerId++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return Stream<VideoEvent>.value(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 1),
        size: const Size(1620, 2880),
      ),
    );
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    calls.add('setLooping:$looping');
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('setVolume:$volume');
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    // The controller's play/pause timer polls the position.
    return Duration.zero;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
  }

  @override
  Future<void> init() async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return Container(key: const ValueKey('fakeVideoView'));
  }
}
