import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/archive_service.dart';
import '../theme/theme.dart';

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

/// Screen that scans directories for duplicate files based on SHA-256 hash.
class DuplicatesScreen extends StatefulWidget {
  final List<String> scanPaths;
  const DuplicatesScreen({super.key, this.scanPaths = const ['/home', '/home/user/Downloads']});

  @override
  State<DuplicatesScreen> createState() => _DupsState();
}

class _DupsState extends State<DuplicatesScreen> {
  Map<String, List<String>> _duplicates = {};
  bool _loading = false;
  String? _error;
  int _totalWastedBytes = 0;

  Future<void> _scan() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Collect all file paths under scan dirs
      final allPaths = <String>[];
      for (final root in widget.scanPaths) {
        final dir = Directory(root);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) allPaths.add(entity.path);
        }
      }
      final result = await ArchiveService.findDuplicates(allPaths);
      if (mounted) {
        int wasted = 0;
        for (final group in result.values) {
          wasted += group.length > 1 ? group.length - 1 : 0;
        }
        setState(() {
          _duplicates = result;
          _totalWastedBytes = wasted;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Scan failed: $e'; _loading = false; });
    }
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Duplicate Files', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _scan, tooltip: 'Rescan'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
              : _duplicates.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle, size: 64, color: OneDarkColors.green),
                          SizedBox(height: 16),
                          Text('No duplicates found', style: TextStyle(color: OneDarkColors.fg, fontSize: 18)),
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
                                'up to ${_fmtBytes(_totalWastedBytes)} could be freed',
                                style: const TextStyle(color: OneDarkColors.fg),
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
                                leading: Icon(Icons.error_outline, color: OneDarkColors.red),
                                title: Text(
                                  '${entry.value.length} files (${_fmtBytes(entry.value.first.length)})',
                                  style: const TextStyle(color: OneDarkColors.fg),
                                ),
                                subtitle: Text(p.basename(entry.value.first),
                                    style: const TextStyle(color: OneDarkColors.fgDim)),
                                children: entry.value.map((path) {
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.insert_drive_file, size: 16, color: OneDarkColors.fgDim),
                                    title: Text(path, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12)),
                                    subtitle: Text(p.dirname(path), style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 10)),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline, color: OneDarkColors.red),
                                      onPressed: () async {
                                        await File(path).delete();
                                        if (mounted) _scan();
                                      },
                                      tooltip: 'Delete',
                                    ),
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
