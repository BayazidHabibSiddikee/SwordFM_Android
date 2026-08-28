import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';

/// Storage analysis screen — shows disk usage breakdown by folder size.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
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
    setState(() {
      _loading = true;
      _error = null;
    });
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
      if (mounted)
        setState(() {
          _error = 'Scan failed: $e';
          _loading = false;
        });
    }
  }

  /// Recursively collect folder sizes, capping depth at 3 to keep scan fast.
  Future<List<_FolderSize>> _collectSizes(
    Directory dir,
    String rootPath, [
    int depth = 0,
  ]) async {
    if (depth > 3) return [];
    List<FileSystemEntity> children;
    try {
      children = await dir.list().toList();
    } catch (_) {
      return []; // skip inaccessible directories
    }
    final results = <_FolderSize>[];
    for (final entity in children) {
      if (entity is Directory) {
        if (_isRestrictedPath(entity.path)) continue;
        List<_FolderSize> subItems;
        try {
          subItems = await _collectSizes(entity, rootPath, depth + 1);
        } catch (_) {
          subItems = []; // one bad subfolder must not fail the whole scan
        }
        int total = subItems.fold(0, (s, e) => s + e.size);
        // Also include direct files in this dir
        try {
          for (final child in entity.listSync()) {
            if (child is File) {
              try {
                total += child.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
        results.add(_FolderSize(entity.path, total, subItems));
      }
    }
    results.sort((a, b) => b.size.compareTo(a.size));
    return results;
  }

  /// Android forbids listing these without special permissions; skip them
  /// instead of letting the whole scan fail with PathAccessException.
  static bool _isRestrictedPath(String path) {
    final segments = path.split('/');
    if (!segments.contains('Android')) return false;
    return segments.contains('data') || segments.contains('obb');
  }

  void _navigateTo(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StorageAnalysisScreen(rootPath: path)),
    );
  }

  void _showContextMenu(_FolderSize entry) {
    final hasItems = entry.children.isNotEmpty;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width / 2 - 100,
        MediaQuery.of(context).size.height / 2 - 150,
        MediaQuery.of(context).size.width / 2 + 100,
        MediaQuery.of(context).size.height / 2 + 150,
      ),
      items: [
        _menuItem('Open', Icons.folder_open, () => _navigateTo(entry.path)),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(entry.path)),
        if (hasItems)
          _menuItem(
            'Delete All',
            Icons.delete_sweep,
            () => _deleteFolder(entry),
          ),
        _menuItem(
          'Properties',
          Icons.info_outline,
          () => _showProperties(entry),
        ),
      ],
    );
  }

  PopupMenuItem<Object?> _menuItem(
    String title,
    IconData icon,
    VoidCallback onTap,
  ) {
    return PopupMenuItem<Object?>(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18, color: OneDarkColors.fg),
          const SizedBox(width: 12),
          Text(title, style: TextStyle(color: OneDarkColors.fg)),
        ],
      ),
    );
  }

  void _showRenameDialog(String path) {
    final controller = TextEditingController(text: p.basename(path));
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (!mounted) return;
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != p.basename(path)) {
                try {
                  final newPath = p.join(p.dirname(path), newName);
                  await Directory(path).rename(newPath);
                  if (mounted) _scan(p.dirname(path));
                } catch (_) {}
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFolder(_FolderSize entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete "${p.basename(entry.path)}" and all contents?',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: OneDarkColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await Directory(entry.path).delete(recursive: true);
        if (mounted) _scan(widget.rootPath);
      } catch (_) {}
    }
  }

  void _showProperties(_FolderSize entry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          p.basename(entry.path),
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _propRow('Name', p.basename(entry.path)),
              _propRow('Path', entry.path),
              _propRow('Size', _formatBytes(entry.size)),
              _propRow('Subfolders', '${entry.children.length}'),
              _propRow(
                'Total items',
                '${entry.children.fold(0, (s, e) => s + 1 + e.children.length)} est.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _propRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: Text(
          'Storage Analysis',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
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
          ? Center(
              child: Text(_error!, style: TextStyle(color: OneDarkColors.red)),
            )
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  color: OneDarkColors.bgDark,
                  child: Row(
                    children: [
                      Icon(Icons.storage, color: OneDarkColors.cyan, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Total: ${_formatBytes(_totalBytes)}',
                        style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
                      ),
                      const Spacer(),
                      Text(
                        widget.rootPath,
                        style: TextStyle(
                          color: OneDarkColors.fgDim,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _entries.isEmpty
                      ? Center(
                          child: Text(
                            'No subfolders found',
                            style: TextStyle(color: OneDarkColors.fgDim),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final entry = _entries[index];
                            final pct = _totalBytes > 0
                                ? entry.size / _totalBytes
                                : 0.0;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: OneDarkColors.dim,
                                child: Icon(
                                  Icons.folder,
                                  size: 18,
                                  color: OneDarkColors.amber,
                                ),
                              ),
                              title: Text(
                                p.basename(entry.path),
                                style: TextStyle(color: OneDarkColors.fg),
                              ),
                              subtitle: LinearProgressIndicator(
                                value: pct,
                                minHeight: 4,
                                backgroundColor: OneDarkColors.dim,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  OneDarkColors.cyan,
                                ),
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _formatBytes(entry.size),
                                    style: TextStyle(
                                      color: OneDarkColors.fg,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${(pct * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      color: OneDarkColors.fgDim,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () => _navigateTo(entry.path),
                              onLongPress: () => _showContextMenu(entry),
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
