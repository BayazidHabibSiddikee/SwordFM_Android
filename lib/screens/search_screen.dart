import 'dart:async';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import '../services/archive_service.dart';
import '../services/search_service.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';

/// Search screen — recursive filename search with result list.
class SearchScreen extends StatefulWidget {
  final String startPath;

  const SearchScreen({super.key, required this.startPath});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<FileItem> _results = [];
  bool _loading = false;
  String? _error;
  int _resultCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onSearchChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Timer? _debounce;
  void _onSearchChanged() {
    _debounce?.cancel();
    final query = _controller.text.trim();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (query.isEmpty) {
        setState(() {
          _results = [];
          _resultCount = 0;
          _error = null;
        });
        return;
      }
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await SearchService.searchDirectory(
        widget.startPath,
        query,
        includeHidden: false,
        limit: 300,
      );
      if (mounted) {
        setState(() {
          _results = results;
          _resultCount = results.length;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _error = 'Search failed: $e';
          _loading = false;
        });
    }
  }

  Future<void> _openItem(FileItem item) async {
    if (item.isDirectory) {
      Navigator.pop(context, item.path);
    } else {
      final result = await OpenFile.open(item.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot open: ${result.message}'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
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
        _menuItem('Open', Icons.open_in_new, () => _openItem(item)),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(item)),
        _menuItem('Copy', Icons.copy, () {
          FileUtils.setClipboard(item.path, 'copy');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied: ${item.name}'),
              backgroundColor: OneDarkColors.cyan,
            ),
          );
        }),
        _menuItem('Cut', Icons.content_cut, () {
          FileUtils.setClipboard(item.path, 'cut');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cut: ${item.name}'),
              backgroundColor: OneDarkColors.amber,
            ),
          );
        }),
        _menuItem('Delete', Icons.delete, () => _confirmDelete(item)),
        if (ArchiveService.isArchive(item.path))
          _menuItem('Extract', Icons.folder_open, () async {
            final destDir = p.join(
              p.dirname(item.path),
              p.basenameWithoutExtension(item.path),
            );
            try {
              await ArchiveService.extract(item.path, destDir);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Extracted to ${p.basename(destDir)}'),
                    backgroundColor: OneDarkColors.green,
                  ),
                );
                if (_results.any((r) => r.path == item.path)) {
                  _runSearch(_controller.text.trim());
                }
              }
            } catch (e) {
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Extract failed: $e'),
                    backgroundColor: OneDarkColors.red,
                  ),
                );
            }
          }),
        _menuItem(
          'Properties',
          Icons.info_outline,
          () => _showProperties(item),
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

  void _showRenameDialog(FileItem item) {
    final controller = TextEditingController(text: item.name);
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
              if (newName.isNotEmpty && newName != item.name) {
                try {
                  await FileUtils.rename(item.path, newName);
                  if (mounted) _runSearch(_controller.text.trim());
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

  Future<void> _confirmDelete(FileItem item) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete "${item.name}"?',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'trash'),
            child: const Text('Move to Trash'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text('Delete', style: TextStyle(color: OneDarkColors.red)),
          ),
        ],
      ),
    );
    if (choice == 'trash') {
      try {
        await FileUtils.moveToTrash(item.path);
      } catch (_) {}
      if (mounted) _runSearch(_controller.text.trim());
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
    } else if (choice == 'delete') {
      try {
        await FileUtils.delete(item.path);
      } catch (_) {}
      if (mounted) _runSearch(_controller.text.trim());
    }
  }

  void _showProperties(FileItem item) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(item.name, style: TextStyle(color: OneDarkColors.fg)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _propRow('Name', item.name),
              _propRow(
                'Type',
                item.isDirectory
                    ? 'Folder'
                    : (item.extension.isNotEmpty
                          ? item.extension.toUpperCase().replaceAll('.', '')
                          : 'File'),
              ),
              _propRow('Size', item.formattedSize),
              _propRow('Modified', item.formattedDate),
              _propRow('Path', item.path),
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
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: TextStyle(color: OneDarkColors.fg),
          decoration: InputDecoration(
            hintText: 'Search files…',
            hintStyle: TextStyle(color: OneDarkColors.fgDim),
            border: InputBorder.none,
          ),
          autofocus: true,
          onChanged: (_) {},
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
      ),
      body: Column(
        children: [
          if (_resultCount > 0 || _loading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: OneDarkColors.bgDark,
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: OneDarkColors.cyan),
                  const SizedBox(width: 8),
                  Text(
                    _loading
                        ? 'Searching…'
                        : '$_resultCount result${_resultCount != 1 ? 's' : ''}',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: TextStyle(color: OneDarkColors.red)),
            ),
          Expanded(
            child: _loading && _results.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: OneDarkColors.fgDim,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _controller.text.trim().isEmpty
                              ? 'Type to search'
                              : 'No results found',
                          style: TextStyle(color: OneDarkColors.fgDim),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = _results[index];
                      return ListTile(
                        leading: Icon(
                          item.icon,
                          size: 24,
                          color: item.iconColor,
                        ),
                        title: Text(
                          item.name,
                          style: TextStyle(color: OneDarkColors.fg),
                        ),
                        subtitle: Text(
                          '${item.formattedSize} · ${p.dirname(item.path)}',
                          style: TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _openItem(item),
                        onLongPress: () => _showContextMenu(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
