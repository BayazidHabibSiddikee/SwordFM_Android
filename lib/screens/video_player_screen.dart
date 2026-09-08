import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/audio_handler.dart';
import '../theme/theme.dart';

/// Full-screen video player with:
/// - Hardware-accelerated playback via video_player
/// - Background audio + lock-screen media notification via audio_service
/// - Auto-hiding controls (tap to toggle)
/// - Seek bar, ±10s, volume mute, fullscreen lock
class VideoPlayerScreen extends StatefulWidget {
  final String filePath;
  const VideoPlayerScreen({super.key, required this.filePath});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  late VideoPlayerController _video;
  bool _initialized = false;
  bool _showControls = true;
  String? _error;
  Timer? _hideTimer;

  String get _fileName => widget.filePath.split('/').last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep screen on while video plays
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initVideo();
  }

  void _initVideo() {
    _video = VideoPlayerController.file(
      File(widget.filePath),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    )
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _initialized = true);
        _video.play();
        _registerWithAudioService();
        _listenToNotificationCommands();
        _scheduleHide();
      }).catchError((e) {
        if (mounted) setState(() => _error = e.toString());
      });
    _video.addListener(_onVideoUpdate);
  }

  /// Listens to playback state changes pushed from the notification buttons
  /// (Stop / Pause / Play) so tapping Stop on the lock screen actually stops
  /// the video and closes the notification.
  void _listenToNotificationCommands() {
    final handler = swiftAudioHandler;
    if (handler == null) return;
    handler.playbackState.listen((state) {
      if (!mounted || !_initialized) return;
      // Stop tapped from notification
      if (state.processingState == AudioProcessingState.idle &&
          state.controls.isEmpty) {
        if (_video.value.isPlaying) _video.pause();
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      // Play/Pause tapped from notification
      if (state.playing && !_video.value.isPlaying) {
        _video.play();
      } else if (!state.playing && _video.value.isPlaying &&
          state.processingState != AudioProcessingState.idle) {
        _video.pause();
      }
    });
  }

  /// Registers the currently playing video with audio_service so Android
  /// shows a media notification on the lock screen / notification shade
  /// with Play/Pause and Stop controls. This is what keeps audio running
  /// in the background when the screen locks.
  void _registerWithAudioService() {
    final handler = swiftAudioHandler;
    if (handler == null) return;
    final item = MediaItem(
      id: widget.filePath,
      title: _fileName.replaceAll(RegExp(r'\.[^.]+$'), ''),
      artist: 'SwordFM Video',
      duration: _video.value.duration,
      extras: {'isVideo': true},
    );
    handler.mediaItem.add(item);
    // Sync playback state so the notification shows correct play/pause
    handler.playbackState.add(handler.playbackState.value.copyWith(
      controls: [
        MediaControl.rewind,
        MediaControl.pause,
        MediaControl.fastForward,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek, MediaAction.stop},
      androidCompactActionIndices: const [0, 1, 3], // rewind|pause|stop
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: Duration.zero,
    ));
  }

  void _updateNotificationState() {
    final handler = swiftAudioHandler;
    if (handler == null || !_initialized) return;
    final playing = _video.value.isPlaying;
    handler.playbackState.add(handler.playbackState.value.copyWith(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.stop,
      ],
      androidCompactActionIndices: const [0, 1, 3],
      playing: playing,
      updatePosition: _video.value.position,
    ));
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    setState(() {});
    _updateNotificationState();
    // Auto-stop at end
    if (_video.value.position >= _video.value.duration &&
        _video.value.duration > Duration.zero) {
      _clearNotification();
    }
  }

  void _clearNotification() {
    final handler = swiftAudioHandler;
    if (handler == null) return;
    handler.playbackState.add(handler.playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    handler.mediaItem.add(null);
  }

  // ── App lifecycle — pause video when app goes background ──────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Video visuals pause automatically, but audio continues in background
      // via the foreground service. We keep _video playing so audio continues.
      // The notification shows pause button so user can stop from lock screen.
    } else if (state == AppLifecycleState.resumed) {
      // Nothing to do — video was still playing.
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _video.removeListener(_onVideoUpdate);
    _video.dispose();
    _clearNotification();
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Controls auto-hide ────────────────────────────────────────────────────
  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_error != null) return _buildError();
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Video frame
            if (_initialized)
              Center(
                child: AspectRatio(
                  aspectRatio: _video.value.aspectRatio,
                  child: VideoPlayer(_video),
                ),
              )
            else
              Center(
                child: CircularProgressIndicator(color: OneDarkColors.cyan),
              ),

            // Controls overlay (auto-hide)
            if (_initialized && _showControls) _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final playing = _video.value.isPlaying;
    final position = _video.value.position;
    final duration = _video.value.duration;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // ── Top bar ──────────────────────────────────────────────────────
          SafeArea(
            bottom: false,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      _fileName,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Background playback indicator
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cast_connected,
                            color: Colors.white54, size: 16),
                        SizedBox(width: 4),
                        Text('BG audio',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Center play/pause ────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10,
                    color: Colors.white, size: 36),
                onPressed: () => _video.seekTo(
                    position - const Duration(seconds: 10)),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  color: Colors.white,
                  size: 64,
                ),
                onPressed: () {
                  playing ? _video.pause() : _video.play();
                  _updateNotificationState();
                  _scheduleHide();
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.forward_10,
                    color: Colors.white, size: 36),
                onPressed: () => _video.seekTo(
                    position + const Duration(seconds: 10)),
              ),
            ],
          ),

          // ── Bottom bar ───────────────────────────────────────────────────
          SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xCC000000), Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  // Seek slider
                  SliderTheme(
                    data: SliderThemeData(
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12),
                      trackHeight: 2.5,
                      activeTrackColor: OneDarkColors.cyan,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: (v) {
                        final target = Duration(
                            milliseconds:
                                (v * duration.inMilliseconds).round());
                        _video.seekTo(target);
                      },
                    ),
                  ),
                  // Time row
                  Row(
                    children: [
                      Text(
                        _fmt(position),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12),
                      ),
                      const Text(' / ',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      Text(
                        _fmt(duration),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                      const Spacer(),
                      // Mute
                      IconButton(
                        icon: Icon(
                          _video.value.volume > 0
                              ? Icons.volume_up
                              : Icons.volume_off,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          _video.setVolume(
                              _video.value.volume > 0 ? 0 : 1);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(_fileName,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off, size: 64, color: OneDarkColors.red),
            const SizedBox(height: 16),
            const Text('Playback error',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
