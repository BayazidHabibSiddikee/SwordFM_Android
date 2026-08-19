import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../services/archive_service.dart';
import 'convert_dialog.dart';
import 'package:path/path.dart' as p;

enum ViewMode { details, grid }
enum SortOption { name, size, date, type }
enum SortDir { asc, desc }
enum SelectionMode { none, multi }

class FileBrowser extends StatefulWidget {
  final String initialPath;
  final ValueChanged<FileItem?> onItemSelected;

  const FileBrowser({super.key, required this.initialPath, required this.onItemSelected});

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
  SelectionMode _selectionMode = SelectionMode.none;
  // ignore: prefer_final_fields — mutated via setState
  Set<String> _selectedPaths = {};
  final Map<String, int> _folderSizes = {};
  final Set<String> _loadingFolders = {};

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadDirectory();
  }

  Future<void> _loadDirectory([String? path]) async {
    if (path != null) setState(() { _currentPath = path; _selectedPaths.clear(); _selectionMode = SelectionMode.none; });
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

  Future<int> _computeFolderSize(FileItem folder) async {
    if (_loadingFolders.contains(folder.path)) return -1;
    if (_folderSizes.containsKey(folder.path)) return _folderSizes[folder.path]!;
    _loadingFolders.add(folder.path);
    final size = await FileItem.getTotalSize(folder);
    _loadingFolders.remove(folder.path);
    setState(() => _folderSizes[folder.path] = size);
    return size;
  }

  void _sortItems(List<FileItem> items) {
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      int cmp;
      switch (_sortOption) {
        case SortOption.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortOption.size:
          {
            if (a.isDirectory && b.isDirectory) {
              cmp = 0;
            } else if (a.isDirectory) {
              cmp = 1;
            } else if (b.isDirectory) {
              cmp = -1;
            } else {
              cmp = a.size.compareTo(b.size);
            }
          }
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

  void _enterSelectMode() => setState(() => _selectionMode = SelectionMode.multi);
  void _exitSelectMode() => setState(() { _selectionMode = SelectionMode.none; _selectedPaths.clear(); });
  void _selectAll() => setState(() => _selectedPaths = _items.map((e) => e.path).toSet());
  void _deselectAll() => setState(() => _selectedPaths.clear());

  Future<void> _deleteSelected() async {
    if (_selectedPaths.isEmpty) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Delete ${_selectedPaths.length} items?', style: const TextStyle(color: OneDarkColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, 'trash'), child: const Text('Move to Trash')),
          TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete', style: TextStyle(color: OneDarkColors.red))),
        ],
      ),
    );
    if (choice == 'trash' && mounted) {
      for (final path in _selectedPaths.toList()) {
        try { await FileUtils.moveToTrash(path); } catch (_) {}
      }
      _selectedPaths.clear();
      if (mounted) _loadDirectory();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Moved to trash'), backgroundColor: OneDarkColors.amber));
    } else if (choice == 'delete' && mounted) {
      for (final path in _selectedPaths.toList()) {
        try { await FileUtils.delete(path); } catch (_) {}
      }
      _selectedPaths.clear();
      if (mounted) _loadDirectory();
    }
  }

  void _copySelected() {
    for (final path in _selectedPaths) {
      FileUtils.setClipboard(path, 'copy');
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_selectedPaths.length} item(s) copied'), backgroundColor: OneDarkColors.cyan));
  }

  void _cutSelected() {
    for (final path in _selectedPaths) {
      FileUtils.setClipboard(path, 'cut');
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_selectedPaths.length} item(s) cut'), backgroundColor: OneDarkColors.amber));
  }

  void _batchRename() {
    if (_selectedPaths.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => _BatchRenameDialog(selectedPaths: _selectedPaths.toList()),
    ).then((_) { if (mounted) _loadDirectory(); });
  }

  Future<void> _extractArchive(String path) async {
    final destDir = p.join(p.dirname(path), p.basenameWithoutExtension(path));
    try {
      await ArchiveService.extract(path, destDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extracted to ${p.basename(destDir)}'), backgroundColor: OneDarkColors.green),
        );
        _loadDirectory();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extract failed: $e'), backgroundColor: OneDarkColors.red),
      );
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
              _propRow('Name', item.name),
              _propRow('Type', item.isDirectory ? 'Folder' : (item.extension.isNotEmpty ? item.extension.toUpperCase().replaceAll('.', '') : 'File')),
              _propRow('Size', item.formattedSize),
              _propRow('Modified', item.formattedDate),
              _propRow('Path', item.path),
              if (item.isDirectory) ...[
                const SizedBox(height: 4),
                _buildFolderSizeFutureBuilder(item),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  Widget _buildFolderSizeFutureBuilder(FileItem folder) {
    return FutureBuilder<int>(
      future: _computeFolderSize(folder),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Row(children: [
            SizedBox(width: 80, child: Text('Size', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
            Expanded(child: const Row(children: [SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 6), Text('Calculating...', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12))])),
          ]);
        }
        final size = snapshot.hasData && snapshot.data! >= 0 ? snapshot.data! : folder.size;
        return Row(children: [
          SizedBox(width: 80, child: Text('Size', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
          Expanded(child: Text(_formatBytes(size), style: const TextStyle(color: OneDarkColors.fg, fontSize: 12))),
        ]);
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
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
        _menuItem('Open', Icons.open_in_new, () => _openItem(item)),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(item)),
        _menuItem('Copy', Icons.copy, () {
          FileUtils.setClipboard(item.path, 'copy');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied: ${item.name}'), backgroundColor: OneDarkColors.cyan));
        }),
        _menuItem('Cut', Icons.content_paste, () {
          FileUtils.setClipboard(item.path, 'cut');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cut: ${item.name}'), backgroundColor: OneDarkColors.amber));
        }),
        _menuItem('Delete', Icons.delete, () => _confirmDelete(item)),
        if (ArchiveService.isArchive(item.path))
          _menuItem('Extract', Icons.folder_open, () => _extractArchive(item.path)),
        _menuItem('Properties', Icons.info_outline, () => _showProperties(item)),
        if (item.isMarkdown)
          _menuItem('Convert…', Icons.transform, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ConvertDialog(filePath: item.path)),
            );
          }),
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
              if (controller.text.isNotEmpty && controller.text != item.name) {
                await FileUtils.rename(item.path, controller.text);
                if (mounted) _loadDirectory();
              }
              final ctx = context;
              if (mounted) {
                Navigator.pop(ctx);
              }
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
        title: Text('Delete "${item.name}"?', style: const TextStyle(color: OneDarkColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, 'trash'), child: const Text('Move to Trash')),
          TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete', style: TextStyle(color: OneDarkColors.red))),
        ],
      ),
    );
    if (choice == 'trash' && mounted) {
      try { await FileUtils.moveToTrash(item.path); } catch (_) {}
      if (mounted) { _loadDirectory(); _exitSelectMode(); }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Moved to trash'), backgroundColor: OneDarkColors.amber));
    } else if (choice == 'delete' && mounted) {
      await FileUtils.delete(item.path);
      if (mounted) { _loadDirectory(); _exitSelectMode(); }
    }
  }

  Widget _buildToolbar() {
    final inSelectMode = _selectionMode == SelectionMode.multi;
    return Container(
      color: OneDarkColors.bgDark,
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: OneDarkColors.fg), onPressed: _currentPath != '/' ? _goUp : null),
          IconButton(icon: const Icon(Icons.arrow_upward, color: OneDarkColors.fg), onPressed: _goUp),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: OneDarkColors.dim, borderRadius: BorderRadius.circular(4)),
              child: Row(children: [
                Icon(Icons.folder_open, size: 16, color: OneDarkColors.cyan),
                const SizedBox(width: 6),
                Expanded(child: Text(_currentPath, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
          const SizedBox(width: 4),
          if (inSelectMode)
            IconButton(icon: const Icon(Icons.check, color: OneDarkColors.green), onPressed: _exitSelectMode, tooltip: 'Done')
          else
            IconButton(icon: const Icon(Icons.select_all, color: OneDarkColors.fgDim), onPressed: _enterSelectMode, tooltip: 'Select'),
          if (inSelectMode)
            IconButton(icon: const Icon(Icons.delete_outline, color: OneDarkColors.red), onPressed: _deleteSelected, tooltip: 'Delete selected'),
          if (inSelectMode)
            IconButton(icon: const Icon(Icons.copy, color: OneDarkColors.cyan), onPressed: _copySelected, tooltip: 'Copy selected'),
          if (inSelectMode)
            IconButton(icon: const Icon(Icons.content_paste, color: OneDarkColors.amber), onPressed: _cutSelected, tooltip: 'Cut selected'),
          if (inSelectMode)
            IconButton(icon: const Icon(Icons.edit_note, color: OneDarkColors.cyan), onPressed: _batchRename, tooltip: 'Batch rename'),
          if (inSelectMode)
            PopupMenuButton<bool>(
              icon: const Icon(Icons.tune, color: OneDarkColors.fgDim),
              onSelected: (v) => v ? _selectAll() : _deselectAll(),
              itemBuilder: (_) => [
                PopupMenuItem(value: true, child: const Text('Select All')),
                PopupMenuItem(value: false, child: const Text('Deselect All')),
              ],
            ),
          _buildSortButton(),
          IconButton(
            icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off, color: _showHidden ? OneDarkColors.cyan : OneDarkColors.fgDim),
            onPressed: () { setState(() => _showHidden = !_showHidden); _loadDirectory(); },
          ),
          IconButton(
            icon: Icon(_viewMode == ViewMode.details ? Icons.view_list : Icons.grid_view, color: OneDarkColors.cyan),
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
      onSelected: (opt) { setState(() => _sortOption = opt); _loadDirectory(); },
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
          onTap: () { setState(() => _sortDir = _sortDir == SortDir.asc ? SortDir.desc : SortDir.asc); _loadDirectory(); },
        ),
      ],
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.75, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return const SizedBox.shrink();
        final item = _items[index - 1];
        final isSelected = _selectedPaths.contains(item.path);
        return GestureDetector(
          onLongPress: () => _showContextMenu(item),
          onSecondaryTapDown: (_) => _showContextMenu(item),
          onTap: () {
            if (_selectionMode == SelectionMode.multi) {
              _toggleSelection(item.path);
            } else if (isSelected) {
              _openItem(item);
            } else {
              _toggleSelection(item.path);
            }
          },
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: isSelected ? OneDarkColors.select : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: isSelected ? Border.all(color: OneDarkColors.cyan, width: 1.5) : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(item.icon, size: 32, color: item.iconColor),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(item.name, style: const TextStyle(color: OneDarkColors.fg, fontSize: 11), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
              if (_selectionMode == SelectionMode.multi)
                Positioned(top: 2, right: 2, child: Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(color: isSelected ? OneDarkColors.cyan : OneDarkColors.dim, shape: BoxShape.circle),
                  child: Center(child: Icon(isSelected ? Icons.check : Icons.circle_outlined, size: 14, color: isSelected ? Colors.black : OneDarkColors.fgDim)),
                )),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailsView() {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4),
      itemCount: _items.length + 1,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) return _buildColumnHeaders();
        final item = _items[index - 1];
        final isSelected = _selectedPaths.contains(item.path);
        return GestureDetector(
          onLongPress: () => _showContextMenu(item),
          onSecondaryTapDown: (_) => _showContextMenu(item),
          onTap: () {
            if (_selectionMode == SelectionMode.multi) {
              _toggleSelection(item.path);
            } else if (isSelected) {
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
                if (_selectionMode == SelectionMode.multi)
                  InkWell(
                    onTap: () => _toggleSelection(item.path),
                    child: Container(
                      width: 20, height: 20,
                      decoration: BoxDecoration(color: isSelected ? OneDarkColors.cyan : OneDarkColors.dim, shape: BoxShape.circle),
                      child: Center(child: Icon(isSelected ? Icons.check : Icons.circle_outlined, size: 14, color: isSelected ? Colors.black : OneDarkColors.fgDim)),
                    ),
                  )
                else
                  const SizedBox(width: 20),
                Icon(item.icon, size: 18, color: item.iconColor),
                const SizedBox(width: 10),
                Expanded(child: Text(item.name, style: const TextStyle(color: OneDarkColors.fg, fontSize: 13))),
                if (item.isDirectory)
                  SizedBox(width: 60, child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder, size: 11, color: OneDarkColors.fgDim),
                      const SizedBox(width: 2),
                      FutureBuilder<int>(
                        future: _computeFolderSize(item),
                        builder: (ctx, snap) {
                          if (snap.connectionState == ConnectionState.waiting) return const SizedBox(width: 30, child: LinearProgressIndicator(minHeight: 4));
                          final s = snap.hasData && snap.data! >= 0 ? snap.data! : 0;
                          return Text(_formatBytes(s), style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12));
                        },
                      ),
                    ],
                  ))
                else
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
    return Row(
      children: [
        SizedBox(width: _selectionMode == SelectionMode.multi ? 42 : 28),
        Expanded(child: Text('Name', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 60, child: Text('Size', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 120, child: Text('Date Modified', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
        SizedBox(width: 80, child: Text('Type', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _buildToolbar(),
      if (_isLoading) const Expanded(child: Center(child: CircularProgressIndicator()))
      else Expanded(child: _viewMode == ViewMode.details ? _buildDetailsView() : _buildGridView()),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Batch rename dialog
// ---------------------------------------------------------------------------

class _BatchRenameDialog extends StatefulWidget {
  final List<String> selectedPaths;
  const _BatchRenameDialog({required this.selectedPaths});
  @override
  State<_BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<_BatchRenameDialog> {
  final _prefixController = TextEditingController();
  final _suffixController = TextEditingController();
  String _mode = 'prefix'; // 'prefix', 'suffix', or 'regex'
  final _regexController = TextEditingController();
  final _replacementController = TextEditingController();

  List<MapEntry<String, String>> get _previewEntries {
    return widget.selectedPaths.map((path) {
      final name = p.basename(path);
      String newName;
      if (_mode == 'prefix') {
        newName = '${_prefixController.text}$name';
      } else if (_mode == 'suffix') {
        newName = '$name${_suffixController.text}';
      } else {
        try {
          newName = name.replaceAll(RegExp(_regexController.text), _replacementController.text);
        } catch (_) {
          newName = name;
        }
      }
      return MapEntry(name, newName);
    }).toList();
  }

  @override
  void dispose() {
    _prefixController.dispose();
    _suffixController.dispose();
    _regexController.dispose();
    _replacementController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: Text('Batch Rename (${widget.selectedPaths.length})', style: const TextStyle(color: OneDarkColors.fg)),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'prefix', label: Text('Prefix'), icon: Icon(Icons.text_fields, size: 16)),
                  ButtonSegment(value: 'suffix', label: Text('Suffix'), icon: Icon(Icons.text_format, size: 16)),
                  ButtonSegment(value: 'regex', label: Text('Regex'), icon: Icon(Icons.functions, size: 16)),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(height: 12),
              if (_mode == 'prefix') ...[
                TextField(
                  controller: _prefixController,
                  decoration: const InputDecoration(labelText: 'Prefix', border: OutlineInputBorder()),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ] else if (_mode == 'suffix') ...[
                TextField(
                  controller: _suffixController,
                  decoration: const InputDecoration(labelText: 'Suffix', border: OutlineInputBorder()),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ] else ...[
                TextField(
                  controller: _regexController,
                  decoration: const InputDecoration(labelText: 'Regex pattern', border: OutlineInputBorder()),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _replacementController,
                  decoration: const InputDecoration(labelText: 'Replacement', border: OutlineInputBorder()),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ],
              const SizedBox(height: 12),
              const Text('Preview:', style: TextStyle(color: OneDarkColors.cyan, fontSize: 12)),
              const Divider(height: 1),
              ..._previewEntries.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(e.key, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11))),
                    const Icon(Icons.arrow_forward, size: 14, color: OneDarkColors.fgDim),
                    Expanded(child: Text(e.value, style: const TextStyle(color: OneDarkColors.green, fontSize: 11))),
                  ],
                ),
              )),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            for (final entry in _previewEntries) {
              if (entry.key != entry.value) {
                try { await FileUtils.rename(entry.key, entry.value); } catch (_) {}
              }
            }
            final ctx = context;
              if (mounted) {
                Navigator.pop(ctx);
              }
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
