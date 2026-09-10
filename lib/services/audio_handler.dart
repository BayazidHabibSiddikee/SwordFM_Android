import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

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

  /// The underlying just_audio player. Exposed so the UI can keep using the
  /// familiar player API while playback runs through this handler (and thus
  /// survives backgrounding / lock screen).
  AudioPlayer get player => _player;

  SwiftAudioHandler() {
    _configureSession();
    // Playback state → broadcast state
    _player.playerStateStream.listen((state) {
      final playing = state.playing;
      final processingState = state.processingState;
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,          // ← Stop button always visible
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.stop,           // ← allows swipe-to-dismiss on Android
        },
        androidCompactActionIndices: const [0, 1, 2], // prev|play|next in compact view
        playing: playing,
        processingState: processingState == ProcessingState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ));
    });

    // Track changes → current media item
    _player.currentIndexStream.listen((index) {
      if (_player.sequence != null && index != null) {
        final source = _player.sequence![index];
        final tag = (source as dynamic).tag as Map<String, dynamic>?;
        mediaItem.add(MediaItem(
          id: (tag?['path'] as String?) ?? '$index',
          title: (tag?['title'] as String?) ?? 'Track ${index + 1}',
          artist: 'SwordFM',
        ));
      }
    });

    // Completion / auto-next: advance to the next track; stop only at end.
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (_player.hasNext) {
          _player.seekToNext();
        } else {
          stop();
        }
      }
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
    final sources = paths
        .map((p) => AudioSource.file(
              p,
              tag: {'path': p, 'title': p.split('/').last},
            ))
        .toList();
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: initialIndex >= 0 && initialIndex < sources.length
          ? initialIndex
          : 0,
    );
    play();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> stop() async {
    await _player.stop();
    // Broadcast idle so the system removes the ongoing notification
    // and the lock-screen controls disappear immediately.
    playbackState.add(playbackState.value.copyWith(
      controls: [],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    mediaItem.add(null);
  }

  /// Sets the playback speed (e.g. 0.5, 0.75, 1.0, 1.25, 1.5, 2.0).
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