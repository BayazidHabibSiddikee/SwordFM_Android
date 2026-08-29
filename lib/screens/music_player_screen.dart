import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../theme/theme.dart';

/// Music player screen with playlist support and controls.
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
  late AudioPlayer _player;
  bool _initialized = false;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _init();
  }

  Future<void> _init() async {
    final paths = widget.playlist.isNotEmpty
        ? widget.playlist
        : [widget.filePath!];
    final playlist = ConcatenatingAudioSource(
      children: paths.map((p) => AudioSource.file(p)).toList(),
    );
    await _player.setAudioSource(playlist, initialIndex: widget.initialIndex);
    _currentIndex = widget.initialIndex;
    _player.currentIndexStream.listen((i) {
      if (i != null && mounted) setState(() => _currentIndex = i);
    });
    if (mounted) setState(() => _initialized = true);
    _player.play();
  }

  @override
  void dispose() {
    _player.dispose();
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
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      body: _initialized
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
                    stream: _player.positionStream,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = _player.duration ?? Duration.zero;
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Slider(
                              value: pos.inMilliseconds.toDouble().clamp(
                                0,
                                dur.inMilliseconds.toDouble(),
                              ),
                              max: dur.inMilliseconds.toDouble().clamp(
                                1,
                                double.infinity,
                              ),
                              activeColor: OneDarkColors.cyan,
                              inactiveColor: OneDarkColors.border,
                              onChanged: (v) => _player.seek(
                                Duration(milliseconds: v.toInt()),
                              ),
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
                        onPressed: _player.hasPrevious
                            ? _player.seekToPrevious
                            : null,
                      ),
                      const SizedBox(width: 16),
                      StreamBuilder<PlayerState>(
                        stream: _player.playerStateStream,
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
                            onPressed: () =>
                                playing ? _player.pause() : _player.play(),
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
                        onPressed: _player.hasNext ? _player.seekToNext : null,
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
                            onTap: () => _player.seek(Duration.zero, index: i),
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
