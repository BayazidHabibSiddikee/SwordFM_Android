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

  void _showContextMenu(FileItem item) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width / 2 - 100,
        MediaQuery.of(context).size.height / 2 - 150,
        MediaQuery.of(context).size.width / 2 + 100,
        MediaQuery.of(context).size.height / 2 + 150,
      ),
      items: [
        _menuItem('Restore', Icons.restore, () => _restore(item)),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(item)),
        _menuItem('Delete permanently', Icons.delete_forever, () => _permanentDelete(item)),
        _menuItem('Properties', Icons.info_outline, () => _showProperties(item)),
      ],
    );
  }

  PopupMenuItem<Object?> _menuItem(String title, IconData icon, VoidCallback onTap) {
    return PopupMenuItem<Object?>(onTap: onTap, child: Row(children: [
      Icon(icon, size: 18, color: OneDarkColors.fg),
      const SizedBox(width: 12),
      Text(title, style: const TextStyle(color: OneDarkColors.fg)),
    ]));
  }

  void _showRenameDialog(FileItem item) {
    final controller = TextEditingController(text: item.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(controller: controller, style: const TextStyle(color: OneDarkColors.fg), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (!mounted) return;
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != item.name) {
                try {
                  await FileUtils.rename(item.path, newName);
                  if (mounted) _loadTrash();
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

  void _showProperties(FileItem item) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(item.name, style: const TextStyle(color: OneDarkColors.fg)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _propRow('Name', item.name),
              _propRow('Type', item.isDirectory ? 'Folder' : (item.extension.isNotEmpty ? item.extension.toUpperCase().replaceAll('.', '') : 'File')),
              _propRow('Size', item.formattedSize),
              _propRow('Modified', item.formattedDate),
              _propRow('Path', item.path),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  Widget _propRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
        Expanded(child: Text(value, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12))),
      ]),
    );
  }

  /// Reconstructs the likely original path from a trash entry path.
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
                          onLongPress: () => _showContextMenu(item),
                        );
                      },
                    ),
    );
  }
}
