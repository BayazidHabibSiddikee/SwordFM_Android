import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';
import '../utils/file_utils.dart';

/// Trash screen — lists trashed items with Restore / Empty Trash / Permanent Delete actions.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<FileItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTrash();
  }

  Future<void> _loadTrash() async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await FileUtils.listTrash();
      if (mounted) setState(() { _items = items; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Failed to load trash: $e'; _loading = false; });
    }
  }

  Future<void> _restore(FileItem item) async {
    // Reconstruct original path from trash filename pattern: timestamp_basename
    final originalPath = _originalPath(item.path);
    try {
      await FileUtils.restoreFromTrash(item.path, originalPath);
      if (mounted) _loadTrash();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored: ${item.name}'), backgroundColor: OneDarkColors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e'), backgroundColor: OneDarkColors.red),
        );
      }
    }
  }

  Future<void> _permanentDelete(FileItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Permanently delete "${item.name}"?', style: const TextStyle(color: OneDarkColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: OneDarkColors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await FileUtils.delete(item.path);
        if (mounted) _loadTrash();
      } catch (_) {}
    }
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text('Empty Trash?', style: TextStyle(color: OneDarkColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Empty', style: TextStyle(color: OneDarkColors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await FileUtils.emptyTrash();
      if (mounted) _loadTrash();
    }
  }

  /// Reconstructs the likely original path from a trash entry path.
  /// The trash stores files as `<timestamp>_<original_name>`.
  String _originalPath(String trashPath) {
    final name = p.basename(trashPath);
    final possibleBase = name.replaceFirst(RegExp(r'^\d+_(.+)$'), r'$1');
    final dirs = [AppPaths.home, AppPaths.downloads, AppPaths.documents, AppPaths.desktop, AppPaths.pictures];
    for (final dir in dirs) {
      final candidate = p.join(dir, possibleBase);
      if (File(candidate).existsSync() || Directory(candidate).existsSync()) return candidate;
    }
    return p.join(p.dirname(AppPaths.trash), possibleBase);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Trash', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: OneDarkColors.red),
              onPressed: _emptyTrash,
              tooltip: 'Empty Trash',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
              : _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.delete_outline, size: 48, color: OneDarkColors.fgDim),
                          const SizedBox(height: 12),
                          Text('Trash is empty', style: TextStyle(color: OneDarkColors.fgDim)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          leading: Icon(item.icon, size: 24, color: item.iconColor),
                          title: Text(item.name, style: const TextStyle(color: OneDarkColors.fg)),
                          subtitle: Text(
                            '${item.formattedDate} · ${item.formattedSize}',
                            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.restore, color: OneDarkColors.cyan),
                                onPressed: () => _restore(item),
                                tooltip: 'Restore',
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: OneDarkColors.red),
                                onPressed: () => _permanentDelete(item),
                                tooltip: 'Delete permanently',
                              ),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}
