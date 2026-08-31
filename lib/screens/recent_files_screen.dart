import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../utils/file_utils.dart'
    show FileItem, kAudioExtensions, kVideoExtensions;
import '../utils/constants.dart' show AppPaths;
import '../widgets/preview_panel.dart';
import 'video_player_screen.dart';
import 'music_player_screen.dart';

/// Shows recently modified files across common storage directories,
/// similar to the "Recent" category in Google Files.
class RecentFilesScreen extends StatefulWidget {
  const RecentFilesScreen({super.key});

  @override
  State<RecentFilesScreen> createState() => _RecentFilesScreenState();
}

class _RecentFilesScreenState extends State<RecentFilesScreen> {
  List<_RecentEntry> _entries = [];
  bool _loading = true;
  String? _error;
  FileItem? _previewItem;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      final home = AppPaths.home;
      // Scan common media directories (resolved via AppPaths so the screen
      // also works on the Linux desktop build).
      final dirs = [
        AppPaths.pictures,
        AppPaths.downloads,
        AppPaths.documents,
        AppPaths.music,
        AppPaths.videos,
        '$home/DCIM',
        '$home/Telegram',
        '$home/WhatsApp',
      ];

      // Run the recursive scan in a background isolate: on-device media
      // folders hold thousands of files and scanning on the UI isolate froze
      // the app. The isolate uses sync I/O (cheap there) with a depth cap and
      // a result cap so even huge trees return quickly.
      final rawEntries = await Isolate.run(
        () => _scanRecent(dirs, cutoff.millisecondsSinceEpoch),
      );
      final entries = rawEntries
          .map(
            (e) => _RecentEntry(
              path: e['path']! as String,
              name: p.basename(e['path']! as String),
              size: e['size']! as int,
              modified: DateTime.fromMillisecondsSinceEpoch(
                e['modified']! as int,
              ),
            ),
          )
          .toList();

      // Sort newest first
      entries.sort((a, b) => b.modified.compareTo(a.modified));

      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load recent files: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent Files'),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            )
          : _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No recent files',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : isWide
          ? Row(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadRecent,
                    child: ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        final file = File(entry.path);
                        final item = FileItem(
                          entity: file,
                          name: entry.name,
                          path: entry.path,
                          isDirectory: false,
                          size: entry.size,
                          lastModified: entry.modified,
                        );
                        final isSel = _previewItem?.path == entry.path;
                        return ListTile(
                          leading: Icon(
                            item.icon,
                            color: item.iconColor,
                            size: 28,
                          ),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _formatSize(entry.size),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Text(
                            _relativeTime(entry.modified),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          selected: isSel,
                          selectedTileColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withValues(alpha: 0.2),
                          onTap: () {
                            _openEntry(item);
                          },
                        );
                      },
                    ),
                  ),
                ),
                if (_previewItem != null)
                  PreviewPanel(
                    item: _previewItem,
                    width: 460,
                    onClose: () => setState(() => _previewItem = null),
                  ),
              ],
            )
          : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadRecent,
                    child: ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        final file = File(entry.path);
                        final item = FileItem(
                          entity: file,
                          name: entry.name,
                          path: entry.path,
                          isDirectory: false,
                          size: entry.size,
                          lastModified: entry.modified,
                        );
                        final isSel = _previewItem?.path == entry.path;
                        return ListTile(
                          leading: Icon(
                            item.icon,
                            color: item.iconColor,
                            size: 28,
                          ),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _formatSize(entry.size),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Text(
                            _relativeTime(entry.modified),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          selected: isSel,
                          selectedTileColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withValues(alpha: 0.2),
                          onTap: () {
                            _openEntry(item);
                          },
                        );
                      },
                    ),
                  ),
                ),
                if (_previewItem != null)
                  PreviewPanel(
                    item: _previewItem,
                    width: double.infinity,
                    height: null, // let it grow to fill remaining column space
                    onClose: () => setState(() => _previewItem = null),
                  ),
              ],
            ),
    );
  }

  /// Taps a recent entry: video/audio open in the built-in players, anything
  /// else shows the preview panel.
  void _openEntry(FileItem item) {
    final ext = item.extension.toLowerCase();
    if (kVideoExtensions.contains(ext)) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(filePath: item.path),
        ),
      );
      return;
    }
    if (kAudioExtensions.contains(ext)) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MusicPlayerScreen(filePath: item.path),
        ),
      );
      return;
    }
    setState(() => _previewItem = item);
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MMM d').format(dt);
  }
}

/// Scans [dirs] recursively for files modified after [cutoffMs].
/// Runs inside a background isolate: sync I/O, depth-capped (3 levels) and
/// result-capped (500 entries) so the scan always terminates quickly.
List<Map<String, Object>> _scanRecent(List<String> dirs, int cutoffMs) {
  final cutoff = DateTime.fromMillisecondsSinceEpoch(cutoffMs);
  final entries = <Map<String, Object>>[];
  const maxEntries = 500;
  const maxDepth = 3;

  void scan(String dirPath, int depth) {
    if (entries.length >= maxEntries) return;
    List<FileSystemEntity> children;
    try {
      children = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      return; // unreadable directory — skip
    }
    for (final entity in children) {
      if (entries.length >= maxEntries) return;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      if (entity is Directory) {
        if (depth < maxDepth) scan(entity.path, depth + 1);
        continue;
      }
      try {
        final stat = entity.statSync();
        if (stat.modified.isAfter(cutoff)) {
          entries.add({
            'path': entity.path,
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch,
          });
        }
      } catch (_) {}
    }
  }

  for (final dir in dirs) {
    scan(dir, 0);
  }
  return entries;
}

class _RecentEntry {
  final String path;
  final String name;
  final int size;
  final DateTime modified;

  const _RecentEntry({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });
}
