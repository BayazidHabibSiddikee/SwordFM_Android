import 'package:flutter/material.dart';
import '../theme/theme.dart';
import '../widgets/file_browser.dart';
import '../utils/app_paths.dart';

class FilePickerScreen extends StatefulWidget {
  final bool allowMultiple;
  const FilePickerScreen({super.key, this.allowMultiple = true});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  List<String> _selectedPaths = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        title: Text('Select Files', style: TextStyle(color: OneDarkColors.fg)),
        leading: IconButton(
          icon: Icon(Icons.close, color: OneDarkColors.fg),
          onPressed: () => Navigator.pop(context, <String>[]),
        ),
        actions: [
          if (_selectedPaths.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, _selectedPaths),
              child: Text('OK (${_selectedPaths.length})', style: TextStyle(color: OneDarkColors.cyan, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: FileBrowser(
        initialPath: AppPaths.home,
        onItemSelected: (item) {
          if (item != null && !item.isDirectory) {
             Navigator.pop(context, <String>[item.path]);
          }
        },
        onSelectionChanged: (info) {
           setState(() {
              _selectedPaths = info.items.map((e) => e.path).toList();
           });
        },
      ),
    );
  }
}
