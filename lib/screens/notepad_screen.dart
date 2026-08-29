import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../theme/theme.dart';
import '../utils/file_utils.dart';

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
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    if (widget.filePath != null) {
      _currentPath = widget.filePath!;
      _loadFile();
    } else {
      _loaded = true;
    }
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
    if (_currentPath.isEmpty) {
      await _saveAs();
      return;
    }
    try {
      await File(_currentPath).writeAsString(_controller.text);
      setState(() => _dirty = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved: ${p.basename(_currentPath)}'),
            backgroundColor: OneDarkColors.green,
          ),
        );
      }
    } catch (e) {
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

  Future<void> _saveAs() async {
    final nameController = TextEditingController(
      text: _currentPath.isNotEmpty ? p.basename(_currentPath) : 'untitled.txt',
    );
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Save As', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: nameController,
          style: TextStyle(color: OneDarkColors.fg),
          decoration: const InputDecoration(
            labelText: 'Filename',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == null || choice.isEmpty) return;
    final dir = _currentPath.isNotEmpty
        ? p.dirname(_currentPath)
        : AppPaths.documents;
    _currentPath = p.join(dir, choice);
    await _save();
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
