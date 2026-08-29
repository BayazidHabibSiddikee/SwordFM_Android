import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../theme/theme.dart';

/// Full-screen video player with basic controls.
class VideoPlayerScreen extends StatefulWidget {
  final String filePath;
  const VideoPlayerScreen({super.key, required this.filePath});
  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller =
        VideoPlayerController.file(
            File(widget.filePath),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          )
          ..initialize()
              .then((_) {
                if (mounted) setState(() => _initialized = true);
                _controller.play();
              })
              .catchError((e) {
                if (mounted) setState(() => _error = e.toString());
              });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error, size: 48, color: OneDarkColors.red),
                  const SizedBox(height: 12),
                  Text(
                    'Playback error',
                    style: TextStyle(color: OneDarkColors.fg),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                ],
              ),
            )
          : !_initialized
          ? Center(child: CircularProgressIndicator(color: OneDarkColors.cyan))
          : GestureDetector(
              onTap: () => setState(() => _showControls = !_showControls),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                  if (_showControls)
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black54,
                            Colors.transparent,
                            Colors.black54,
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top bar
                          SafeArea(
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_back,
                                    color: Colors.white,
                                  ),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                Expanded(
                                  child: Text(
                                    widget.filePath.split('/').last,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Center play/pause
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: Icon(
                                  _controller.value.isPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  size: 64,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  _controller.value.isPlaying
                                      ? _controller.pause()
                                      : _controller.play();
                                },
                              ),
                            ],
                          ),
                          // Bottom controls
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                // Progress bar
                                VideoProgressIndicator(
                                  _controller,
                                  allowScrubbing: true,
                                  colors: VideoProgressColors(
                                    playedColor: OneDarkColors.cyan,
                                    bufferedColor: OneDarkColors.fgDim,
                                    backgroundColor: OneDarkColors.border,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Time + buttons
                                Row(
                                  children: [
                                    Text(
                                      _format(_controller.value.position),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const Text(
                                      ' / ',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      _format(_controller.value.duration),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.replay_10,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      onPressed: () => _controller.seekTo(
                                        _controller.value.position -
                                            const Duration(seconds: 10),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.forward_10,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      onPressed: () => _controller.seekTo(
                                        _controller.value.position +
                                            const Duration(seconds: 10),
                                      ),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        _controller.value.volume > 0
                                            ? Icons.volume_up
                                            : Icons.volume_off,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        _controller.setVolume(
                                          _controller.value.volume > 0 ? 0 : 1,
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
