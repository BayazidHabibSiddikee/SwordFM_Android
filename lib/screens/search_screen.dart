import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/archive_service.dart';
import '../services/search_service.dart';
import '../services/open_with_service.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../widgets/preview_panel.dart';
import 'video_player_screen.dart';
import 'music_player_screen.dart';

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
  FileItem? _previewItem;

  SearchMode _searchMode = SearchMode.substring;
  int _minSize = 0;
  int _maxSize = 0;
  final _minSizeController = TextEditingController();
  final _maxSizeController = TextEditingController();
  bool _showFilters = false;

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
    _minSizeController.dispose();
    _maxSizeController.dispose();
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
      _parseSizeFilters();
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
        mode: _searchMode,
        minSize: _minSize,
        maxSize: _maxSize,
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

  void _parseSizeFilters() {
    _minSize = _parseSize(_minSizeController.text);
    _maxSize = _parseSize(_maxSizeController.text);
  }

  int _parseSize(String text) {
    text = text.trim().toLowerCase();
    if (text.isEmpty) return 0;
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(b|kb|mb|gb|tb)?$',
    ).firstMatch(text);
    if (match == null) return 0;
    final value = double.parse(match.group(1)!);
    final unit = match.group(2) ?? 'b';
    switch (unit) {
      case 'kb':
        return (value * 1024).round();
      case 'mb':
        return (value * 1024 * 1024).round();
      case 'gb':
        return (value * 1024 * 1024 * 1024).round();
      case 'tb':
        return (value * 1024 * 1024 * 1024 * 1024).round();
      default:
        return value.round();
    }
  }

  Future<void> _openItem(FileItem item) async {
    if (item.isDirectory) {
      Navigator.pop(context, item.path);
      return;
    }
    final ext = item.extension.toLowerCase();
    // Video → built-in player
    if (kVideoExtensions.contains(ext)) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(filePath: item.path),
        ),
      );
      return;
    }
    // Audio → built-in music player (playlist = all audio hits)
    if (kAudioExtensions.contains(ext)) {
      final playlist = _results
          .where((r) => kAudioExtensions.contains(r.extension.toLowerCase()))
          .map((r) => r.path)
          .toList();
      final index = playlist.indexOf(item.path);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MusicPlayerScreen(
            filePath: item.path,
            playlist: playlist,
            initialIndex: index < 0 ? 0 : index,
          ),
        ),
      );
      return;
    }
    // Images/PDFs/text open in the in-app preview panel (like the browser).
    if (item.isImage ||
        item.isPdf ||
        item.isMarkdown ||
        item.isText ||
        item.isCode) {
      setState(() => _previewItem = item);
      return;
    }
    // Other file types open externally.
    try {
      await OpenWithService.openDefault(item.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot open: $e'),
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

  Widget _modeChip(String label, SearchMode mode) {
    final selected = _searchMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _searchMode = mode);
        final q = _controller.text.trim();
        if (q.isNotEmpty) _runSearch(q);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? OneDarkColors.cyan.withValues(alpha: 0.2)
              : OneDarkColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? OneDarkColors.cyan : OneDarkColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? OneDarkColors.cyan : OneDarkColors.fgDim,
            fontSize: 11,
          ),
        ),
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
            hintText: _searchMode == SearchMode.regex
                ? 'Regex pattern…'
                : _searchMode == SearchMode.glob
                ? 'Glob pattern (e.g. *.jpg)…'
                : 'Search files…',
            hintStyle: TextStyle(color: OneDarkColors.fgDim),
            border: InputBorder.none,
          ),
          autofocus: true,
          onChanged: (_) {},
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          IconButton(
            icon: Icon(
              _showFilters ? Icons.filter_list_off : Icons.filter_list,
              size: 20,
              color: _showFilters ? OneDarkColors.cyan : OneDarkColors.fgDim,
            ),
            tooltip: 'Filters',
            onPressed: () => setState(() => _showFilters = !_showFilters),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search mode chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: OneDarkColors.bgDark,
            child: Row(
              children: [
                _modeChip('Text', SearchMode.substring),
                const SizedBox(width: 6),
                _modeChip('Regex', SearchMode.regex),
                const SizedBox(width: 6),
                _modeChip('Glob', SearchMode.glob),
              ],
            ),
          ),
          // Size filter row
          if (_showFilters)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: OneDarkColors.bgDark,
              child: Row(
                children: [
                  Icon(Icons.format_size, size: 16, color: OneDarkColors.fgDim),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 70,
                    child: TextField(
                      controller: _minSizeController,
                      style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Min',
                        hintStyle: TextStyle(
                          color: OneDarkColors.fgDim,
                          fontSize: 11,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: OneDarkColors.border),
                        ),
                      ),
                      keyboardType: TextInputType.text,
                      onSubmitted: (_) {
                        _parseSizeFilters();
                        final q = _controller.text.trim();
                        if (q.isNotEmpty) _runSearch(q);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('–', style: TextStyle(color: OneDarkColors.fgDim)),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 70,
                    child: TextField(
                      controller: _maxSizeController,
                      style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Max',
                        hintStyle: TextStyle(
                          color: OneDarkColors.fgDim,
                          fontSize: 11,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: OneDarkColors.border),
                        ),
                      ),
                      keyboardType: TextInputType.text,
                      onSubmitted: (_) {
                        _parseSizeFilters();
                        final q = _controller.text.trim();
                        if (q.isNotEmpty) _runSearch(q);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'KB/MB/GB',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
                  ),
                ],
              ),
            ),
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
                      final isSel = _previewItem?.path == item.path;
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
                        selected: isSel,
                        selectedTileColor: OneDarkColors.select.withValues(
                          alpha: 0.3,
                        ),
                        onTap: () => _openItem(item),
                        onLongPress: () => _showContextMenu(item),
                      );
                    },
                  ),
          ),
          if (_previewItem != null)
            PreviewPanel(
              item: _previewItem,
              width: double.infinity,
              height: 280,
              onClose: () => setState(() => _previewItem = null),
            ),
        ],
      ),
    );
  }
}
