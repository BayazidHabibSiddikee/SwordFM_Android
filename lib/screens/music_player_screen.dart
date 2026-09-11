import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_handler.dart';
import '../theme/theme.dart';

/// Music player screen with playlist, speed, sleep timer, shuffle, repeat.
class MusicPlayerScreen extends StatefulWidget {
  final String? filePath;
  final List<String> playlist;
  final int initialIndex;
  const MusicPlayerScreen({
    super.key,
    this.filePath,
    this.playlist = const [],
    this.initialIndex = 0,
  });
  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayerScreen> {
  AudioPlayer? _player;
  SwiftAudioHandler? _handler;

  /// Reused across opens when the background handler is unavailable (e.g.
  /// AudioService.init failed), so repeated opens can never stack several
  /// native players on top of each other — the reported "audio acts crazy".
  static AudioPlayer? _fallbackPlayer;

  bool _initialized = false;
  int _currentIndex = 0;

  // Extra controls state
  double _speed = 1.0;
  bool _shuffle = false;
  LoopMode _loopMode = LoopMode.off;
  Timer? _sleepTimer;
  int? _sleepMinutesLeft;
  StreamSubscription<int?>? _indexSubscription;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final reopened = widget.filePath == null && widget.playlist.isEmpty;
    _handler = swiftAudioHandler;
    if (_handler != null) {
      _player = _handler!.player;
      if (!reopened) {
        final paths = widget.playlist.isNotEmpty
            ? widget.playlist
            : [widget.filePath!];
        await _handler!.loadQueue(paths, initialIndex: widget.initialIndex);
      }
      _currentIndex = _player!.currentIndex ?? widget.initialIndex;
      // Sync existing speed/shuffle/loop from player
      _speed = _player!.speed;
      _shuffle = _player!.shuffleModeEnabled;
      _loopMode = _player!.loopMode;
      _indexSubscription = _player!.currentIndexStream.listen((i) {
        if (i != null && mounted) setState(() => _currentIndex = i);
      });
    } else {
      if (reopened) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      _fallbackPlayer?.dispose();
      _fallbackPlayer = AudioPlayer();
      _player = _fallbackPlayer;
      final pl = ConcatenatingAudioSource(
        children: [widget.filePath!].map((p) => AudioSource.file(p)).toList(),
      );
      await _player!.setAudioSource(pl, initialIndex: widget.initialIndex);
      _currentIndex = widget.initialIndex;
      _indexSubscription = _player!.currentIndexStream.listen((i) {
        if (i != null && mounted) setState(() => _currentIndex = i);
      });
    }
    if (mounted) setState(() => _initialized = true);
    if (!reopened) await _player!.play();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _indexSubscription?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _currentTitle() {
    if (widget.playlist.isNotEmpty && _currentIndex < widget.playlist.length) {
      return widget.playlist[_currentIndex].split('/').last;
    }
    if (widget.filePath != null) return widget.filePath!.split('/').last;
    return swiftAudioHandler?.mediaItem.value?.title ?? 'Unknown';
  }

  // ── Speed ──────────────────────────────────────────────────────────────────
  void _showSpeedPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OneDarkColors.bg,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Playback Speed',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
            ListTile(
              title: Text(
                '${s}x',
                style: TextStyle(
                  color: s == _speed ? OneDarkColors.cyan : OneDarkColors.fg,
                ),
              ),
              trailing: s == _speed
                  ? Icon(Icons.check, color: OneDarkColors.cyan)
                  : null,
              onTap: () async {
                setState(() => _speed = s);
                await _player!.setSpeed(s);
                if (_handler != null) await _handler!.setSpeed(s);
                if (mounted) Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ── Sleep timer ────────────────────────────────────────────────────────────
  void _showSleepTimer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OneDarkColors.bg,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Sleep Timer',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_sleepTimer != null)
            ListTile(
              leading: Icon(Icons.timer_off, color: OneDarkColors.red),
              title: Text(
                'Cancel (${_sleepMinutesLeft ?? '?'} min left)',
                style: TextStyle(color: OneDarkColors.red),
              ),
              onTap: () {
                _cancelSleepTimer();
                Navigator.pop(context);
              },
            ),
          for (final min in [5, 10, 15, 20, 30, 45, 60, 90])
            ListTile(
              leading: Icon(Icons.timer, color: OneDarkColors.amber),
              title: Text(
                '$min minutes',
                style: TextStyle(color: OneDarkColors.fg),
              ),
              onTap: () {
                _startSleepTimer(min);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _startSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    setState(() => _sleepMinutesLeft = minutes);
    // Update countdown every minute
    Timer.periodic(const Duration(minutes: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _sleepMinutesLeft = (_sleepMinutesLeft ?? 1) - 1);
      if (_sleepMinutesLeft! <= 0) {
        t.cancel();
        _player?.pause();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sleep timer: playback stopped')),
          );
        }
      }
    });
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _player?.pause();
      if (mounted) {
        setState(() {
          _sleepTimer = null;
          _sleepMinutesLeft = null;
        });
      }
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    setState(() {
      _sleepTimer = null;
      _sleepMinutesLeft = null;
    });
  }

  // ── Shuffle ────────────────────────────────────────────────────────────────
  Future<void> _toggleShuffle() async {
    final next = !_shuffle;
    setState(() => _shuffle = next);
    await _player!.setShuffleModeEnabled(next);
    if (_handler != null) {
      await _handler!.setShuffleMode(
        next ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      );
    }
  }

  // ── Loop / Repeat ──────────────────────────────────────────────────────────
  Future<void> _cycleLoop() async {
    final next = _loopMode == LoopMode.off
        ? LoopMode.all
        : _loopMode == LoopMode.all
        ? LoopMode.one
        : LoopMode.off;
    setState(() => _loopMode = next);
    await _player!.setLoopMode(next);
    if (_handler != null) await _handler!.setLoopMode(next);
  }

  IconData get _loopIcon {
    switch (_loopMode) {
      case LoopMode.one:
        return Icons.repeat_one;
      case LoopMode.all:
        return Icons.repeat;
      default:
        return Icons.repeat;
    }
  }

  Color get _loopColor =>
      _loopMode == LoopMode.off ? OneDarkColors.fgDim : OneDarkColors.cyan;

  @override
  Widget build(BuildContext context) {
    final p = _player;
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      body: _initialized && p != null
          ? SafeArea(
              child: Column(
                children: [
                  // ── Top bar ──────────────────────────────────────────────
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_downward,
                          color: OneDarkColors.fg,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(
                          'Now Playing',
                          style: TextStyle(
                            color: OneDarkColors.fg,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      // Sleep timer indicator
                      if (_sleepTimer != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.timer,
                                size: 14,
                                color: OneDarkColors.amber,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '${_sleepMinutesLeft}m',
                                style: TextStyle(
                                  color: OneDarkColors.amber,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Album art ────────────────────────────────────────────
                  Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: OneDarkColors.bg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: OneDarkColors.border),
                    ),
                    child: Icon(
                      Icons.music_note,
                      size: 80,
                      color: OneDarkColors.cyan,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Title ────────────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _currentTitle(),
                      style: TextStyle(
                        color: OneDarkColors.fg,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Track ${_currentIndex + 1} of ${widget.playlist.isNotEmpty ? widget.playlist.length : 1}',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                  const SizedBox(height: 24),

                  // ── Progress bar ─────────────────────────────────────────
                  StreamBuilder<Duration>(
                    stream: p.positionStream,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = p.duration ?? Duration.zero;
                      final durMs = dur.inMilliseconds.toDouble();
                      final maxMs = durMs > 0 ? durMs : 1.0;
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Slider(
                              value: pos.inMilliseconds.toDouble().clamp(
                                0.0,
                                maxMs,
                              ),
                              max: maxMs,
                              activeColor: OneDarkColors.cyan,
                              inactiveColor: OneDarkColors.border,
                              onChanged: durMs > 0
                                  ? (v) => p.seek(
                                      Duration(milliseconds: v.toInt()),
                                    )
                                  : null,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _format(pos),
                                  style: TextStyle(
                                    color: OneDarkColors.fgDim,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  _format(dur),
                                  style: TextStyle(
                                    color: OneDarkColors.fgDim,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),

                  // ── Main controls ────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.skip_previous,
                          color: OneDarkColors.fg,
                          size: 32,
                        ),
                        onPressed: p.hasPrevious ? p.seekToPrevious : null,
                      ),
                      const SizedBox(width: 16),
                      StreamBuilder<PlayerState>(
                        stream: p.playerStateStream,
                        builder: (_, snap) {
                          final playing = snap.data?.playing ?? false;
                          return IconButton(
                            icon: Icon(
                              playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              size: 56,
                              color: OneDarkColors.cyan,
                            ),
                            onPressed: () => playing ? p.pause() : p.play(),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: Icon(
                          Icons.skip_next,
                          color: OneDarkColors.fg,
                          size: 32,
                        ),
                        onPressed: p.hasNext ? p.seekToNext : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // ── Extra controls: shuffle · repeat · speed · sleep ─────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Shuffle
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: _shuffle
                              ? OneDarkColors.cyan
                              : OneDarkColors.fgDim,
                          size: 22,
                        ),
                        onPressed: _toggleShuffle,
                        tooltip: _shuffle ? 'Shuffle on' : 'Shuffle off',
                      ),
                      // Repeat
                      IconButton(
                        icon: Icon(_loopIcon, color: _loopColor, size: 22),
                        onPressed: _cycleLoop,
                        tooltip: _loopMode == LoopMode.off
                            ? 'Repeat off'
                            : _loopMode == LoopMode.all
                            ? 'Repeat all'
                            : 'Repeat one',
                      ),
                      const SizedBox(width: 8),
                      // Speed
                      GestureDetector(
                        onTap: _showSpeedPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _speed != 1.0
                                  ? OneDarkColors.cyan
                                  : OneDarkColors.border,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_speed}x',
                            style: TextStyle(
                              color: _speed != 1.0
                                  ? OneDarkColors.cyan
                                  : OneDarkColors.fgDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Sleep timer
                      IconButton(
                        icon: Icon(
                          _sleepTimer != null
                              ? Icons.timer
                              : Icons.timer_outlined,
                          color: _sleepTimer != null
                              ? OneDarkColors.amber
                              : OneDarkColors.fgDim,
                          size: 22,
                        ),
                        onPressed: _showSleepTimer,
                        tooltip: 'Sleep timer',
                      ),
                    ],
                  ),

                  // ── Playlist ─────────────────────────────────────────────
                  if (widget.playlist.length > 1)
                    Expanded(
                      child: ListView.builder(
                        itemCount: widget.playlist.length,
                        itemBuilder: (_, i) {
                          final isCurrent = i == _currentIndex;
                          final name = widget.playlist[i].split('/').last;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isCurrent ? Icons.music_note : Icons.music_off,
                              size: 18,
                              color: isCurrent
                                  ? OneDarkColors.cyan
                                  : OneDarkColors.fgDim,
                            ),
                            title: Text(
                              name,
                              style: TextStyle(
                                color: isCurrent
                                    ? OneDarkColors.cyan
                                    : OneDarkColors.fg,
                                fontSize: 12,
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => p.seek(Duration.zero, index: i),
                          );
                        },
                      ),
                    ),
                ],
              ),
            )
          : Center(child: CircularProgressIndicator(color: OneDarkColors.cyan)),
    );
  }
}
