import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../services/archive_service.dart';
import '../services/open_with_service.dart';
import '../services/terminal_service.dart';
import 'convert_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

enum ViewMode { details, grid }

enum SortOption { name, size, date, type }

enum SortDir { asc, desc }

enum SelectionMode { none, multi }

enum FileTypeFilter { all, images, videos, audio, documents, archives, discs }

/// Archive formats supported by the "Compress…" dialog.
enum ArchiveFormat { zip, tar, tarGz }

/// Extension sets matching Linux SwordFM's filefilter.cpp exactly.
const Map<FileTypeFilter, Set<String>> _kTypeExtensions = {
  FileTypeFilter.images: {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'svg',
    'ico',
    'tif',
    'tiff',
    'avif',
    'jxl',
    'heic',
    'heif',
    'raw',
    'cr2',
    'nef',
    'arw',
    'dng',
    'psd',
    'xcf',
  },
  FileTypeFilter.videos: {
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    '3gp',
    'ogv',
    'ts',
    'm2ts',
    'vob',
    'rmvb',
    'divx',
  },
  FileTypeFilter.audio: {
    'mp3',
    'flac',
    'wav',
    'ogg',
    'opus',
    'm4a',
    'aac',
    'wma',
    'aiff',
    'ape',
    'alac',
    'mid',
    'midi',
  },
  FileTypeFilter.documents: {
    'pdf',
    'doc',
    'docx',
    'odt',
    'rtf',
    'txt',
    'md',
    'xls',
    'xlsx',
    'ods',
    'csv',
    'ppt',
    'pptx',
    'odp',
    'epub',
    'mobi',
    'djvu',
    'tex',
  },
  FileTypeFilter.archives: {
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'bz2',
    'xz',
    'zst',
    'lz',
    'lzma',
    'tgz',
    'tbz2',
    'txz',
    'cab',
    'arj',
    'lha',
    'deb',
    'rpm',
    'pkg',
    'apk',
    'jar',
  },
  FileTypeFilter.discs: {
    'iso',
    'img',
    'dmg',
    'vdi',
    'vmdk',
    'qcow2',
    'cue',
    'bin',
    'mdf',
    'nrg',
    'toast',
  },
};

/// Extensions treated as plain text/code for the "Open With" menu.
const Set<String> _kTextExtensions = {
  '.txt',
  '.md',
  '.markdown',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.log',
  '.csv',
  '.html',
  '.css',
  '.js',
  '.ts',
  '.tsx',
  '.py',
  '.dart',
  '.sh',
  '.bash',
  '.zsh',
  '.cpp',
  '.c',
  '.h',
  '.hpp',
  '.java',
  '.kt',
  '.rb',
  '.go',
  '.rs',
  '.swift',
  '.ini',
  '.conf',
  '.cfg',
  '.toml',
  '.sql',
  '.env',
  '.gitignore',
  '.diff',
};

/// Aggregate info about the current multi-selection, reported to the parent
/// via [FileBrowser.onSelectionChanged].
class SelectionInfo {
  final int count;
  final int totalSizeBytes;
  final List<FileItem> items;
  const SelectionInfo({
    required this.count,
    required this.totalSizeBytes,
    required this.items,
  });
}

/// State of the internal file clipboard, reported to the parent via
/// [FileBrowser.onClipboardChanged].
class ClipboardInfo {
  final bool hasClipboard;
  final String operation; // 'copy' | 'cut' | 'none'
  final int count;
  const ClipboardInfo({
    required this.hasClipboard,
    required this.operation,
    required this.count,
  });
  const ClipboardInfo.empty()
    : this(hasClipboard: false, operation: 'none', count: 0);
}

class FileBrowser extends StatefulWidget {
  final String initialPath;
  final ValueChanged<FileItem?> onItemSelected;
  final ValueChanged<SelectionInfo>? onSelectionChanged;
  final ValueChanged<ClipboardInfo>? onClipboardChanged;

  /// Called when the browser navigates to a new path (for breadcrumb/sidebar sync).
  final ValueChanged<String>? onPathChanged;

