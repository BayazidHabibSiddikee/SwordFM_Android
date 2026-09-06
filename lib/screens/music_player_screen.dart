import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_handler.dart';
import '../theme/theme.dart';

/// Music player screen with playlist support and controls.
///
/// Routes playback through the app-wide [SwiftAudioHandler] (set up in
/// `main()`) so the audio session keeps playing when the screen locks or
/// the app is backgrounded. The player UI never creates its own
/// [AudioPlayer] — it reads from `swiftAudioHandler!.player`.
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
  // Pulled from the global SwiftAudioHandler set in main(). If it's null
  // (AudioService init failed on this platform) we fall back to a local
  // player so the UI still works.
  AudioPlayer? _player;
  SwiftAudioHandler? _handler;
  bool _initialized = false;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final paths = widget.playlist.isNotEmpty
        ? widget.playlist
        : [widget.filePath!];
    _handler = swiftAudioHandler;
    if (_handler != null) {
      // Use the shared background-capable player.
      _player = _handler!.player;
      await _handler!.loadQueue(paths, initialIndex: widget.initialIndex);
      _currentIndex = widget.initialIndex;
      _player!.currentIndexStream.listen((i) {
        if (i != null && mounted) setState(() => _currentIndex = i);
      });
    } else {
      // Fallback: spin up a local player. Playback won't survive
      // backgrounding on this path, but the UI still works.
      _player = AudioPlayer();
      final playlist = ConcatenatingAudioSource(
        children: paths.map((p) => AudioSource.file(p)).toList(),
      );
      await _player!.setAudioSource(playlist,
          initialIndex: widget.initialIndex);
      _currentIndex = widget.initialIndex;
      _player!.currentIndexStream.listen((i) {
        if (i != null && mounted) setState(() => _currentIndex = i);
      });
    }
    if (mounted) setState(() => _initialized = true);
    await _player!.play();
  }

  @override
  void dispose() {
    // Don't dispose the player — it's the shared handler. Just remove
    // the listener subscription. The handler keeps playing in the
    // background; the user can return to the player UI from the
    // notification or re-open the screen.
    super.dispose();
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _currentTitle() {
    final paths = widget.playlist.isNotEmpty
        ? widget.playlist
        : [widget.filePath!];
    if (_currentIndex < paths.length) {
      return paths[_currentIndex].split('/').last;
    }
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      body: _initialized && p != null
          ? SafeArea(
              child: Column(
                children: [
                  // Top bar
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
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Album art placeholder
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
                  // Title
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
                  const SizedBox(height: 8),
                  Text(
                    'Track ${_currentIndex + 1} of ${widget.playlist.isNotEmpty ? widget.playlist.length : 1}',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                  const SizedBox(height: 24),
                  // Progress
                  StreamBuilder<Duration>(
                    stream: p.positionStream,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = p.duration ?? Duration.zero;
                      // Slider requires max > min AND a finite max. When the
                      // audio hasn't loaded a real duration yet (dur is
                      // Duration.zero), use a 1ms window so the slider
                      // renders without throwing. Once duration lands the
                      // StreamBuilder rebuilds with the real value.
                      final durMs = dur.inMilliseconds.toDouble();
                      final maxMs = durMs > 0 ? durMs : 1.0;
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Slider(
                              value: pos.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, maxMs),
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
                  const SizedBox(height: 16),
                  // Controls
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
                          final state = snap.data;
                          final playing = state?.playing ?? false;
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
                  const SizedBox(height: 24),
                  // Playlist
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
