import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';
import '../utils/file_utils.dart' show FileItem;
import '../services/open_with_service.dart';

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
      final home = '/storage/emulated/0';
      // Scan common media directories
      final dirs = [
        '$home/DCIM',
        '$home/Download',
        '$home/Documents',
        '$home/Music',
        '$home/Pictures',
        '$home/Videos',
        '$home/Telegram',
        '$home/WhatsApp',
      ];

      final entries = <_RecentEntry>[];
      for (final dirPath in dirs) {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        try {
          await for (final entity in dir.list(recursive: true)) {
            if (entity is! File) continue;
            try {
              final stat = await entity.stat();
              if (stat.modified.isAfter(cutoff)) {
                entries.add(_RecentEntry(
                  path: entity.path,
                  name: p.basename(entity.path),
                  size: stat.size,
                  modified: stat.modified,
                ));
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

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
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                )
              : _entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.history,
                              size: 48,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          const SizedBox(height: 12),
                          Text('No recent files',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadRecent,
                      child: ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
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
                          return ListTile(
                            leading: Icon(item.icon,
                                color: item.iconColor, size: 28),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_formatSize(entry.size)}  ·  ${_relativeTime(entry.modified)}',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () async {
                              try {
                                await OpenWithService.openDefault(entry.path);
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Cannot open: $e'),
                                      backgroundColor: OneDarkColors.red,
                                    ),
                                  );
                                }
                              }
                            },
                          );
                        },
                      ),
                    ),
    );
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