  const FileBrowser({
    super.key,
    required this.initialPath,
    required this.onItemSelected,
    this.onSelectionChanged,
    this.onClipboardChanged,
    this.onPathChanged,
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
  SelectionMode _selectionMode = SelectionMode.none;
  // ignore: prefer_final_fields — mutated via setState
  Set<String> _selectedPaths = {};
  final Map<String, int> _folderSizes = {};
  final Set<String> _loadingFolders = {};

  // --- Type filter & date range filter ---
  FileTypeFilter _filterType = FileTypeFilter.all;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  bool _showJunk = false; // hide auto-generated junk names by default

  // --- Navigation history (Alt+Left / Alt+Right) ---
  final List<String> _history = [];
  int _historyIndex = -1;

  // Focus node so hardware-keyboard shortcuts keep working after dialogs.
  final FocusNode _focusNode = FocusNode();

  // --- In-place rename (F2) ---
  int? _renamingIndex;
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocusNode = FocusNode();

  // Prevents onPathChanged callback loop when navigating from external prop change.
  bool _suppressCallback = false;

  @override
  void initState() {
    super.initState();
    // Start at root; didUpdateWidget will navigate to initialPath if non-empty.
    _history.add(_currentPath);
    _historyIndex = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    // Navigate to the initial path if it differs from the default '/'.
    if (widget.initialPath.isNotEmpty && widget.initialPath != '/') {
      _loadDirectory(path: widget.initialPath);
    } else {
      _loadDirectory();
    }
  }

  @override
  void didUpdateWidget(covariant FileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the parent changes initialPath (sidebar/breadcrumb navigation),
    // navigate internally without destroying state — preserves history.
    if (widget.initialPath != oldWidget.initialPath &&
        widget.initialPath.isNotEmpty) {
      _suppressCallback = true;
      _loadDirectory(path: widget.initialPath);
      _suppressCallback = false;
    }
  }

  @override
  void dispose() {
    _renameController.dispose();
    _renameFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Returns [_items] filtered by the active type filter, date range, and junk filter.
  List<FileItem> get _filteredItems {
    var result = _items;
    // Junk name filter (hide auto-generated names by default)
    if (!_showJunk) {
      result = result
          .where((item) => item.isDirectory || !isJunkName(item.name))
          .toList();
    }
    // Type filter
    if (_filterType != FileTypeFilter.all) {
      final exts = _kTypeExtensions[_filterType];
      if (exts != null) {
        result = result
            .where(
              (item) =>
                  item.isDirectory ||
                  exts.contains(item.extension.substring(1)),
            )
            .toList();
      }
    }
    // Date range filter
    if (_dateFrom != null || _dateTo != null) {
      result = result.where((item) {
        final d = item.lastModified;
        if (_dateFrom != null && d.isBefore(_dateFrom!)) return false;
        if (_dateTo != null && d.isAfter(_dateTo!.add(const Duration(days: 1))))
          return false;
        return true;
      }).toList();
    }
    return result;
  }

  Future<void> _loadDirectory({String? path, bool pushHistory = true}) async {
    if (path != null) {
      // Block navigation into system directories (matches Linux SwordFM).
      if (isBlockedPath(path)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('System directory — navigation blocked'),
              backgroundColor: OneDarkColors.amber,
            ),
          );
        }
        return;
      }
      if (pushHistory && (_history.isEmpty || _history.last != path)) {
        // Truncate any forward entries (we navigated back, then went elsewhere).
        if (_historyIndex >= 0 && _historyIndex < _history.length - 1) {
          _history.removeRange(_historyIndex + 1, _history.length);
        }
        _history.add(path);
        if (_history.length > 50) _history.removeAt(0);
        _historyIndex = _history.length - 1;
      }
      final pathChanged = path != _currentPath;
      setState(() {
        _currentPath = path;
        _selectedPaths.clear();
        _selectionMode = SelectionMode.none;
        _renamingIndex = null;
      });
      _notifySelectionChanged();
      // Notify parent of path change (for breadcrumb/sidebar sync), unless
      // this navigation was triggered by an external prop change.
      if (pathChanged && !_suppressCallback) {
        widget.onPathChanged?.call(path);
      }
    }
    setState(() {
      _isLoading = true;
    });
    final items = await FileUtils.listDirectory(
      _currentPath,
      includeHidden: _showHidden,
    );
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
    if (_folderSizes.containsKey(folder.path))
      return _folderSizes[folder.path]!;
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
    _loadDirectory(path: parent);
  }

