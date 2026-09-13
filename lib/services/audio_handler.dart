import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart'
    show readMetadata;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'playback_resume_policy.dart';
import 'playback_resume_store.dart';

/// Embedded-tag metadata for one queued file, read once at queue-load time.
///
/// Null fields mean "no tag" — callers fall back to the filename. Tags are
/// read with images disabled (fast header-only parse); cover art stays out
/// of scope until a dedicated artwork cache ships.
class TrackTags {
  final String? title;
  final String? artist;
  final String? album;
  const TrackTags({this.title, this.artist, this.album});

  /// Reads tags for [path] off the calling thread. Never throws — any
  /// failure (missing file, unsupported container, corrupt header) yields
  /// empty tags so playback never depends on metadata.
  static Future<TrackTags> read(String path) async {
    try {
      final meta = await Future(() => readMetadata(File(path)));
      return TrackTags(
        title: _clean(meta.title),
        artist: _clean(meta.artist ?? meta.albumArtist),
        album: _clean(meta.album),
      );
    } catch (_) {
      return const TrackTags();
    }
  }

  static String? _clean(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Synchronous tag read for use inside [Isolate.run]. Never throws.
  static TrackTags readSync(String path) {
    try {
      final meta = readMetadata(File(path));
      return TrackTags(
        title: _clean(meta.title),
        artist: _clean(meta.artist ?? meta.albumArtist),
        album: _clean(meta.album),
      );
    } catch (_) {
      return const TrackTags();
    }
  }
}

/// Top-level batch tag reader for [Isolate.run].
///
/// Returns plain maps (NOT TrackTags): custom class instances do not cross
/// the isolate boundary reliably, so each map holds title/artist/album
/// strings (or nothing) and the caller re-wraps them into TrackTags.
/// Must stay a top-level function so it can be passed to [Isolate.run].
/// The [List<String>] argument is sendable, so capturing the local batch
/// list in the Isolate.run closure is allowed (verified: no MethodChannel
/// or plugin use inside readMetadata — pure dart:io parsing).
Future<List<Map<String, String?>>> _readAllTags(List<String> paths) async {
  final out = <Map<String, String?>>[];
  for (final p in paths) {
    try {
      final t = TrackTags.readSync(p);
      out.add({'title': t.title, 'artist': t.artist, 'album': t.album});
    } catch (_) {
      out.add(const <String, String?>{});
    }
  }
  return out;
}

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
  final List<TrackTags> _queueTags = <TrackTags>[];
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

  /// Embedded tags for the currently playing track (empty when untagged).
  /// The player screen reads this to show artist/album under the title.
  TrackTags get currentTags {
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueTags.length) {
      return const TrackTags();
    }
    return _queueTags[index];
  }

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
      if (_disposed) return;
      if (_player.sequence != null &&
          index != null &&
          index >= 0 &&
          index < _player.sequence!.length) {
        // Fill tags lazily for tracks beyond the background batch.
        unawaited(_ensureTagsFor(index));
        final source = _player.sequence![index];
        final tag = (source as dynamic).tag as Map<String, dynamic>?;
        final tags = index >= 0 && index < _queueTags.length
            ? _queueTags[index]
            : const TrackTags();
        mediaItem.add(
          MediaItem(
            id: (tag?['path'] as String?) ?? '$index',
            title: tags.title ??
                (tag?['title'] as String?) ??
                'Track ${index + 1}',
            artist: tags.artist,
            album: tags.album,
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
  ///
  /// Playback starts on the filename fallback immediately; embedded tags
  /// (title/artist/album) are then read in a background isolate and pushed
  /// into the media item when they land. A slow or corrupt file simply keeps
  /// its filename — the player screen never waits on metadata (the earlier
  /// "controller renders very late" bug was tag reads gating setAudioSource).
  Future<void> loadQueue(List<String> paths, {int initialIndex = 0}) async {
    _writeCurrentResume();
    final generation = ++_queueGeneration;
    _queuePaths
      ..clear()
      ..addAll(paths);
    _queueIdentities
      ..clear()
      ..addAll(paths.map(_identityForSync));
    _queueTags
      ..clear()
      ..addAll(List.filled(paths.length, const TrackTags()));
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
    unawaited(_loadTagsInBackground(paths, generation));
  }

  int _queueGeneration = 0;

  /// Max tracks tag-fetched in one background batch. Huge folders
  /// (thousands of songs) must not be stat'ed + parsed at once in an
  /// isolate: cap the batch and lazily fill the rest on track change.
  static const int _maxTagBatch = 200;

  /// Reads queue tags off-isolate, then refreshes the media item.
  /// A newer loadQueue supersedes this run via the generation check.
  Future<void> _loadTagsInBackground(
    List<String> paths,
    int generation,
  ) async {
    try {
      final batch = paths.length > _maxTagBatch
          ? paths.sublist(0, _maxTagBatch)
          : paths;
      final maps = await Isolate.run(() => _readAllTags(batch));
      if (_disposed || generation != _queueGeneration) return;
      for (var i = 0; i < maps.length && i < _queueTags.length; i++) {
        final m = maps[i];
        _queueTags[i] = TrackTags(
          title: _nonEmpty(m['title']),
          artist: _nonEmpty(m['artist']),
          album: _nonEmpty(m['album']),
        );
      }
      final index = _player.currentIndex;
      if (index != null) _emitMediaItem(index);
    } catch (e) {
      debugPrint('SwiftAudioHandler: tag preload failed: $e');
    }
  }

  static String? _nonEmpty(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Lazily fills tags for [index] when the user skips beyond the initial
  /// background batch (or when the batch had not finished yet). Never
  /// blocks playback: failures keep the filename fallback.
  Future<void> _ensureTagsFor(int index) async {
    if (index < 0 || index >= _queueTags.length || index >= _queuePaths.length) {
      return;
    }
    final cur = _queueTags[index];
    if (cur.title != null || cur.artist != null || cur.album != null) return;
    try {
      final t = await TrackTags.read(_queuePaths[index]);
      if (_disposed) return;
      if (index < _queueTags.length) _queueTags[index] = t;
      if (_player.currentIndex == index) _emitMediaItem(index);
    } catch (_) {}
  }

  /// Publishes the MediaItem (notification + UI) for queue position [index].
  void _emitMediaItem(int index) {
    final sequence = _player.sequence;
    if (sequence == null || index < 0 || index >= sequence.length) return;
    final source = sequence[index];
    final tag = (source as dynamic).tag as Map<String, dynamic>?;
    final tags = index >= 0 && index < _queueTags.length
        ? _queueTags[index]
        : const TrackTags();
    mediaItem.add(
      MediaItem(
        id: (tag?['path'] as String?) ?? '$index',
        title:
            tags.title ?? (tag?['title'] as String?) ?? 'Track ${index + 1}',
        artist: tags.artist,
        album: tags.album,
      ),
    );
  }

  /// Synchronous stat-based identity — cheap and non-blocking, so queue
  /// start never awaits filesystem I/O for every track.
  PlaybackMediaIdentity? _identityForSync(String path) {
    try {
      final stat = File(path).statSync();
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
