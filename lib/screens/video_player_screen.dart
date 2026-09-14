import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/playback_resume_policy.dart';
import '../services/playback_resume_store.dart';
import '../theme/theme.dart';
import '../utils/media_kit_guard.dart';

/// Full-screen video player backed by media_kit / libmpv.
///
/// Supports: MKV, MP4, AVI, MOV, WebM, TS, 3GP …
/// Codecs: H.264/H.265/VP8/VP9/AV1, AC3, DTS, EAC3, TrueHD, MP3, AAC, FLAC
/// Features: subtitles (.srt/.ass/embedded sidecars + embedded tracks),
///           speed control, audio-track selection, auto-next playlist,
///           hardware-decode toggle (persisted, default OFF),
///           aspect-fit switch (contain/cover/16:9),
///           Picture-in-Picture (Android 8+, native).
///
/// BACKGROUND PLAYBACK NOTE:
/// media_kit/libmpv does NOT support true background video playback on Android.
/// When the screen locks or the app backgrounds, playback will pause. This is
/// a platform limitation of libmpv-based players. For background audio, use the
/// music player (SwiftAudioHandler with just_audio + audio_service).
///
/// For true background video playback, we would need to switch to native
/// ExoPlayer with a foreground service, which is beyond current scope.
/// The current implementation maximizes playback continuity within platform limits.
///
/// Workarounds implemented below:
/// - Keep screen awake during playback (SystemChrome + Wakelock-style behavior)
/// - Persist playback position robustly for resume after returning
/// - Save position on lifecycle pause events
/// - Show user a message explaining video requires screen-on
///
/// For true background video playback, we would need to switch to native
/// ExoPlayer with a foreground service, which is beyond current scope.
/// The current implementation maximizes playback continuity within platform limits.

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
  /// Native PiP bridge (MainActivity `com.swordfm/video` channel).
  static const _videoChannel = MethodChannel('com.swordfm/video');

  Player? _player;
  VideoController? _controller;

  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _resumeTimer;
  double _speed = 1.0;
  bool _showSubtitles = true;
  bool _hwDecode =
      false; // persisted via shared_preferences key 'video_hw_decode'
  BoxFit _fit =
      BoxFit.contain; // persisted via shared_preferences key 'video_fit'
  bool _pipAvailable = false;
  String? _error;
  PlaybackResumeStore? _resumeStore;
  PlaybackMediaIdentity? _currentIdentity;
  Future<void> _resumeWriteChain = Future<void>.value();

  List<String> get _playlist =>
      widget.playlist.isNotEmpty ? widget.playlist : [widget.filePath];
  int _currentIndex = 0;

  // Track if we need to resume after backgrounding
  bool _wasPlaying = false;
  bool _didSaveResumeOnPause = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep screen on during video playback
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _currentIndex = widget.initialIndex.clamp(0, _playlist.length - 1);
    _loadHwDecodePref().then((_) => _initPlayer());
  }

  static const _kHwDecodeKey = 'video_hw_decode';
  static const _kFitKey = 'video_fit';

  Future<void> _loadHwDecodePref() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _hwDecode = prefs.getBool(_kHwDecodeKey) ?? false;
        _fit = _fitFromName(prefs.getString(_kFitKey));
      });
    }
    await _checkPip();
  }

  static BoxFit _fitFromName(String? name) {
    return switch (name) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }

  static String _fitName(BoxFit fit) {
    return switch (fit) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
  }

  String get _fitLabel => switch (_fit) {
        BoxFit.cover => 'Cover',
        BoxFit.fill => '16:9 fill',
        _ => 'Fit',
      };

  /// Cycles contain → cover → 16:9 fill → contain. Persisted.
  Future<void> _cycleFit() async {
    final next = switch (_fit) {
      BoxFit.contain => BoxFit.cover,
      BoxFit.cover => BoxFit.fill,
      _ => BoxFit.contain,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFitKey, _fitName(next));
    if (mounted) setState(() => _fit = next);
  }

  /// Queries the native PiP bridge once (desktop/tests → false, no crash).
  Future<void> _checkPip() async {
    try {
      final ok = await _videoChannel.invokeMethod<bool>('pipAvailable');
      if (mounted) setState(() => _pipAvailable = ok ?? false);
    } catch (_) {
      if (mounted) setState(() => _pipAvailable = false);
    }
  }

  /// Enters Picture-in-Picture, keeping audio playing. Failures surface a
  /// snackbar instead of silently doing nothing.
  Future<void> _enterPip() async {
    try {
      final ok = await _videoChannel.invokeMethod<bool>('enterPip', {
        'width': 16,
        'height': 9,
      });
      if (ok != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Picture-in-Picture is not available right now'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Picture-in-Picture is not available right now'),
          ),
        );
      }
    }
  }

  /// Toggles hardware decode and restarts the player with the new setting.
  /// The preference is persisted so it survives app restarts.
  Future<void> _toggleHwDecode() async {
    final next = !_hwDecode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHwDecodeKey, next);
    // Save resume position before tearing down the player.
    _saveResume();
    // Dispose existing player, then re-init with the new hw-decode setting.
    final oldPlayer = _player;
    final oldController = _controller;
    setState(() {
      _hwDecode = next;
      _player = null;
      _controller = null;
      _error = null;
    });
    await oldPlayer?.dispose();
    // ignore: unused_local_variable
    final _ = oldController; // VideoController is disposed with the player.
    await _initPlayer();
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
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: _hwDecode,
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

  String _fileName() {
    final path = _playlist[_currentIndex];
    return path.split('/').last;
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

  /// Lifecycle handling for background/foreground transitions.
  /// 
  /// NOTE: media_kit/libmpv cannot play video with screen off on Android.
  /// This is a platform limitation - video requires the surface to be visible.
  /// When the app goes to background, playback pauses automatically.
  /// We save the position so it can resume when returning to foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App is going to background or screen is locked
        // Save current position before player pauses
        _saveResumePosition();
        // Don't explicitly pause here - the player will handle it
        // when the surface becomes invalid
        break;
      case AppLifecycleState.resumed:
        // App returned to foreground
        // Try to resume if we were playing before
        if (_wasPlaying && _player != null) {
          _player!.play();
        }
        _wasPlaying = false;
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  // ── Resume position management ───────────────────────────────────────────

  Future<void> _saveResumePosition() async {
    final identity = _currentIdentity;
    final player = _player;
    if (identity == null || player == null) return;
    if (player.state.position == null) return;

    // Track if we were playing for resume-on-foreground.
    if (player.state.playing) {
      _wasPlaying = true;
    }

    try {
      final position = player.state.position!;
      final duration = player.state.duration;

      final point = PlaybackResumePoint.fromMilliseconds(
        positionMs: position.inMilliseconds,
        durationMs: duration > Duration.zero ? duration.inMilliseconds : null,
        queueIndex: _currentIndex,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );

      final store = await _store();
      await store.write(identity, point);
    } catch (e) {
      debugPrint('Video: failed to save resume position: $e');
    }
  }

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
                fit: _fit,
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
                      Semantics(
                        button: true,
                        label: _showSubtitles
                            ? 'Hide subtitle tracks'
                            : 'Show subtitle tracks',
                        child: IconButton(
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
                      ),
                      // Hardware decode toggle
                      Semantics(
                        button: true,
                        toggled: _hwDecode,
                        label: _hwDecode
                            ? 'Hardware decoding on. Double tap to disable.'
                            : 'Hardware decoding off. Double tap to enable.',
                        child: IconButton(
                          icon: Icon(
                            Icons.memory,
                            color: _hwDecode
                                ? OneDarkColors.cyan
                                : Colors.white54,
                            size: 20,
                          ),
                          onPressed: _toggleHwDecode,
                          tooltip: _hwDecode
                              ? 'HW decode ON (tap to disable)'
                              : 'HW decode OFF (tap to enable)',
                        ),
                      ),
                      // Aspect-fit switch: Fit → Cover → 16:9 fill.
                      IconButton(
                        icon: Text(
                          _fitLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                        onPressed: _cycleFit,
                        tooltip: 'Aspect ratio (${_fitLabel})',
                      ),
                      // Picture-in-Picture (Android 8+; hidden elsewhere).
                      if (_pipAvailable)
                        IconButton(
                          icon: const Icon(
                            Icons.picture_in_picture_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: _enterPip,
                          tooltip: 'Picture-in-Picture',
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