  Future<void> _openItem(FileItem item) async {
    if (item.isDirectory) {
      _loadDirectory(path: item.path);
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
    final item = _items.firstWhere(
      (i) => i.path == path,
      orElse: () => _items.first,
    );
    widget.onItemSelected(_selectedPaths.isEmpty ? null : item);
    _notifySelectionChanged();
  }

  void _enterSelectMode() =>
      setState(() => _selectionMode = SelectionMode.multi);

  void _exitSelectMode() {
    setState(() {
      _selectionMode = SelectionMode.none;
      _selectedPaths.clear();
    });
    _notifySelectionChanged();
  }

  void _selectAll() {
    setState(() => _selectedPaths = _items.map((e) => e.path).toSet());
    _notifySelectionChanged();
  }

  void _deselectAll() {
    setState(() => _selectedPaths.clear());
    _notifySelectionChanged();
  }

  // ---------------------------------------------------------------------------
  // Selection / clipboard reporting to the parent (status bar)
  // ---------------------------------------------------------------------------

  /// Builds aggregate info about the current selection.
  SelectionInfo _computeSelectionInfo() {
    final selected = _items
        .where((i) => _selectedPaths.contains(i.path))
        .toList();
    final total = selected.fold<int>(
      0,
      (sum, i) => sum + (i.isDirectory ? 0 : i.size),
    );
    return SelectionInfo(
      count: _selectedPaths.length,
      totalSizeBytes: total,
      items: selected,
    );
  }

  void _notifySelectionChanged() {
    widget.onSelectionChanged?.call(_computeSelectionInfo());
  }

  /// Reports clipboard state to the parent (status bar indicator).
  void _setClipboardInfo(ClipboardInfo info) {
    widget.onClipboardChanged?.call(info);
  }

  // ---------------------------------------------------------------------------
  // In-place rename (F2)
  // ---------------------------------------------------------------------------

  void _startInPlaceRename() {
    if (_selectedPaths.length == 1) {
      final path = _selectedPaths.first;
      final idx = _items.indexWhere((i) => i.path == path);
      if (idx >= 0) _initiateRename(idx);
    } else if (_items.isNotEmpty) {
      _selectedPaths.add(_items.first.path);
      _startInPlaceRename();
    }
  }

  void _initiateRename(int index) {
    _renamingIndex = index;
    final item = _items[index];
    final ext = item.isDirectory ? '' : p.extension(item.name);
    final nameWithoutExt = item.name.substring(
      0,
      item.name.length - ext.length,
    );
    _renameController.text = nameWithoutExt;
    _renameFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: nameWithoutExt.length,
      );
    });
  }

  void _cancelInPlaceRename() {
    _renamingIndex = null;
    _renameController.clear();
    _renameFocusNode.unfocus();
  }

  Future<void> _finishInPlaceRename() async {
    if (_renamingIndex == null) return;
    final item = _items[_renamingIndex!];
    final newName = _renameController.text.trim();
    if (newName.isEmpty || newName == item.name) {
      _cancelInPlaceRename();
      return;
    }
    try {
      await FileUtils.rename(item.path, newName);
      if (mounted) _loadDirectory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rename failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
    _cancelInPlaceRename();
  }

  /// Returns true when a keyboard shortcut was handled.
  bool _handleKeyboardShortcut(KeyEvent event) {
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    // Some Android hardware-keyboard stacks deliver Ctrl+C/X/V as character
    // events instead of a logical key + ctrl modifier.
    final ch = event.character;

    if (ctrl && ch != null) {
      switch (ch) {
        case '\u0003': // Ctrl+C
          if (_selectedPaths.isNotEmpty) {
            _copySelected();
            return true;
          }
          return false;
        case '\u0018': // Ctrl+X
          if (_selectedPaths.isNotEmpty) {
            _cutSelected();
            return true;
          }
          return false;
        case '\u0016': // Ctrl+V
          _pasteToCurrent();
          return true;
        case '\u0001': // Ctrl+A
          _selectAll();
          return true;
      }
    }
    if (ctrl) {
      switch (key) {
        case LogicalKeyboardKey.keyC:
          if (_selectedPaths.isNotEmpty) {
            _copySelected();
            return true;
          }
          return false;
        case LogicalKeyboardKey.keyX:
          if (_selectedPaths.isNotEmpty) {
            _cutSelected();
            return true;
          }
          return false;
        case LogicalKeyboardKey.keyV:
          _pasteToCurrent();
          return true;
        case LogicalKeyboardKey.keyA:
          _selectAll();
          return true;
        case LogicalKeyboardKey.keyL:
          _showGoToPathDialog();
          return true;
        case LogicalKeyboardKey.keyN:
          _showNewFolderDialog();
          return true;
        case LogicalKeyboardKey.keyH:
          setState(() => _showHidden = !_showHidden);
          _loadDirectory();
          return true;
        case LogicalKeyboardKey.digit1:
          setState(() => _viewMode = ViewMode.details);
          return true;
        case LogicalKeyboardKey.digit2:
          setState(() => _viewMode = ViewMode.grid);
          return true;
        default:
          break;
      }
    }
    if (alt) {
      switch (key) {
        case LogicalKeyboardKey.arrowUp:
          _goUp();
          return true;
        case LogicalKeyboardKey.arrowLeft:
          _goBack();
          return true;
        case LogicalKeyboardKey.arrowRight:
          _goForward();
          return true;
        default:
          break;
      }
    }
    switch (key) {
      case LogicalKeyboardKey.f2:
        _startInPlaceRename();
        return true;
      case LogicalKeyboardKey.f4:
        _openTerminalHere(_currentPath);
        return true;
      case LogicalKeyboardKey.f5:
        _loadDirectory();
        return true;
      case LogicalKeyboardKey.backspace:
        _goUp();
        return true;
      case LogicalKeyboardKey.enter:
        if (_renamingIndex != null) {
          _finishInPlaceRename();
        } else if (_selectedPaths.length == 1) {
          final item = _items.firstWhere(
            (i) => _selectedPaths.contains(i.path),
            orElse: () => _items.first,
          );
          _openItem(item);
        } else if (_items.isNotEmpty) {
          _toggleSelection(_items.first.path);
        }
        return true;
      case LogicalKeyboardKey.delete:
        _deleteSelected();
        return true;
      case LogicalKeyboardKey.escape:
        if (_renamingIndex != null) {
          _cancelInPlaceRename();
        } else {
          _exitSelectMode();
        }
        return true;
      default:
        return false;
    }
  }

  // --- Navigation history & misc shortcut helpers ---

  void _goBack() {
    if (_historyIndex > 0) {
      _historyIndex--;
      _loadDirectory(path: _history[_historyIndex], pushHistory: false);
    }
  }

  void _goForward() {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _loadDirectory(path: _history[_historyIndex], pushHistory: false);
    }
  }

  void _pasteToCurrent() {
    if (!FileUtils.hasClipboard) return;
    FileUtils.paste(_currentPath).then((_) {
      if (!mounted) return;
      // A 'cut' paste consumes the clipboard; a 'copy' paste keeps it.
      _setClipboardInfo(
        FileUtils.hasClipboard
            ? ClipboardInfo(
                hasClipboard: true,
                operation: FileUtils.clipboardOperation ?? 'copy',
                count: 1,
              )
            : const ClipboardInfo.empty(),
      );
      _loadDirectory();
    });
  }

  /// Opens a Termux session at [path] (Linux F4 equivalent). Shows install
  /// instructions when Termux is unavailable.
  Future<void> _openTerminalHere(String path) async {
    final launched = await TerminalService.openTerminalAt(path);
    if (launched || !mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text(
          'Open Terminal',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This feature uses Termux. Open Termux and run:',
              style: TextStyle(color: OneDarkColors.fg),
            ),
            const SizedBox(height: 8),
            Text(
              "cd '$path' && bash",
              style: const TextStyle(
                color: OneDarkColors.cyan,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Prerequisites: Termux installed with "Allow external apps" enabled.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              if (!mounted) return;
              Navigator.pop(context);
              final termuxUri = Uri.parse(
                'https://f-droid.org/packages/com.termux/',
              );
              if (await canLaunchUrl(termuxUri)) {
                await launchUrl(termuxUri);
              }
            },
            child: const Text('Install Termux'),
          ),
        ],
      ),
    );
  }

  /// Ctrl+L: jump to a typed path.
  void _showGoToPathDialog() {
    final controller = TextEditingController(text: _currentPath);
    showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text(
          'Go to path',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: OneDarkColors.fg),
          decoration: const InputDecoration(
            labelText: 'Path',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Go'),
          ),
        ],
      ),
    ).then((path) {
      if (path is String && path.isNotEmpty) {
        _loadDirectory(path: path);
      }
      _focusNode.requestFocus();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedPaths.isEmpty) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete ${_selectedPaths.length} items?',
          style: const TextStyle(color: OneDarkColors.fg),
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
            child: const Text(
              'Delete',
              style: TextStyle(color: OneDarkColors.red),
            ),
          ),
        ],
      ),
    );
    if (choice == 'trash' && mounted) {
      for (final path in _selectedPaths.toList()) {
        try {
          await FileUtils.moveToTrash(path);
        } catch (_) {}
      }
      _selectedPaths.clear();
      _notifySelectionChanged();
      if (mounted) _loadDirectory();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
    } else if (choice == 'delete' && mounted) {
      for (final path in _selectedPaths.toList()) {
        try {
          await FileUtils.delete(path);
        } catch (_) {}
      }
      _selectedPaths.clear();
      _notifySelectionChanged();
      if (mounted) _loadDirectory();
    }
  }

  void _copySelected() {
    for (final path in _selectedPaths) {
      FileUtils.setClipboard(path, 'copy');
    }
    _setClipboardInfo(
      ClipboardInfo(
        hasClipboard: true,
        operation: 'copy',
        count: _selectedPaths.length,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_selectedPaths.length} item(s) copied'),
        backgroundColor: OneDarkColors.cyan,
      ),
    );
  }

  void _cutSelected() {
    for (final path in _selectedPaths) {
      FileUtils.setClipboard(path, 'cut');
    }
    _setClipboardInfo(
      ClipboardInfo(
        hasClipboard: true,
        operation: 'cut',
        count: _selectedPaths.length,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_selectedPaths.length} item(s) cut'),
        backgroundColor: OneDarkColors.amber,
      ),
    );
  }

  void _batchRename() {
    if (_selectedPaths.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) =>
          _BatchRenameDialog(selectedPaths: _selectedPaths.toList()),
    ).then((_) {
      if (mounted) _loadDirectory();
    });
  }

  /// Extracts [path] either into the current directory (Linux "Extract Here"
  /// semantics) or into a subfolder named after the archive.
  Future<void> _extractArchive(String path, {bool toSubfolder = true}) async {
    final destDir = toSubfolder
        ? p.join(p.dirname(path), p.basenameWithoutExtension(path))
        : p.dirname(path);
    try {
      await ArchiveService.extract(path, destDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              toSubfolder
                  ? 'Extracted to ${p.basename(destDir)}'
                  : 'Extracted to current folder',
            ),
            backgroundColor: OneDarkColors.green,
          ),
        );
        _loadDirectory();
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
  }

  /// Compresses [paths] into an archive (ZIP / TAR / TAR.GZ).
  ///
  /// Prompts for the archive name and format, appending the matching
  /// extension to the name when the user hasn't typed one explicitly.
  Future<void> _compressSelection(List<String> paths) async {
    if (paths.isEmpty) return;
    final controller = TextEditingController(
      text: paths.length == 1
          ? p.basenameWithoutExtension(paths.first)
          : 'archive',
    );
    ArchiveFormat format = ArchiveFormat.zip;

    String suffixFor(ArchiveFormat f) =>
        f == ArchiveFormat.tarGz ? '.tar.gz' : '.${f.name}';

    final result = await showDialog<(String, ArchiveFormat)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) {
          void onFormatChanged(ArchiveFormat f) {
            final current = controller.text;
            // Strip any known archive extension before re-appending the new one.
            String base = current;
            if (base.endsWith('.tar.gz')) {
              base = base.substring(0, base.length - '.tar.gz'.length);
            } else if (base.endsWith('.zip') || base.endsWith('.tar')) {
              base = base.substring(0, base.lastIndexOf('.'));
            }
            setDialogState(() {
              format = f;
              controller.text = base + suffixFor(f);
            });
          }

          return AlertDialog(
            backgroundColor: OneDarkColors.bg,
            title: const Text(
              'Compress Selection',
              style: TextStyle(color: OneDarkColors.fg),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: OneDarkColors.fg),
                  decoration: const InputDecoration(
                    labelText: 'Archive name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Format',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                ),
                const SizedBox(height: 8),
                SegmentedButton<ArchiveFormat>(
                  segments: const [
                    ButtonSegment(
                      value: ArchiveFormat.zip,
                      label: Text('ZIP'),
                      icon: Icon(Icons.archive),
                    ),
                    ButtonSegment(
                      value: ArchiveFormat.tar,
                      label: Text('TAR'),
                      icon: Icon(Icons.folder_zip),
                    ),
                    ButtonSegment(
                      value: ArchiveFormat.tarGz,
                      label: Text('TAR.GZ'),
                      icon: Icon(Icons.compress),
                    ),
                  ],
                  selected: {format},
                  onSelectionChanged: (s) => onFormatChanged(s.first),
                  style: ButtonStyle(
                    foregroundColor: WidgetStatePropertyAll(OneDarkColors.fg),
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? OneDarkColors.select
                          : OneDarkColors.dim,
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
                onPressed: () => Navigator.pop(dialogContext, (
                  controller.text.trim(),
                  format,
                )),
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;
    final (name, fmt) = result;
    if (name.isEmpty) return;
    final outputPath = p.join(p.dirname(paths.first), name);
    try {
      switch (fmt) {
        case ArchiveFormat.zip:
          await ArchiveService.createZip(
            outputPath: outputPath,
            sources: paths,
          );
        case ArchiveFormat.tar:
          await ArchiveService.createTar(
            outputPath: outputPath,
            sources: paths,
          );
        case ArchiveFormat.tarGz:
          await ArchiveService.createTarGz(
            outputPath: outputPath,
            sources: paths,
          );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Created $name'),
            backgroundColor: OneDarkColors.green,
          ),
        );
        _loadDirectory();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Compression failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
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
              if (item.isDirectory) ...[
                const SizedBox(height: 4),
                _buildFolderSizeFutureBuilder(item),
              ],
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

  Widget _buildFolderSizeFutureBuilder(FileItem folder) {
    return FutureBuilder<int>(
      future: _computeFolderSize(folder),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  'Size',
                  style: const TextStyle(
                    color: OneDarkColors.fgDim,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: const Row(
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Calculating...',
                      style: TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        final size = snapshot.hasData && snapshot.data! >= 0
            ? snapshot.data!
            : folder.size;
        return Row(
          children: [
            SizedBox(
              width: 80,
              child: Text(
                'Size',
                style: const TextStyle(
                  color: OneDarkColors.fgDim,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Text(
                _formatBytes(size),
                style: const TextStyle(color: OneDarkColors.fg, fontSize: 12),
              ),
            ),
          ],
        );
      },
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
              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: OneDarkColors.fg, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(FileItem item, [Offset? tapPosition]) {
    final box = context.findRenderObject() as RenderBox?;
    final RenderBox? parentBox = box?.parent as RenderBox?;
    RelativeRect? position;
    if (tapPosition != null && parentBox != null) {
      position = RelativeRect.fromLTRB(
        tapPosition.dx,
        tapPosition.dy,
        parentBox.paintBounds.width - tapPosition.dx,
        parentBox.paintBounds.height - tapPosition.dy,
      );
    } else if (box != null && parentBox != null) {
      final offset = box.localToGlobal(Offset.zero);
      position = RelativeRect.fromLTRB(
        offset.dx,
        offset.dy,
        parentBox.paintBounds.width - offset.dx - 200,
        parentBox.paintBounds.height - offset.dy - 240,
      );
    }
    showMenu(
      context: context,
      position: position,
      items: <PopupMenuEntry<Object?>>[
        _menuItem('Open', Icons.open_in_new, () => _openItem(item)),
        if (!item.isDirectory)
          _menuItem(
            'Open With…',
            Icons.open_with,
            () => _showOpenWithMenu(item),
          ),
        _menuItem(
          'Open Terminal Here',
          Icons.terminal,
          () => _openTerminalHere(item.path),
        ),
        const PopupMenuDivider(),
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
        if (FileUtils.hasClipboard)
          _menuItem('Paste here', Icons.content_paste, () async {
            final destDir = item.isDirectory ? item.path : p.dirname(item.path);
            await FileUtils.paste(destDir);
            if (mounted) _loadDirectory();
          }),
        const PopupMenuDivider(),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(item)),
        _menuItem('Delete', Icons.delete, () => _confirmDelete(item)),
        if (ArchiveService.isArchive(item.path)) ...[
          _menuItem(
            'Extract Here',
            Icons.folder_open,
            () => _extractArchive(item.path, toSubfolder: false),
          ),
          _menuItem(
            'Extract to Subfolder…',
            Icons.create_new_folder,
            () => _extractArchive(item.path, toSubfolder: true),
          ),
        ],
        _menuItem(
          'Compress…',
          Icons.archive,
          () => _compressSelection([item.path]),
        ),
        const PopupMenuDivider(),
        if (item.isMarkdown)
          _menuItem('Convert…', Icons.transform, () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConvertDialog(filePath: item.path),
              ),
            );
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
          Text(title, style: const TextStyle(color: OneDarkColors.fg)),
        ],
      ),
    );
  }

  /// Shows a nested "Open With" menu with app options for a file.
  void _showOpenWithMenu(FileItem item) {
    final box = context.findRenderObject() as RenderBox?;
    final RenderBox? parentBox = box?.parent as RenderBox?;
    if (box == null || parentBox == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final isText =
        !item.isDirectory && _kTextExtensions.contains(item.extension);

    final entries = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: 'default',
        child: Row(
          children: [
            Icon(Icons.open_in_new, size: 16, color: OneDarkColors.fg),
            const SizedBox(width: 8),
            const Text('Open with default app'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'chooser',
        child: Row(
          children: [
            Icon(Icons.apps, size: 16, color: OneDarkColors.fg),
            const SizedBox(width: 8),
            const Text('Choose another app…'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      if (isText)
        PopupMenuItem(
          value: 'termux',
          child: Row(
            children: [
              Icon(Icons.terminal, size: 16, color: OneDarkColors.fg),
              const SizedBox(width: 8),
              const Text('Open in Termux'),
            ],
          ),
        ),
      PopupMenuItem(
        value: 'copy',
        child: Row(
          children: [
            Icon(Icons.copy, size: 16, color: OneDarkColors.fg),
            const SizedBox(width: 8),
            const Text('Copy file path'),
          ],
        ),
      ),
    ];

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx + 200,
        offset.dy + 100,
        parentBox.paintBounds.width - offset.dx - 200,
        parentBox.paintBounds.height - offset.dy - 100,
      ),
      items: entries,
    ).then((value) async {
      if (value == null || !mounted) return;
      switch (value) {
        case 'default':
          try {
            await OpenWithService.openDefault(item.path);
          } catch (e) {
            _openFailed(e);
          }
          break;
        case 'chooser':
          try {
            await OpenWithService.openWithChooser(item.path);
          } catch (e) {
            _openFailed(e);
          }
          break;
        case 'termux':
          _openTerminalHere(p.dirname(item.path));
          break;
        case 'copy':
          await Clipboard.setData(ClipboardData(text: item.path));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Path copied'),
              backgroundColor: OneDarkColors.green,
            ),
          );
          break;
      }
    });
  }

  /// Shows an error snackbar for a failed open-with launch.
  void _openFailed(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Cannot open: $e'),
        backgroundColor: OneDarkColors.red,
      ),
    );
  }

  void _showRenameDialog(FileItem item) {
    final controller = TextEditingController(text: item.name);
    final ext = item.isDirectory ? '' : p.extension(item.name);
    final nameWithoutExt = item.name.substring(
      0,
      item.name.length - ext.length,
    );
    // Select just the filename part (without extension) for easy editing
    final focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: nameWithoutExt.length,
      );
      focusNode.requestFocus();
    });
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(color: OneDarkColors.fg),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: ext.isNotEmpty ? ext : null,
            suffixStyle: const TextStyle(color: OneDarkColors.fgDim),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!mounted) return;
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != item.name) {
                try {
                  await FileUtils.rename(item.path, newName);
                  if (mounted) _loadDirectory();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Rename failed: $e'),
                        backgroundColor: OneDarkColors.red,
                      ),
                    );
                  }
                }
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
          style: const TextStyle(color: OneDarkColors.fg),
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
            child: const Text(
              'Delete',
              style: TextStyle(color: OneDarkColors.red),
            ),
          ),
        ],
      ),
    );
    if (choice == 'trash' && mounted) {
      try {
        await FileUtils.moveToTrash(item.path);
      } catch (_) {}
      if (mounted) {
        _loadDirectory();
        _exitSelectMode();
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
    } else if (choice == 'delete' && mounted) {
      await FileUtils.delete(item.path);
      if (mounted) {
        _loadDirectory();
        _exitSelectMode();
      }
    }
  }

  void _showNewFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text(
          'New Folder',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: OneDarkColors.fg),
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                try {
                  await FileUtils.createDirectory(p.join(_currentPath, name));
                  if (mounted) _loadDirectory();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed: $e'),
                        backgroundColor: OneDarkColors.red,
                      ),
                    );
                  }
                }
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showNewFileDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text(
          'New File',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: OneDarkColors.fg),
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'File name (e.g. notes.txt)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                try {
                  await File(p.join(_currentPath, name)).create();
                  if (mounted) _loadDirectory();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed: $e'),
                        backgroundColor: OneDarkColors.red,
                      ),
                    );
                  }
                }
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final inSelectMode = _selectionMode == SelectionMode.multi;
    return Container(
      color: OneDarkColors.bgDark,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: OneDarkColors.fg),
              onPressed: _historyIndex > 0 ? _goBack : null,
              tooltip: 'Back',
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward, color: OneDarkColors.fg),
              onPressed: _currentPath != '/' ? _goUp : null,
              tooltip: 'Go up one level',
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward, color: OneDarkColors.fg),
              onPressed: _historyIndex < _history.length - 1
                  ? _goForward
                  : null,
              tooltip: 'Forward',
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 320),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: OneDarkColors.dim,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_open,
                      size: 16,
                      color: OneDarkColors.cyan,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _currentPath,
                        style: const TextStyle(
                          color: OneDarkColors.fg,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (!inSelectMode) ...[
              IconButton(
                icon: const Icon(
                  Icons.create_new_folder,
                  color: OneDarkColors.fgDim,
                ),
                onPressed: _showNewFolderDialog,
                tooltip: 'New Folder',
              ),
              IconButton(
                icon: const Icon(Icons.note_add, color: OneDarkColors.fgDim),
                onPressed: _showNewFileDialog,
                tooltip: 'New File',
              ),
              IconButton(
                icon: const Icon(Icons.edit, color: OneDarkColors.cyan),
                onPressed: _startInPlaceRename,
                tooltip: 'Rename (F2)',
              ),
            ],
            if (inSelectMode)
              IconButton(
                icon: const Icon(Icons.check, color: OneDarkColors.green),
                onPressed: _exitSelectMode,
                tooltip: 'Done',
              )
            else
              IconButton(
                icon: const Icon(Icons.select_all, color: OneDarkColors.fgDim),
                onPressed: _enterSelectMode,
                tooltip: 'Select',
              ),
            if (inSelectMode)
              IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  color: OneDarkColors.red,
                ),
                onPressed: _deleteSelected,
                tooltip: 'Delete selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: const Icon(Icons.copy, color: OneDarkColors.cyan),
                onPressed: _copySelected,
                tooltip: 'Copy selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: const Icon(Icons.content_cut, color: OneDarkColors.amber),
                onPressed: _cutSelected,
                tooltip: 'Cut selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: const Icon(Icons.edit_note, color: OneDarkColors.cyan),
                onPressed: _batchRename,
                tooltip: 'Batch rename',
              ),
            if (inSelectMode)
              IconButton(
                icon: const Icon(Icons.archive, color: OneDarkColors.green),
                onPressed: () => _compressSelection(_selectedPaths.toList()),
                tooltip: 'Compress…',
              ),
            if (inSelectMode)
              PopupMenuButton<bool>(
                icon: const Icon(Icons.tune, color: OneDarkColors.fgDim),
                onSelected: (v) => v ? _selectAll() : _deselectAll(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: true, child: const Text('Select All')),
                  PopupMenuItem(
                    value: false,
                    child: const Text('Deselect All'),
                  ),
                ],
              ),
            if (!inSelectMode && FileUtils.hasClipboard)
              IconButton(
                icon: const Icon(
                  Icons.content_paste,
                  color: OneDarkColors.green,
                ),
                onPressed: _pasteToCurrent,
                tooltip: 'Paste',
              ),
            _buildSortButton(),
            _buildTypeFilterButton(),
            _buildDateFilterButton(),
            IconButton(
              icon: Icon(
                _showJunk ? Icons.cleaning_services : Icons.auto_fix_high,
                color: _showJunk ? OneDarkColors.amber : OneDarkColors.fgDim,
              ),
              onPressed: () => setState(() => _showJunk = !_showJunk),
              tooltip: _showJunk ? 'Showing junk files' : 'Hide junk files',
            ),
            IconButton(
              icon: Icon(
                _showHidden ? Icons.visibility : Icons.visibility_off,
                color: _showHidden ? OneDarkColors.cyan : OneDarkColors.fgDim,
              ),
              onPressed: () {
                setState(() => _showHidden = !_showHidden);
                _loadDirectory();
              },
            ),
            IconButton(
              icon: Icon(
                _viewMode == ViewMode.details
                    ? Icons.view_list
                    : Icons.grid_view,
                color: OneDarkColors.cyan,
              ),
              onPressed: () => setState(
                () => _viewMode = _viewMode == ViewMode.details
                    ? ViewMode.grid
                    : ViewMode.details,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortButton() {
    final icons = {
      SortOption.name: Icons.sort_by_alpha,
      SortOption.size: Icons.straighten,
      SortOption.date: Icons.calendar_today,
      SortOption.type: Icons.category,
    };
    final labels = {
      SortOption.name: 'Name',
      SortOption.size: 'Size',
      SortOption.date: 'Date',
      SortOption.type: 'Type',
    };
    return PopupMenuButton<SortOption>(
      icon: Icon(icons[_sortOption], color: OneDarkColors.fg),
      onSelected: (opt) {
        setState(() => _sortOption = opt);
        _loadDirectory();
      },
      itemBuilder: (_) => [
        ...SortOption.values.map(
          (opt) => PopupMenuItem(
            value: opt,
            child: Row(
              children: [
                Icon(icons[opt], size: 16, color: OneDarkColors.fg),
                const SizedBox(width: 8),
                Text(
                  '${labels[opt]!} ${_sortDir == SortDir.asc ? '↑' : '↓'}',
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          child: Text(
            _sortDir == SortDir.asc ? 'Descending' : 'Ascending',
            style: const TextStyle(color: OneDarkColors.fg),
          ),
          onTap: () {
            setState(
              () => _sortDir = _sortDir == SortDir.asc
                  ? SortDir.desc
                  : SortDir.asc,
            );
            _loadDirectory();
          },
        ),
      ],
    );
  }

  Widget _buildTypeFilterButton() {
    final labels = {
      FileTypeFilter.all: 'All Types',
      FileTypeFilter.images: 'Images',
      FileTypeFilter.videos: 'Videos',
      FileTypeFilter.audio: 'Audio',
      FileTypeFilter.documents: 'Documents',
      FileTypeFilter.archives: 'Archives',
      FileTypeFilter.discs: 'Discs/ISO',
    };
    final icons = {
      FileTypeFilter.all: Icons.filter_list,
      FileTypeFilter.images: Icons.image,
      FileTypeFilter.videos: Icons.movie,
      FileTypeFilter.audio: Icons.music_note,
      FileTypeFilter.documents: Icons.description,
      FileTypeFilter.archives: Icons.archive,
      FileTypeFilter.discs: Icons.storage,
    };
    return PopupMenuButton<FileTypeFilter>(
      icon: Icon(
        icons[_filterType],
        color: _filterType != FileTypeFilter.all
            ? OneDarkColors.cyan
            : OneDarkColors.fgDim,
      ),
      tooltip: 'Type filter',
      onSelected: (t) => setState(() => _filterType = t),
      itemBuilder: (_) => FileTypeFilter.values
          .map(
            (t) => PopupMenuItem(
              value: t,
              child: Row(
                children: [
                  Icon(
                    icons[t],
                    size: 16,
                    color: t == _filterType
                        ? OneDarkColors.cyan
                        : OneDarkColors.fg,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    labels[t]!,
                    style: TextStyle(
                      color: t == _filterType
                          ? OneDarkColors.cyan
                          : OneDarkColors.fg,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildDateFilterButton() {
    final hasFilter = _dateFrom != null || _dateTo != null;
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.calendar_month,
        color: hasFilter ? OneDarkColors.cyan : OneDarkColors.fgDim,
      ),
      tooltip: 'Date range filter',
      onSelected: (v) async {
        if (v == 'pick') {
          final now = DateTime.now();
          final picked = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2000),
            lastDate: now,
            initialDateRange: _dateFrom != null && _dateTo != null
                ? DateTimeRange(start: _dateFrom!, end: _dateTo!)
                : null,
          );
          if (picked != null) {
            setState(() {
              _dateFrom = picked.start;
              _dateTo = picked.end;
            });
          }
        } else if (v == 'clear') {
          setState(() {
            _dateFrom = null;
            _dateTo = null;
          });
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'pick', child: Text('Pick date range')),
        if (hasFilter)
          const PopupMenuItem(value: 'clear', child: Text('Clear date filter')),
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
      itemCount: _filteredItems.length,
      itemBuilder: (context, index) {
        final item = _filteredItems[index];
        final isSelected = _selectedPaths.contains(item.path);
        return GestureDetector(
          onLongPressStart: (details) =>
              _showContextMenu(item, details.globalPosition),
          onSecondaryTapDown: (details) =>
              _showContextMenu(item, details.globalPosition),
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
                  border: isSelected
                      ? Border.all(color: OneDarkColors.cyan, width: 1.5)
                      : null,
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
                        style: const TextStyle(
                          color: OneDarkColors.fg,
                          fontSize: 11,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (_selectionMode == SelectionMode.multi)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? OneDarkColors.cyan
                          : OneDarkColors.dim,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Icon(
                        isSelected ? Icons.check : Icons.circle_outlined,
                        size: 14,
                        color: isSelected ? Colors.black : OneDarkColors.fgDim,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailsView() {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4),
      itemCount: _filteredItems.length + 1,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) return _buildColumnHeaders();
        final item = _filteredItems[index - 1];
        // Show in-place rename row if active
        if (_renamingIndex == index - 1) {
          return _buildRenameRow(item, index - 1);
        }
        final isSelected = _selectedPaths.contains(item.path);
        return GestureDetector(
          onLongPressStart: (details) =>
              _showContextMenu(item, details.globalPosition),
          onSecondaryTapDown: (details) =>
              _showContextMenu(item, details.globalPosition),
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
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? OneDarkColors.cyan
                            : OneDarkColors.dim,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Icon(
                          isSelected ? Icons.check : Icons.circle_outlined,
                          size: 14,
                          color: isSelected
                              ? Colors.black
                              : OneDarkColors.fgDim,
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 20),
                Icon(item.icon, size: 18, color: item.iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      color: OneDarkColors.fg,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (item.isDirectory)
                  Flexible(
                    flex: 2,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.folder,
                          size: 11,
                          color: OneDarkColors.fgDim,
                        ),
                        const SizedBox(width: 2),
                        FutureBuilder<int>(
                          future: _computeFolderSize(item),
                          builder: (ctx, snap) {
                            if (snap.connectionState == ConnectionState.waiting)
                              return const SizedBox(
                                width: 30,
                                child: LinearProgressIndicator(minHeight: 4),
                              );
                            final s = snap.hasData && snap.data! >= 0
                                ? snap.data!
                                : 0;
                            return Text(
                              _formatBytes(s),
                              style: const TextStyle(
                                color: OneDarkColors.fgDim,
                                fontSize: 12,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    flex: 2,
                    child: Text(
                      item.formattedSize,
                      style: const TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Flexible(
                  flex: 3,
                  child: Text(
                    item.formattedDate,
                    style: const TextStyle(
                      color: OneDarkColors.fgDim,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(
                  flex: 1,
                  child: Text(
                    item.extension.isEmpty ? 'Folder' : item.extension,
                    style: const TextStyle(
                      color: OneDarkColors.fgDim,
                      fontSize: 12,
                    ),
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

  Widget _buildColumnHeaders() {
    return Row(
      children: [
        SizedBox(width: _selectionMode == SelectionMode.multi ? 42 : 28),
        Expanded(
          child: Text(
            'Name',
            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ),
        Flexible(
          flex: 2,
          child: Text(
            'Size',
            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ),
        Flexible(
          flex: 3,
          child: Text(
            'Date Modified',
            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ),
        Flexible(
          flex: 1,
          child: Text(
            'Type',
            style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// Builds the in-place rename row (shown when [_renamingIndex] is active).
  Widget _buildRenameRow(FileItem item, int index) {
    final isSelected = _selectedPaths.contains(item.path);
    return Container(
      color: isSelected
          ? OneDarkColors.select
          : OneDarkColors.dim.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          if (_selectionMode == SelectionMode.multi)
            InkWell(
              onTap: () => _toggleSelection(item.path),
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: isSelected ? OneDarkColors.cyan : OneDarkColors.dim,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Icon(
                    isSelected ? Icons.check : Icons.circle_outlined,
                    size: 14,
                    color: isSelected ? Colors.black : OneDarkColors.fgDim,
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: 20),
          Icon(item.icon, size: 18, color: item.iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _renameController,
              focusNode: _renameFocusNode,
              style: const TextStyle(color: OneDarkColors.fg, fontSize: 13),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                suffixText: item.isDirectory ? null : p.extension(item.name),
                suffixStyle: const TextStyle(color: OneDarkColors.fgDim),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              onSubmitted: (_) => _finishInPlaceRename(),
            ),
          ),
          if (item.isDirectory)
            Flexible(
              flex: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder, size: 11, color: OneDarkColors.fgDim),
                  const SizedBox(width: 2),
                  FutureBuilder<int>(
                    future: _computeFolderSize(item),
                    builder: (ctx, snap) {
                      if (snap.connectionState == ConnectionState.waiting)
                        return const SizedBox(
                          width: 30,
                          child: LinearProgressIndicator(minHeight: 4),
                        );
                      final s = snap.hasData && snap.data! >= 0
                          ? snap.data!
                          : 0;
                      return Text(
                        _formatBytes(s),
                        style: const TextStyle(
                          color: OneDarkColors.fgDim,
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
                ],
              ),
            )
          else
            Flexible(
              flex: 2,
              child: Text(
                item.formattedSize,
                style: const TextStyle(
                  color: OneDarkColors.fgDim,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Flexible(
            flex: 3,
            child: Text(
              item.formattedDate,
              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Flexible(
            flex: 1,
            child: Text(
              item.extension.isEmpty ? 'Folder' : item.extension,
              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.f2): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.f4): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.f5): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.backspace):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.escape):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.delete):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyH, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            const ActivateIntent(),
      },
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (_handleKeyboardShortcut(event)) return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            _buildToolbar(),
            if (_isLoading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              Expanded(
                child: GestureDetector(
                  onLongPressStart: (details) {
                    // Only show if tap is on the background (not on an item)
                    _showBackgroundContextMenu(details.globalPosition);
                  },
                  child: _viewMode == ViewMode.details
                      ? _buildDetailsView()
                      : _buildGridView(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showBackgroundContextMenu(Offset position) {
    final box = context.findRenderObject() as RenderBox?;
    final RenderBox? parentBox = box?.parent as RenderBox?;
    if (box == null || parentBox == null) return;
    final offset = box.localToGlobal(Offset.zero);
    // Check if tap is in the lower 20% of the view (likely background area)
    if (position.dy < offset.dy + box.size.height * 0.8) return;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        parentBox.paintBounds.width - position.dx,
        parentBox.paintBounds.height - position.dy,
      ),
      items: <PopupMenuEntry<Object?>>[
        _menuItem(
          'Open Terminal Here',
          Icons.terminal,
          () => _openTerminalHere(_currentPath),
        ),
        const PopupMenuDivider(),
        _menuItem('New Folder', Icons.create_new_folder, _showNewFolderDialog),
        _menuItem('New File', Icons.note_add, _showNewFileDialog),
        const PopupMenuDivider(),
        if (FileUtils.hasClipboard)
          _menuItem('Paste', Icons.content_paste, () async {
            await FileUtils.paste(_currentPath);
            if (mounted) _loadDirectory();
          }),
        _menuItem('Select All', Icons.select_all, _selectAll),
        _menuItem('Refresh', Icons.refresh, () => _loadDirectory()),
      ],
    );
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
          newName = name.replaceAll(
            RegExp(_regexController.text),
            _replacementController.text,
          );
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
      title: Text(
        'Batch Rename (${widget.selectedPaths.length})',
        style: const TextStyle(color: OneDarkColors.fg),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'prefix',
                    label: Text('Prefix'),
                    icon: Icon(Icons.text_fields, size: 16),
                  ),
                  ButtonSegment(
                    value: 'suffix',
                    label: Text('Suffix'),
                    icon: Icon(Icons.text_format, size: 16),
                  ),
                  ButtonSegment(
                    value: 'regex',
                    label: Text('Regex'),
                    icon: Icon(Icons.functions, size: 16),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(height: 12),
              if (_mode == 'prefix') ...[
                TextField(
                  controller: _prefixController,
                  decoration: const InputDecoration(
                    labelText: 'Prefix',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ] else if (_mode == 'suffix') ...[
                TextField(
                  controller: _suffixController,
                  decoration: const InputDecoration(
                    labelText: 'Suffix',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ] else ...[
                TextField(
                  controller: _regexController,
                  decoration: const InputDecoration(
                    labelText: 'Regex pattern',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _replacementController,
                  decoration: const InputDecoration(
                    labelText: 'Replacement',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Preview:',
                style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
              ),
              const Divider(height: 1),
              ..._previewEntries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.key,
                          style: const TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: OneDarkColors.fgDim,
                      ),
                      Expanded(
                        child: Text(
                          e.value,
                          style: const TextStyle(
                            color: OneDarkColors.green,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            for (final entry in _previewEntries) {
              if (entry.key != entry.value) {
                try {
                  await FileUtils.rename(entry.key, entry.value);
                } catch (_) {}
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
