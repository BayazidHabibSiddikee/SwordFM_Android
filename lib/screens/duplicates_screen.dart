import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../services/archive_service.dart';
import '../services/device_service.dart';

/// Screen that scans directories for duplicate files based on SHA-256 hash.
class DuplicatesScreen extends StatefulWidget {
  final List<String> scanPaths;
  // Empty means "scan the app home directory" (resolved at scan time so the
  // platform-aware AppPaths values are used on Android).
  const DuplicatesScreen({super.key, this.scanPaths = const []});

  @override
  State<DuplicatesScreen> createState() => _DupsState();
}

class _DupsState extends State<DuplicatesScreen> {
  Map<String, List<String>> _duplicates = {};
  bool _loading = false;
  String? _error;
  int _totalWastedBytes = 0;

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Check full-storage permission first — without it the scan sees
    // only the small scoped sandbox (~1.5 GB) instead of the real 120 GB.
    try {
      final granted = await allFilesAccessGranted();
      if (!granted && mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: OneDarkColors.bg,
            title: Text('Storage access needed',
                style: TextStyle(color: OneDarkColors.fg)),
            content: Text(
              'To scan all files for duplicates, grant "All files access" '
              'in the system screen, then come back and tap Rescan.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Grant Access'),
              ),
            ],
          ),
        );
        if (go == true) await requestAllFilesAccess();
        if (mounted) {
          setState(() => _loading = false);
          return;
        }
      }
    } catch (_) {}
    try {
      final roots = widget.scanPaths.isNotEmpty
          ? widget.scanPaths
          : <String>[AppPaths.home];
      final allPaths = <String>[];
      for (final root in roots) {
        final dir = Directory(root);
        if (!await dir.exists()) continue;
        await _collectFiles(dir, allPaths);
      }
      final result = await ArchiveService.findDuplicates(allPaths);
      if (mounted) {
        // Wasted bytes = sum of every duplicate except the largest one kept.
        int wasted = 0;
        for (final group in result.values) {
          if (group.length < 2) continue;
          int groupBytes = 0;
          int largest = 0;
          for (final path in group) {
            int size = 0;
            try {
              size = await File(path).length();
            } catch (_) {}
            groupBytes += size;
            if (size > largest) largest = size;
          }
          wasted += groupBytes - largest;
        }
        setState(() {
          _duplicates = result;
          _totalWastedBytes = wasted;
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

  /// Recursively collects file paths under [dir] into [out], skipping
  /// unreadable subdirectories instead of aborting the whole scan with a
  /// permission error (Android blocks e.g. Android/data and Android/obb).
  Future<void> _collectFiles(
    Directory dir,
    List<String> out,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = await dir.list().toList();
    } catch (_) {
      return;
    }
    for (final entity in entities) {
      if (entity is Directory) {
        await _collectFiles(entity, out);
      } else if (entity is File) {
        out.add(entity.path);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  void _showContextMenu(String path) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width / 2 - 100,
        MediaQuery.of(context).size.height / 2 - 150,
        MediaQuery.of(context).size.width / 2 + 100,
        MediaQuery.of(context).size.height / 2 + 150,
      ),
      items: [
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(path)),
        _menuItem('Delete', Icons.delete, () => _deleteFile(path)),
        _menuItem(
          'Properties',
          Icons.info_outline,
          () => _showProperties(path),
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
                  await FileUtils.rename(
                    path,
                    p.join(p.dirname(path), newName),
                  );
                  if (mounted) _scan();
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

  Future<void> _deleteFile(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete "${p.basename(path)}"?',
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
        await File(path).delete();
        if (mounted) _scan();
      } catch (_) {}
    }
  }

  void _showProperties(String path) {
    final file = File(path);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          p.basename(path),
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: FutureBuilder<FileStat>(
          future: file.stat(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            final stat = snapshot.data!;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _propRow('Name', p.basename(path)),
                  _propRow('Size', _formatBytes(stat.size)),
                  _propRow(
                    'Modified',
                    DateFormat('yyyy-MM-dd HH:mm').format(stat.modified),
                  ),
                  _propRow('Path', path),
                ],
              ),
            );
          },
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
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
          'Duplicate Files',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _scan,
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
          : _duplicates.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 64,
                    color: OneDarkColors.green,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'No duplicates found',
                    style: TextStyle(color: OneDarkColors.fg, fontSize: 18),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  color: OneDarkColors.bgDark,
                  child: Row(
                    children: [
                      Icon(Icons.info, color: OneDarkColors.amber, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '${_duplicates.length} duplicate group(s) — '
                        'up to ${_formatBytes(_totalWastedBytes)} could be freed',
                        style: TextStyle(color: OneDarkColors.fg),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: _duplicates.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = _duplicates.entries.elementAt(index);
                      return ExpansionTile(
                        leading: Icon(
                          Icons.error_outline,
                          color: OneDarkColors.red,
                        ),
                        title: Text(
                          '${entry.value.length} files (${_formatBytes(entry.value.first.length)})',
                          style: TextStyle(color: OneDarkColors.fg),
                        ),
                        subtitle: Text(
                          p.basename(entry.value.first),
                          style: TextStyle(color: OneDarkColors.fgDim),
                        ),
                        children: entry.value.map((path) {
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.insert_drive_file,
                              size: 16,
                              color: OneDarkColors.fgDim,
                            ),
                            title: Text(
                              path,
                              style: TextStyle(
                                color: OneDarkColors.fg,
                                fontSize: 12,
                              ),
                            ),
                            subtitle: Text(
                              p.dirname(path),
                              style: TextStyle(
                                color: OneDarkColors.fgDim,
                                fontSize: 10,
                              ),
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                color: OneDarkColors.red,
                              ),
                              onPressed: () => _deleteFile(path),
                              tooltip: 'Delete',
                            ),
                            onLongPress: () => _showContextMenu(path),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
