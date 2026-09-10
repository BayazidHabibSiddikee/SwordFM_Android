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
import 'pdf_reader_screen.dart';
import 'docx_reader_screen.dart';
import 'image_viewer_screen.dart';

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
      // 30-day window so academic files (sessionals, lab reports, scanned
      // coursework from a couple weeks ago) still surface. The original
      // 7-day window was tuned for media folders where anything older is
      // noise; on a Documents tree it actively hides the files the user
      // is most likely to want. Cap is still result-bounded at 500, so
      // the wider window doesn't slow the scan.
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
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
          _error = 'Couldn\'t load recent files -- please try again';
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
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadRecent,
          ),
        ],
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
                  const SizedBox(height: 8),
                  Text(
                    'Files you open appear here.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
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
                    child: _buildEntryList(),
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
                    child: _buildEntryList(),
                  ),
                ),
                // Expanded -- PreviewPanel sizes itself with a Column+Expanded,
                // so a null/loose height constraint crashes the layout
                // ("RenderFlex children have non-zero flex…") the moment a
                // preview item is tapped on phones.
                if (_previewItem != null)
                  Expanded(
                    child: PreviewPanel(
                      item: _previewItem,
                      width: double.infinity,
                      onClose: () => setState(() => _previewItem = null),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Shared ListView so the wide and narrow layouts stay in lockstep.
  Widget _buildEntryList() {
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildEntryTile(_entries[index]),
    );
  }

  Widget _buildEntryTile(_RecentEntry entry) {
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
    final dimColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final selColor =
        Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2);
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
        style: TextStyle(color: dimColor, fontSize: 12),
      ),
      trailing: Text(
        _relativeTime(entry.modified),
        style: TextStyle(color: dimColor, fontSize: 12),
      ),
      selected: isSel,
      selectedTileColor: selColor,
      onTap: () => _openEntry(item),
    );
  }

  /// Taps a recent entry: video/audio open in the built-in players, anything
  /// else shows the preview panel. If the file no longer exists (deleted
  /// between scan and tap, or not readable under scoped storage), a SnackBar
  /// explains the situation instead of letting the player crash.
  Future<void> _openEntry(FileItem item) async {
    final file = File(item.path);
    // Capture the navigator / messenger before the await so we don't reach
    // back into a disposed context if the screen is closing.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await file.exists()) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('"${item.name}" no longer exists.'),
          action: SnackBarAction(
            label: 'Refresh',
            onPressed: _loadRecent,
          ),
        ),
      );
      return;
    }
    final ext = item.extension.toLowerCase();
    if (kVideoExtensions.contains(ext)) {
      // Auto-next across all recent videos (sibling-fire-and-remember).
      final playlist = _entries
          .where((r) => kVideoExtensions.contains(p.extension(r.path).toLowerCase()))
          .map((r) => r.path)
          .toList();
      final index = playlist.indexOf(item.path);
      navigator.push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            filePath: item.path,
            playlist: playlist,
            initialIndex: index < 0 ? 0 : index,
          ),
        ),
      );
      return;
    }
    if (kAudioExtensions.contains(ext)) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => MusicPlayerScreen(filePath: item.path),
        ),
      );
      return;
    }
    // PDF → built-in fullscreen reader (pinch-zoom, page nav). The preview
    // panel alone buries a document behind an extra tap on phones.
    if (ext == '.pdf') {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => PdfReaderScreen(filePath: item.path),
        ),
      );
      return;
    }
    // DOCX → built-in fullscreen reader.
    if (ext == '.docx') {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => DocxReaderScreen(filePath: item.path),
        ),
      );
      return;
    }
    // Images → built-in fullscreen pinch-zoom viewer.
    if (item.isImage) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(filePath: item.path),
        ),
      );
      return;
    }
    if (mounted) setState(() => _previewItem = item);
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
/// Runs inside a background isolate: sync I/O, depth-capped (5 levels) and
/// result-capped (500 entries) so the scan always terminates quickly.
///
/// Depth 5 covers realistic user trees like
/// `Documents/Study/University/3-2/Sessionals/ME 3256/file.pdf` (5 subdirs)
/// from the source folder; bumping past 3 unblocks the study folder where
/// Sessionals live 4 levels down. Result cap stays at 500 so a phone with
/// a huge media tree still returns in well under a second.
List<Map<String, Object>> _scanRecent(List<String> dirs, int cutoffMs) {
  final cutoff = DateTime.fromMillisecondsSinceEpoch(cutoffMs);
  final entries = <Map<String, Object>>[];
  const maxEntries = 500;
  const maxDepth = 5;

  void scan(String dirPath, int depth) {
    if (entries.length >= maxEntries) return;
    List<FileSystemEntity> children;
    try {
      children = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      return; // unreadable directory -- skip
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
