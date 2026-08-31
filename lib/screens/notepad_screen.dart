import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../utils/constants.dart' show AppPaths;

/// Notepad screen — create and edit plain text documents.
class NotepadScreen extends StatefulWidget {
  final String? filePath;
  const NotepadScreen({super.key, this.filePath});
  @override
  State<NotepadScreen> createState() => _NotepadScreenState();
}

class _NotepadScreenState extends State<NotepadScreen> {
  late TextEditingController _controller;
  bool _dirty = false;
  String _currentPath = '';
  String _lastSaveDir = '';
  bool _loaded = false;
  /// True for a brand-new document (not opened from a file) — the first Save
  /// runs Save As so the user explicitly chooses name and location, and always
  /// knows where the file lands.
  bool _isNewDocument = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _loadLastDir();
    if (widget.filePath != null) {
      _currentPath = widget.filePath!;
      _loadFile();
    } else {
      _currentPath = p.join(AppPaths.documents, 'untitled.txt');
      _isNewDocument = true;
      _loaded = true;
    }
  }

  Future<void> _loadLastDir() async {
    final prefs = await SharedPreferences.getInstance();
    _lastSaveDir = prefs.getString('notepad_last_dir') ?? AppPaths.documents;
  }

  Future<void> _loadFile() async {
    try {
      final content = await File(_currentPath).readAsString();
      _controller.text = content;
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
  }

  Future<void> _save() async {
    if (_currentPath.isEmpty || _isNewDocument) {
      await _saveAs();
      return;
    }
    try {
      // Ensure the target directory exists before writing — on Android the
      // Documents folder is often created lazily and a missing parent makes
      // the write throw PathNotFoundException.
      final saveDir = p.dirname(_currentPath);
      await Directory(saveDir).create(recursive: true);
      await File(_currentPath).writeAsString(_controller.text);
      // Remember the directory for next time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('notepad_last_dir', saveDir);
      _lastSaveDir = saveDir;
      setState(() => _dirty = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // Show the full path so the user always knows where the file
            // was written (a bare filename made saves feel lost).
            content: Text('Saved to: $_currentPath'),
            backgroundColor: OneDarkColors.green,
          ),
        );
      }
    } catch (e) {
      // The chosen location is unwritable (e.g. scoped storage on Android
      // without MANAGE_EXTERNAL_STORAGE). Fall back to the SwiftFM downloads
      // folder, which is always writable, rather than losing the edit.
      final fallbackDir = AppPaths.swordfmDownloads;
      try {
        await Directory(fallbackDir).create(recursive: true);
        final fallback = p.join(fallbackDir, p.basename(_currentPath));
        await File(fallback).writeAsString(_controller.text);
        _currentPath = fallback;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('notepad_last_dir', fallbackDir);
        _lastSaveDir = fallbackDir;
        setState(() => _dirty = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved to: $fallback'),
              backgroundColor: OneDarkColors.green,
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Save failed: $e'),
              backgroundColor: OneDarkColors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _saveAs() async {
    final nameController = TextEditingController(
      text: _currentPath.isNotEmpty ? p.basename(_currentPath) : 'untitled.txt',
    );
    var saveDir = _lastSaveDir.isNotEmpty ? _lastSaveDir : AppPaths.documents;
    final choice = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: OneDarkColors.bg,
          title: Text('Save As', style: TextStyle(color: OneDarkColors.fg)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                style: TextStyle(color: OneDarkColors.fg),
                decoration: InputDecoration(
                  labelText: 'Filename',
                  suffixText: '.txt',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              // Save location picker — shows the current target directory
              // and lets the user pick a common folder or any custom one.
              InkWell(
                onTap: () async {
                  final picked = await _pickSaveFolder(dialogContext, saveDir);
                  if (picked != null) setDialogState(() => saveDir = picked);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: OneDarkColors.bgDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: OneDarkColors.dim),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.folder, size: 18, color: OneDarkColors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          saveDir,
                          style: TextStyle(
                            color: OneDarkColors.fg,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: OneDarkColors.fgDim),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'name': nameController.text.trim(),
                'dir': saveDir,
              }),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    var name = choice['name'] ?? '';
    if (name.isEmpty) return;
    if (!name.endsWith('.txt')) name = '$name.txt';
    final dir = choice['dir'] ?? AppPaths.documents;
    _currentPath = p.join(dir, name);
    _isNewDocument = false;
    await _save();
  }

  /// Lets the user choose where the text file is saved: the common document
  /// folders, the last-used folder, or any custom directory via file_picker.
  Future<String?> _pickSaveFolder(
    BuildContext dialogContext,
    String current,
  ) async {
    final dirs = <String>{
      current,
      AppPaths.documents,
      AppPaths.downloads,
      AppPaths.home,
    }.toList();
    return showDialog<String>(
      context: dialogContext,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Save to', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...dirs.map(
              (d) => ListTile(
                dense: true,
                leading: Icon(Icons.folder, size: 18, color: OneDarkColors.amber),
                title: Text(
                  d.split('/').last,
                  style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                ),
                subtitle: Text(
                  d,
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
                ),
                onTap: () => Navigator.pop(dialogContext, d),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.create_new_folder, size: 18, color: OneDarkColors.cyan),
              title: Text(
                'Choose other folder…',
                style: TextStyle(color: OneDarkColors.cyan, fontSize: 13),
              ),
              onTap: () async {
                final custom = await FilePicker.getDirectoryPath(
                  dialogTitle: 'Select save folder',
                );
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, custom ?? current);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileName = _currentPath.isNotEmpty
        ? p.basename(_currentPath)
        : 'New Document';
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      appBar: AppBar(
        title: Text(fileName, style: const TextStyle(fontSize: 14)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(
            icon: Icon(
              Icons.save,
              color: _dirty ? OneDarkColors.cyan : OneDarkColors.fgDim,
            ),
            tooltip: 'Save',
            onPressed: _save,
          ),
          IconButton(
            icon: Icon(Icons.save_as, color: OneDarkColors.fgDim),
            tooltip: 'Save As',
            onPressed: _saveAs,
          ),
        ],
      ),
      body: _loaded
          ? TextField(
              controller: _controller,
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: OneDarkColors.fg,
              ),
              decoration: InputDecoration(
                hintText: 'Start typing…',
                hintStyle: TextStyle(
                  color: OneDarkColors.fgDim.withValues(alpha: 0.5),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(16),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
