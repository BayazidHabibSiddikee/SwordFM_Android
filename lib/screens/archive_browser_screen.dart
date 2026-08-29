import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/archive_service.dart';
import '../services/open_with_service.dart';
import '../theme/theme.dart';

/// Browses a ZIP / TAR archive's contents in place, without extracting the
/// whole archive. Tapping a file extracts just that entry to a temp folder
/// and opens it; long-pressing offers extraction next to the archive.
class ArchiveBrowserScreen extends StatefulWidget {
  final String archivePath;
  const ArchiveBrowserScreen({super.key, required this.archivePath});

  @override
  State<ArchiveBrowserScreen> createState() => _ArchiveBrowserScreenState();
}

class _ArchiveBrowserScreenState extends State<ArchiveBrowserScreen> {
  List<ArchiveEntryInfo> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ArchiveService.listArchiveContents(
        widget.archivePath,
      );
      // Folders first, then alphabetical.
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _extractEntry(ArchiveEntryInfo entry) async {
    try {
      final dir = Directory.systemTemp.createTempSync('swordfm_arc_');
      final outPath = await ArchiveService.extractEntry(
        widget.archivePath,
        entry.name,
        dir.path,
      );
      if (!mounted) return;
      try {
        await OpenWithService.openDefault(outPath);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot open: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extract failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
  }

  Future<void> _extractEntryTo(ArchiveEntryInfo entry) async {
    final destDir = p.join(
      p.dirname(widget.archivePath),
      p.basenameWithoutExtension(widget.archivePath),
    );
    try {
      await ArchiveService.extractEntry(
        widget.archivePath,
        entry.name,
        destDir,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extracted to ${p.basename(destDir)}'),
            backgroundColor: OneDarkColors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extract failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
  }

  Future<void> _extractAll() async {
    final destDir = p.join(
      p.dirname(widget.archivePath),
      p.basenameWithoutExtension(widget.archivePath),
    );
    try {
      await ArchiveService.extract(widget.archivePath, destDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extracted to ${p.basename(destDir)}'),
            backgroundColor: OneDarkColors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extract failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: Text(
          p.basename(widget.archivePath),
          style: TextStyle(color: OneDarkColors.fg, fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(
            icon: const Icon(Icons.unarchive),
            tooltip: 'Extract All',
            onPressed: _extractAll,
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
                  style: TextStyle(color: OneDarkColors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _entries.isEmpty
          ? Center(
              child: Text(
                'Empty archive',
                style: TextStyle(color: OneDarkColors.fgDim),
              ),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final depth = '  ' * entry.name.split('/').length;
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: Icon(
                    entry.isDirectory
                        ? Icons.folder
                        : Icons.insert_drive_file,
                    size: 18,
                    color: entry.isDirectory
                        ? OneDarkColors.cyan
                        : OneDarkColors.fgDim,
                  ),
                  title: Text(
                    '$depth${entry.name.split('/').last}',
                    style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.isDirectory
                      ? null
                      : Text(
                          _formatBytes(entry.size),
                          style: TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                        ),
                  onTap: entry.isDirectory
                      ? null
                      : () => _extractEntry(entry),
                  onLongPress: entry.isDirectory
                      ? null
                      : () => _extractEntryTo(entry),
                );
              },
            ),
    );
  }
}
