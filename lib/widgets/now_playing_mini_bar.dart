import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../services/audio_handler.dart';
import '../theme/theme.dart';

/// Compact "now playing" bar pinned above the bottom navigation while audio
/// plays — visible on every tab so background audio is never invisible.
/// Tap opens the full player; ▸/❚❚ toggles playback; ✕ stops it (which also
/// removes the media notification).
class NowPlayingMiniBar extends StatelessWidget {
  final VoidCallback onOpen;
  final VoidCallback onStop;

  const NowPlayingMiniBar({
    super.key,
    required this.onOpen,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final handler = swiftAudioHandler;
    if (handler == null) return const SizedBox.shrink();
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, stateSnap) {
        final playing = stateSnap.data?.playing ?? false;
        return StreamBuilder<MediaItem?>(
          stream: handler.mediaItem,
          builder: (context, itemSnap) {
            final item = itemSnap.data;
            if (item == null) return const SizedBox.shrink();
            return Material(
              color: OneDarkColors.bg,
              child: SafeArea(
                top: false,
                child: InkWell(
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Icon(Icons.music_note,
                            color: OneDarkColors.cyan, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                                color: OneDarkColors.fg, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: playing ? 'Pause' : 'Play',
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            color: OneDarkColors.fg,
                            size: 20,
                          ),
                          onPressed: () =>
                              playing ? handler.pause() : handler.play(),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Stop',
                          icon: Icon(Icons.close,
                              color: OneDarkColors.fgDim, size: 18),
                          onPressed: onStop,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}