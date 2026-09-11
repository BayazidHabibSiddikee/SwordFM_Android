import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/playback_resume_policy.dart';
import '../services/playback_resume_store.dart';
import '../theme/theme.dart';
import '../utils/media_kit_guard.dart';

/// Full-screen video player backed by media_kit / libmpv.
///
/// Supports: MKV, MP4, AVI, MOV, WebM, TS, 3GP …
/// Codecs: H.264/H.265/VP8/VP9/AV1, AC3, DTS, EAC3, TrueHD, MP3, AAC, FLAC
/// Features: subtitles (.srt/.ass/embedded sidecars + embedded tracks),
///           speed control, audio-track selection, auto-next playlist.
/// Roadmap (not yet shipped): aspect-ratio switch, hardware-decode toggle, PiP.
class VideoPlayerScreen extends StatefulWidget {
  final String filePath;

  /// Optional playlist for auto-next (sibling files).
  final List<String> playlist;
  final int initialIndex;

  const VideoPlayerScreen({
    super.key,
    required this.filePath,
    this.playlist = const [],
    this.initialIndex = 0,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;

  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _resumeTimer;
  double _speed = 1.0;
  bool _showSubtitles = true;
  String? _error;
  PlaybackResumeStore? _resumeStore;
  PlaybackMediaIdentity? _currentIdentity;
  Future<void> _resumeWriteChain = Future<void>.value();

  List<String> get _playlist =>
      widget.playlist.isNotEmpty ? widget.playlist : [widget.filePath];
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _currentIndex = widget.initialIndex.clamp(0, _playlist.length - 1);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      // Belt-and-braces: normally done once in main(); cheap no-op if already
      // initialised, but if main's init was skipped (e.g. an earlier failure)
      // this is what makes the error visible instead of a silent hang.
      MediaKitGuard.ensure();
      _player = Player(
        configuration: const PlayerConfiguration(
          title: 'SwordFM',
          logLevel: MPVLogLevel.warn,
        ),
      );
      _controller = VideoController(
        _player!,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
        ),
      );

      _player!.stream.error.listen((err) {
        if (mounted) setState(() => _error = err);
      });

      _player!.stream.completed.listen((completed) {
        if (completed) _tryPlayNext();
      });

      await _openCurrent();
      _resumeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _saveResume();
      });
      _scheduleHide();
    } catch (e) {
      // Surface construction/init failures in the error overlay too.
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openCurrent() async {
    _saveResume();
    final path = _playlist[_currentIndex];
    _currentIdentity = await _identityFor(path);
    try {
      await _player!.open(Media(path));
      await _restoreResume();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
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

  Future<PlaybackResumeStore> _store() async {
    return _resumeStore ??= await PlaybackResumeStore.create();
  }

  Future<void> _restoreResume() async {
    final identity = _currentIdentity;
    if (identity == null) return;
    try {
      final point = meaningfulPlaybackResume(
        identity,
        await (await _store()).read(identity),
        currentIdentity: identity,
      );
      if (point != null) {
        await _player?.seek(point.position);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Resumed from the last position')),
          );
        }
      }
    } catch (e) {
      debugPrint('VideoPlayerScreen: resume restore failed: $e');
    }
  }

  void _saveResume() {
    final identity = _currentIdentity;
    final player = _player;
    if (identity == null || player == null) return;
    final duration = player.state.duration;
    var position = player.state.position;
    if (duration > Duration.zero && position > duration) position = duration;
    final point = PlaybackResumePoint.fromMilliseconds(
      positionMs: position.inMilliseconds,
      durationMs: duration > Duration.zero ? duration.inMilliseconds : null,
      queueIndex: _currentIndex,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    _resumeWriteChain = _resumeWriteChain.then((_) async {
      try {
        await (await _store()).write(identity, point);
      } catch (e) {
        debugPrint('VideoPlayerScreen: resume save failed: $e');
      }
    });
  }

  Future<void> _tryPlayNext() async {
    _saveResume();
    await _resumeWriteChain;
    if (_currentIndex < _playlist.length - 1) {
      if (mounted) setState(() => _currentIndex++);
      await _openCurrent();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _resumeTimer?.cancel();
    _saveResume();
    _resumeWriteChain = _resumeWriteChain.catchError((_) {});
    _player?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _saveResume();
      _player?.pause();
    }
  }

  String _fileName() => _playlist[_currentIndex].split('/').last;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Speed picker
  // ──────────────────────────────────────────────────────────────────────────
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
          for (final s in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
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
              onTap: () {
                setState(() => _speed = s);
                _player?.setRate(s);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Audio track picker
  // ──────────────────────────────────────────────────────────────────────────
  void _showAudioTracks() {
    final tracks = _player?.state.tracks.audio;
    if (tracks == null || tracks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No audio tracks found')));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OneDarkColors.bg,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Audio Track',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final t in tracks)
            ListTile(
              title: Text(
                t.title?.isNotEmpty == true
                    ? t.title!
                    : t.language?.isNotEmpty == true
                    ? t.language!
                    : 'Track ${t.id}',
                style: TextStyle(color: OneDarkColors.fg),
              ),
              onTap: () {
                _player?.setAudioTrack(t);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Subtitle track picker
  // ──────────────────────────────────────────────────────────────────────────
  void _showSubtitleTracks() {
    final tracks = _player?.state.tracks.subtitle;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OneDarkColors.bg,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Subtitles',
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            title: Text('Off', style: TextStyle(color: OneDarkColors.fg)),
            onTap: () {
              setState(() => _showSubtitles = false);
              _player?.setSubtitleTrack(SubtitleTrack.no());
              Navigator.pop(context);
            },
          ),
          for (final t in tracks ?? [])
            ListTile(
              title: Text(
                t.title?.isNotEmpty == true
                    ? t.title!
                    : t.language?.isNotEmpty == true
                    ? t.language!
                    : 'Track ${t.id}',
                style: TextStyle(color: OneDarkColors.fg),
              ),
              onTap: () {
                setState(() => _showSubtitles = true);
                _player?.setSubtitleTrack(t);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Video surface ──────────────────────────────────────────────
            if (_controller != null)
              Video(
                controller: _controller!,
                subtitleViewConfiguration: SubtitleViewConfiguration(
                  visible: _showSubtitles,
                ),
              )
            else
              Center(
                child: _error == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Icon(
                        Icons.error_outline,
                        color: Colors.white,
                        size: 48,
                      ),
              ),

            // ── Error overlay ──────────────────────────────────────────────
            if (_error != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Could not play this file.\n\n$_error',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // ── Controls overlay ───────────────────────────────────────────
            if (_showControls && _error == null) ...[
              // Top bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(4, 36, 8, 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(
                          _fileName(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Speed
                      IconButton(
                        icon: Text(
                          '${_speed}x',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        onPressed: _showSpeedPicker,
                        tooltip: 'Playback speed',
                      ),
                      // Audio tracks
                      IconButton(
                        icon: const Icon(
                          Icons.audiotrack,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: _showAudioTracks,
                        tooltip: 'Audio track',
                      ),
                      // Subtitles
                      IconButton(
                        icon: Icon(
                          _showSubtitles
                              ? Icons.subtitles
                              : Icons.subtitles_off,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: _showSubtitleTracks,
                        tooltip: 'Subtitles',
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom controls
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Seek bar
                      StreamBuilder<Duration>(
                        stream: _player?.stream.position,
                        builder: (_, posSnap) {
                          return StreamBuilder<Duration?>(
                            stream: _player?.stream.duration,
                            builder: (_, durSnap) {
                              final pos = posSnap.data ?? Duration.zero;
                              final dur = durSnap.data ?? Duration.zero;
                              final durMs = dur.inMilliseconds.toDouble();
                              final maxMs = durMs > 0 ? durMs : 1.0;
                              return Column(
                                children: [
                                  Slider(
                                    value: pos.inMilliseconds.toDouble().clamp(
                                      0.0,
                                      maxMs,
                                    ),
                                    max: maxMs,
                                    activeColor: OneDarkColors.cyan,
                                    inactiveColor: Colors.white38,
                                    onChanged: durMs > 0
                                        ? (v) => _player?.seek(
                                            Duration(milliseconds: v.toInt()),
                                          )
                                        : null,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _fmt(pos),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                        Text(
                                          _fmt(dur),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      // Playback controls row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Prev in playlist
                          if (_playlist.length > 1)
                            IconButton(
                              icon: const Icon(
                                Icons.skip_previous,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: _currentIndex > 0
                                  ? () {
                                      setState(() => _currentIndex--);
                                      _openCurrent();
                                    }
                                  : null,
                            ),
                          // ± 10s
                          IconButton(
                            icon: const Icon(
                              Icons.replay_10,
                              color: Colors.white,
                              size: 28,
                            ),
                            onPressed: () => _player?.seek(
                              _player!.state.position -
                                  const Duration(seconds: 10),
                            ),
                          ),
                          // Play / Pause
                          const SizedBox(width: 8),
                          StreamBuilder<bool>(
                            stream: _player?.stream.playing,
                            builder: (_, snap) {
                              final playing = snap.data ?? false;
                              return IconButton(
                                icon: Icon(
                                  playing
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  color: OneDarkColors.cyan,
                                  size: 56,
                                ),
                                onPressed: () => playing
                                    ? _player?.pause()
                                    : _player?.play(),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.forward_10,
                              color: Colors.white,
                              size: 28,
                            ),
                            onPressed: () => _player?.seek(
                              _player!.state.position +
                                  const Duration(seconds: 10),
                            ),
                          ),
                          // Next in playlist
                          if (_playlist.length > 1)
                            IconButton(
                              icon: const Icon(
                                Icons.skip_next,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: _currentIndex < _playlist.length - 1
                                  ? () {
                                      setState(() => _currentIndex++);
                                      _openCurrent();
                                    }
                                  : null,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
