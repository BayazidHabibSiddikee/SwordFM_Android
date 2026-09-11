import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'playback_resume_policy.dart';
import 'playback_resume_store.dart';

/// The single instance of the background audio handler, set once in main().
/// The UI reads this to drive playback (the music player never creates its own
/// AudioPlayer — it routes through this one so playback survives backgrounding).
SwiftAudioHandler? swiftAudioHandler;

/// Owns the single just_audio [AudioPlayer] that keeps playing even when the
/// screen is locked or the app is in the background.
///
/// audio_service runs the handler in the background isolate (and, on Android,
/// wraps it in a foreground service with a media notification), so playback
/// continues while the UI is gone. The media notification on the lock screen
/// and in the shade re-uses the same handler for play / pause / skip / seek —
/// no separate controller UI needed.
///
/// All state is derived from the underlying [AudioPlayer] streams, so the
/// app only ever drives the player; it never has to mirror playback state.
class SwiftAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final List<String> _queuePaths = <String>[];
  final List<PlaybackMediaIdentity?> _queueIdentities =
      <PlaybackMediaIdentity?>[];
  final PlaybackResumePolicy _resumePolicy = const PlaybackResumePolicy();
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<int?> _currentIndexSubscription;
  late final StreamSubscription<ProcessingState> _processingStateSubscription;
  Timer? _resumeTimer;
  Future<PlaybackResumeStore>? _resumeStoreFuture;
  Future<void> _resumeWriteChain = Future<void>.value();
  bool _disposed = false;

  /// The underlying just_audio player. Exposed so the UI can keep using the
  /// familiar player API while playback runs through this handler (and thus
  /// survives backgrounding / lock screen).
  AudioPlayer get player => _player;

  SwiftAudioHandler() {
    _configureSession();
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      final playing = state.playing;
      final processingState = state.processingState;
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop, // ← Stop button always visible
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.stop, // ← allows swipe-to-dismiss on Android
          },
          androidCompactActionIndices: const [
            0,
            1,
            2,
          ], // prev|play|next in compact view
          playing: playing,
          processingState: processingState == ProcessingState.completed
              ? AudioProcessingState.completed
              : AudioProcessingState.ready,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
          queueIndex: _player.currentIndex,
        ),
      );
    });

    // Track changes → current media item and persisted position.
    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      if (_player.sequence != null &&
          index != null &&
          index >= 0 &&
          index < _player.sequence!.length) {
        final source = _player.sequence![index];
        final tag = (source as dynamic).tag as Map<String, dynamic>?;
        mediaItem.add(
          MediaItem(
            id: (tag?['path'] as String?) ?? '$index',
            title: (tag?['title'] as String?) ?? 'Track ${index + 1}',
            artist: 'SwordFM',
          ),
        );
      }
    });

    // Completion / auto-next: save the final point, then advance to the next
    // track; stop only at the end of the queue.
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      if (state == ProcessingState.completed) {
        _writeCurrentResume();
        if (_player.hasNext) {
          _player.seekToNext();
        } else {
          stop();
        }
      }
    });
    _resumeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_player.playing) _writeCurrentResume();
    });
  }

  /// Requests audio focus and announces the app as music media playback so the
  /// system keeps it playing in the background and shows correct volume/
  /// control behaviour (ducking, lock-screen media).
  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('SwiftAudioHandler: audio session setup failed: $e');
    }
  }

  /// Loads [paths] as the new queue and starts playing at [initialIndex].
  Future<void> loadQueue(List<String> paths, {int initialIndex = 0}) async {
    _writeCurrentResume();
    _queuePaths
      ..clear()
      ..addAll(paths);
    _queueIdentities
      ..clear()
      ..addAll(await Future.wait(paths.map(_identityFor)));
    final sources = paths
        .map(
          (p) =>
              AudioSource.file(p, tag: {'path': p, 'title': p.split('/').last}),
        )
        .toList();
    if (sources.isEmpty) return;
    final validIndex = initialIndex >= 0 && initialIndex < sources.length
        ? initialIndex
        : 0;
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: validIndex,
    );
    await _restoreCurrentResume();
    await play();
  }

  Future<PlaybackMediaIdentity?> _identityFor(String path) async {
    try {
      final stat = await File(path).stat();
      return PlaybackMediaIdentity.fromMilliseconds(
        path: path,
        fileSize: stat.size,
        modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  Future<PlaybackResumeStore> _resumeStore() {
    return _resumeStoreFuture ??= PlaybackResumeStore.create();
  }

  Future<void> _restoreCurrentResume() async {
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueIdentities.length) return;
    final identity = _queueIdentities[index];
    if (identity == null) return;
    try {
      final point = meaningfulPlaybackResume(
        identity,
        await (await _resumeStore()).read(identity),
        currentIdentity: identity,
        policy: _resumePolicy,
      );
      if (point != null && _player.duration != null) {
        await _player.seek(point.position);
      }
    } catch (e) {
      debugPrint('SwiftAudioHandler: resume restore failed: $e');
    }
  }

  void _writeCurrentResume() {
    if (_disposed) return;
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueIdentities.length) return;
    final identity = _queueIdentities[index];
    if (identity == null) return;
    final duration = _player.duration;
    var position = _player.position;
    if (duration != null && position > duration) position = duration;
    final point = PlaybackResumePoint.fromMilliseconds(
      positionMs: position.inMilliseconds,
      durationMs: duration?.inMilliseconds,
      queueIndex: index,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    _resumeWriteChain = _resumeWriteChain.then((_) async {
      try {
        await (await _resumeStore()).write(identity, point);
      } catch (e) {
        debugPrint('SwiftAudioHandler: resume save failed: $e');
      }
    });
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    await _player.pause();
    _writeCurrentResume();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _writeCurrentResume();
  }

  @override
  Future<void> skipToNext() async {
    _writeCurrentResume();
    await _player.seekToNext();
    await _restoreCurrentResume();
  }

  @override
  Future<void> skipToPrevious() async {
    _writeCurrentResume();
    await _player.seekToPrevious();
    await _restoreCurrentResume();
  }

  @override
  Future<void> stop() async {
    _writeCurrentResume();
    await _resumeWriteChain;
    await _player.stop();
    // Broadcast idle so the system removes the ongoing notification
    // and the lock-screen controls disappear immediately.
    playbackState.add(
      playbackState.value.copyWith(
        controls: [],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    mediaItem.add(null);
  }

  @override
  Future<void> onTaskRemoved() async {
    _writeCurrentResume();
    await _resumeWriteChain;
    await super.onTaskRemoved();
  }

  /// Releases handler-owned subscriptions and timers. Audio service normally
  /// owns this instance for the process lifetime, but explicit cleanup keeps
  /// tests and alternate hosts from leaking listeners.
  Future<void> dispose() async {
    if (_disposed) return;
    _resumeTimer?.cancel();
    _writeCurrentResume();
    await _resumeWriteChain;
    _disposed = true;
    await _playerStateSubscription.cancel();
    await _currentIndexSubscription.cancel();
    await _processingStateSubscription.cancel();
    await _player.dispose();
  }

  /// Sets the playback speed (e.g. 0.5, 0.75, 1.0, 1.25, 1.5, 2.0).
  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }

  /// Enables or disables shuffle mode on the underlying player.
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async {
    await _player.setShuffleModeEnabled(mode == AudioServiceShuffleMode.all);
  }

  /// Sets the loop / repeat mode (off, one, all).
  Future<void> setLoopMode(LoopMode mode) async {
    await _player.setLoopMode(mode);
  }
}
