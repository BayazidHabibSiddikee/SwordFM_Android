import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';

enum ViewMode { details, grid }
enum SortOption { name, size, date, type }
enum SortDir { asc, desc }

/// A full-featured file browser matching Linux SwordFM behavior.
class FileBrowser extends StatefulWidget {
  final String initialPath;
  final ValueChanged<FileItem?> onItemSelected;

  const FileBrowser({
    super.key,
    required this.initialPath,
    required this.onItemSelected,
  });

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  List<FileItem> _items = [];
  bool _isLoading = true;
  String _currentPath = '/';
  bool _showHidden = false;
  ViewMode _viewMode = ViewMode.details;
  SortOption _sortOption = SortOption.name;
  SortDir _sortDir = SortDir.asc;
  // ignore: prefer_final_fields — mutated via setState
  Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadDirectory();
  }

  Future<void> _loadDirectory([String? path]) async {
    if (path != null) setState(() { _currentPath = path; _selectedPaths.clear(); });
    setState(() { _isLoading = true; });

    final items = await FileUtils.listDirectory(_currentPath, includeHidden: _showHidden);
    _sortItems(items);

    if (mounted) {
      setState(() {
        _items = items;
        _isLoading = false;
      });
    }
  }

  void _sortItems(List<FileItem> items) {
    items.sort((a, b) {
      // Directories first regardless of sort
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;

      int cmp;
      switch (_sortOption) {
        case SortOption.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortOption.size:
          cmp = a.size.compareTo(b.size);
          break;
        case SortOption.date:
          cmp = a.lastModified.compareTo(b.lastModified);
          break;
        case SortOption.type:
          cmp = a.extension.compareTo(b.extension);
          break;
      }
      return _sortDir == SortDir.desc ? -cmp : cmp;
    });
  }

  void _goUp() {
    if (_currentPath == '/') return;
    final parent = Directory(_currentPath).parent.path;
    _loadDirectory(parent);
  }

  Future<void> _openItem(FileItem item) async {
    if (item.isDirectory) {
      _loadDirectory(item.path);
    } else {
      widget.onItemSelected(item);
    }
  }

  void _showContextMenu(FileItem item) {
    final box = context.findRenderObject() as RenderBox?;
    final RenderBox? parentBox = box?.parent as RenderBox?;
    showMenu(
      context: context,
      position: parentBox != null
          ? RelativeRect.fromRect(
              Rect.fromLTWH(box!.localToGlobal(Offset.zero).dx, box.localToGlobal(Offset.zero).dy, 200, 240),
              parentBox.paintBounds,
            )
          : null,
      items: [
        _menuItem('Open', Icons.open_in_new, () {
          Navigator.pop(context);
          _openItem(item);
        }),
        _menuItem('Rename', Icons.edit, () {
          Navigator.pop(context);
          _showRenameDialog(item);
        }),
        _menuItem('Copy', Icons.copy, () {
          FileUtils.setClipboard(item.path, 'copy');
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Copied: ${item.name}'), backgroundColor: OneDarkColors.cyan),
          );
        }),
        _menuItem('Cut', Icons.content_paste, () {
          FileUtils.setClipboard(item.path, 'cut');
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cut: ${item.name}'), backgroundColor: OneDarkColors.amber),
          );
        }),
        _menuItem('Delete', Icons.delete, () {
          Navigator.pop(context);
          _confirmDelete(item);
        }),
        _menuItem('Properties', Icons.info_outline, () {
          Navigator.pop(context);
          _showProperties(item);
        }),
      ],
    );
  }

  PopupMenuItem<Object?> _menuItem(String title, IconData icon, VoidCallback onTap) {
    return PopupMenuItem<Object?>(
      onTap: onTap,
      child: Row(children: [
        Icon(icon, size: 18, color: OneDarkColors.fg),
        const SizedBox(width: 12),
        Text(title, style: const TextStyle(color: OneDarkColors.fg)),
      ]),
    );
  }

  void _showRenameDialog(FileItem item) {
    final controller = TextEditingController(text: item.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: OneDarkColors.fg),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (!mounted) return;
              if (controller.text.isNotEmpty && controller.text != item.name) {
                await FileUtils.rename(item.path, controller.text);
                if (mounted) _loadDirectory();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Delete "${item.name}"?', style: const TextStyle(color: OneDarkColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: OneDarkColors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await FileUtils.delete(item.path);
      _loadDirectory();
    }
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
              _propRow('Type', item.isDirectory ? 'Folder' : item.extension.toUpperCase().replaceAll('.', '')),
              _propRow('Size', item.formattedSize),
              _propRow('Modified', item.formattedDate),
              const SizedBox(height: 8),
              _propRow('Path', item.path),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _propRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
          Expanded(child: Text(value, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12))),
        ],
      ),
    );
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
    final item = _items.firstWhere((i) => i.path == path, orElse: () => _items.first);
    widget.onItemSelected(_selectedPaths.isEmpty ? null : item);
  }

  Widget _buildToolbar() {
    return Container(
      color: OneDarkColors.bgDark,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: OneDarkColors.fg),
            onPressed: _currentPath != '/' ? _goUp : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward, color: OneDarkColors.fgDim),
            onPressed: null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, color: OneDarkColors.fg),
            onPressed: _goUp,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: OneDarkColors.dim,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_open, size: 16, color: OneDarkColors.cyan),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentPath,
                      style: const TextStyle(color: OneDarkColors.fg, fontSize: 12, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          _buildSortButton(),
          IconButton(
            icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off,
                color: _showHidden ? OneDarkColors.cyan : OneDarkColors.fgDim),
            onPressed: () {
              setState(() => _showHidden = !_showHidden);
              _loadDirectory();
            },
          ),
          IconButton(
            icon: Icon(_viewMode == ViewMode.details ? Icons.view_list : Icons.grid_view,
                color: OneDarkColors.cyan),
            onPressed: () => setState(() => _viewMode = _viewMode == ViewMode.details ? ViewMode.grid : ViewMode.details),
          ),
        ],
      ),
    );
  }

  Widget _buildSortButton() {
    final icons = {SortOption.name: Icons.sort_by_alpha, SortOption.size: Icons.straighten, SortOption.date: Icons.calendar_today, SortOption.type: Icons.category};
    final labels = {SortOption.name: 'Name', SortOption.size: 'Size', SortOption.date: 'Date', SortOption.type: 'Type'};
    return PopupMenuButton<SortOption>(
      icon: Icon(icons[_sortOption], color: OneDarkColors.fg),
      onSelected: (opt) {
        setState(() => _sortOption = opt);
        _loadDirectory();
      },
      itemBuilder: (_) => [
        ...SortOption.values.map((opt) => PopupMenuItem(
          value: opt,
          child: Row(children: [
            Icon(icons[opt], size: 16, color: OneDarkColors.fg),
            const SizedBox(width: 8),
            Text('${labels[opt]!} ${_sortDir == SortDir.asc ? '↑' : '↓'}', style: const TextStyle(color: OneDarkColors.fg)),
          ]),
        )),
        const PopupMenuDivider(),
        PopupMenuItem(
          child: Text(_sortDir == SortDir.asc ? 'Descending' : 'Ascending', style: const TextStyle(color: OneDarkColors.fg)),
          onTap: () {
            setState(() => _sortDir = _sortDir == SortDir.asc ? SortDir.desc : SortDir.asc);
            _loadDirectory();
          },
        ),
      ],
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.75,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return const SizedBox.shrink();
        final item = _items[index - 1];
        final isSelected = _selectedPaths.contains(item.path);
        return GestureDetector(
          onLongPress: () => _showContextMenu(item),
          onTap: () {
            if (isSelected) {
              _openItem(item);
            } else {
              _toggleSelection(item.path);
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: isSelected ? OneDarkColors.select : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, size: 32, color: item.iconColor),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    item.name,
                    style: const TextStyle(color: OneDarkColors.fg, fontSize: 11),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailsView() {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4),
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildColumnHeaders();
        }
        final item = _items[index - 1];
        final isSelected = _selectedPaths.contains(item.path);
        return InkWell(
          onLongPress: () => _showContextMenu(item),
          onTap: () {
            if (isSelected) {
              _openItem(item);
            } else {
              _toggleSelection(item.path);
            }
          },
          child: Container(
            color: isSelected ? OneDarkColors.select : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: item.iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(item.name, style: const TextStyle(color: OneDarkColors.fg, fontSize: 13)),
                ),
                SizedBox(width: 60, child: Text(item.formattedSize, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
                SizedBox(width: 120, child: Text(item.formattedDate, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
                SizedBox(width: 80, child: Text(item.extension.isEmpty ? 'Folder' : item.extension, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildColumnHeaders() {
    return const Row(
      children: [
        SizedBox(width: 28),
        Expanded(child: Text('Name', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 60, child: Text('Size', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 120, child: Text('Date Modified', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 80, child: Text('Type', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(child: _viewMode == ViewMode.details ? _buildDetailsView() : _buildGridView()),
      ],
    );
  }
}
