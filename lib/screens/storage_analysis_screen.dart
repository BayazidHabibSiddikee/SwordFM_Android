import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';

/// Storage analysis screen — shows disk usage breakdown by folder size.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

class StorageAnalysisScreen extends StatefulWidget {
  final String rootPath;
  const StorageAnalysisScreen({super.key, this.rootPath = '/'});

  @override
  State<StorageAnalysisScreen> createState() => _StorageAnalysisScreenState();
}

class _StorageAnalysisScreenState extends State<StorageAnalysisScreen> {
  List<_FolderSize> _entries = [];
  bool _loading = true;
  String? _error;
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _scan(widget.rootPath);
  }

  Future<void> _scan(String path) async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await _collectSizes(Directory(path), path);
      if (mounted) {
        setState(() {
          _entries = results;
          _totalBytes = results.fold(0, (s, e) => s + e.size);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Scan failed: $e'; _loading = false; });
    }
  }

  /// Recursively collect folder sizes, capping depth at 3 to keep scan fast.
  Future<List<_FolderSize>> _collectSizes(Directory dir, String rootPath, [int depth = 0]) async {
    if (depth > 3) return [];
    final children = await dir.list().toList();
    final results = <_FolderSize>[];
    for (final entity in children) {
      if (entity is Directory) {
        final subItems = await _collectSizes(entity, rootPath, depth + 1);
        int total = subItems.fold(0, (s, e) => s + e.size);
        // Also include direct files in this dir
        for (final child in entity.listSync()) {
          if (child is File) total += child.lengthSync();
        }
        results.add(_FolderSize(entity.path, total, subItems));
      }
    }
    results.sort((a, b) => b.size.compareTo(a.size));
    return results;
  }

  void _navigateTo(String path) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => StorageAnalysisScreen(rootPath: path),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Storage Analysis', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _scan(widget.rootPath),
            tooltip: 'Rescan',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
              : Column(
                  children: [
                    // Summary bar
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: OneDarkColors.bgDark,
                      child: Row(
                        children: [
                          Icon(Icons.storage, color: OneDarkColors.cyan, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Total: ${_formatBytes(_totalBytes)}',
                            style: const TextStyle(color: OneDarkColors.fg, fontSize: 14),
                          ),
                          const Spacer(),
                          Text(
                            widget.rootPath,
                            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // Folder list
                    Expanded(
                      child: _entries.isEmpty
                          ? Center(child: Text('No subfolders found', style: TextStyle(color: OneDarkColors.fgDim)))
                          : ListView.separated(
                              itemCount: _entries.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final entry = _entries[index];
                                final pct = _totalBytes > 0 ? entry.size / _totalBytes : 0.0;
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: OneDarkColors.dim,
                                    child: Icon(Icons.folder, size: 18, color: OneDarkColors.amber),
                                  ),
                                  title: Text(
                                    p.basename(entry.path),
                                    style: const TextStyle(color: OneDarkColors.fg),
                                  ),
                                  subtitle: LinearProgressIndicator(
                                    value: pct,
                                    minHeight: 4,
                                    backgroundColor: OneDarkColors.dim,
                                    valueColor: AlwaysStoppedAnimation<Color>(OneDarkColors.cyan),
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        _formatBytes(entry.size),
                                        style: const TextStyle(color: OneDarkColors.fg, fontWeight: FontWeight.w600),
                                      ),
                                      Text(
                                        '${(pct * 100).toStringAsFixed(1)}%',
                                        style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _navigateTo(entry.path),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _FolderSize {
  final String path;
  final int size;
  final List<_FolderSize> children;
  const _FolderSize(this.path, this.size, this.children);
}
