import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme.dart';
import '../screens/video_player_screen.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/pdf_reader_screen.dart';
import '../screens/docx_reader_screen.dart';
import '../screens/music_player_screen.dart';
import '../screens/notepad_screen.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'dart:typed_data';
import '../services/widget_service.dart';
import '../utils/file_utils.dart';
import '../services/archive_service.dart';
import '../services/open_with_service.dart';
import '../services/installer_service.dart';
import '../services/share_service.dart';
import '../screens/terminal_screen.dart';
import '../screens/folder_graph_screen.dart';
import '../screens/lan_screen.dart';
import '../screens/archive_browser_screen.dart';
import 'preview_panel.dart';
import 'convert_dialog.dart';
import 'package:path/path.dart' as p;

enum ViewMode { details, grid }

/// Persisted default view mode — Settings → "Default View" writes here,
/// every FileBrowser instance follows it live.
final ValueNotifier<ViewMode> viewModeNotifier = ValueNotifier<ViewMode>(
  ViewMode.details,
);

/// Shared toggle for showing hidden (dotfile) entries — the toolbar button
/// and the Settings screen both write to this notifier.
final ValueNotifier<bool> showHiddenNotifier = ValueNotifier<bool>(false);

/// When enabled, navigation and search are allowed into the normally blocked
/// system directories (/proc, /sys, /dev, …). Defaults off.
final ValueNotifier<bool> rootModeNotifier = ValueNotifier<bool>(false);

const String kViewModePref = 'swordfm_default_view';
const String kRootModePref = 'swordfm_root_mode';

Future<void> loadPersistedViewMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    viewModeNotifier.value = prefs.getString(kViewModePref) == 'grid'
        ? ViewMode.grid
        : ViewMode.details;
  } catch (_) {}
}

Future<void> savePersistedViewMode(ViewMode mode) async {
  viewModeNotifier.value = mode;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kViewModePref,
      mode == ViewMode.grid ? 'grid' : 'details',
    );
  } catch (_) {}
}

Future<void> loadPersistedRootMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    rootModeNotifier.value = prefs.getBool(kRootModePref) ?? false;
  } catch (_) {}
}

Future<void> savePersistedRootMode(bool enabled) async {
  rootModeNotifier.value = enabled;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kRootModePref, enabled);
  } catch (_) {}
}

enum SortOption { name, size, date, type }

enum SortDir { asc, desc }

enum SelectionMode { none, multi }

enum FileTypeFilter { all, images, videos, audio, documents, archives, discs }

/// Archive formats supported by the "Compress…" dialog.
enum ArchiveFormat { zip, tar, tarGz, tarXz, tarBz2 }

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

const Set<String> _kVideoExtensions = {
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.wmv',
  '.flv',
  '.webm',
  '.m4v',
  '.3gp',
  '.3g2',
  '.mts',
  '.m2ts',
  '.ts',
  '.vob',
  '.ogv',
  '.rm',
  '.rmvb',
  '.asf',
  '.divx',
};

const Set<String> _kAudioExtensions = {
  '.mp3',
  '.wav',
  '.flac',
  '.aac',
  '.ogg',
  '.wma',
  '.m4a',
  '.opus',
  '.aiff',
  '.ape',
  '.alac',
  '.mid',
  '.midi',
  '.amr',
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

  /// Called when the mark count changes (for status bar indicator).
  final ValueChanged<int>? onMarksChanged;

  /// Called when the number of items in the current directory changes
  /// (for the sidebar item-count status).
  final ValueChanged<int>? onItemCountChanged;

  /// Called when the user bookmarks the current folder (toolbar star /
  /// context-menu "Bookmark This Folder"). Receives the folder path.
  final ValueChanged<String>? onBookmarkCurrentPath;

  const FileBrowser({
    super.key,
    required this.initialPath,
    required this.onItemSelected,
    this.onSelectionChanged,
    this.onClipboardChanged,
    this.onPathChanged,
    this.onMarksChanged,
    this.onItemCountChanged,
    this.onBookmarkCurrentPath,
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

  void _setViewMode(ViewMode mode) {
    setState(() => _viewMode = mode);
    savePersistedViewMode(mode);
  }

  SortOption _sortOption = SortOption.name;
  SortDir _sortDir = SortDir.asc;
  SelectionMode _selectionMode = SelectionMode.none;
  // ignore: prefer_final_fields — mutated via setState
  Set<String> _selectedPaths = {};
  final Set<String> _markedPaths =
      {}; // persistent mark state across directory changes
  /// When true, tapping any item toggles its mark (like the top "Select"
  /// button) — entered after marking an item via long-press so the user can
  /// continue marking other documents by tapping them.
  bool _markMode = false;
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
    _viewMode = viewModeNotifier.value;
    _showHidden = showHiddenNotifier.value;
    // Follow the persisted "Default View" setting live.
    viewModeNotifier.addListener(_onViewModeNotifier);
    showHiddenNotifier.addListener(_onShowHiddenNotifier);
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
    viewModeNotifier.removeListener(_onViewModeNotifier);
    showHiddenNotifier.removeListener(_onShowHiddenNotifier);
    _renameController.dispose();
    _renameFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onViewModeNotifier() {
    final mode = viewModeNotifier.value;
    if (mode != _viewMode) setState(() => _viewMode = mode);
  }

  void _onShowHiddenNotifier() {
    final val = showHiddenNotifier.value;
    if (val != _showHidden) {
      setState(() => _showHidden = val);
      _loadDirectory();
    }
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

  /// True when the type/date filter is active — the browser then searches the
  /// whole subtree (Linux: "find these anywhere under here").
  bool get _isRecursiveFilterActive =>
      _filterType != FileTypeFilter.all || _dateFrom != null || _dateTo != null;

  /// File-only predicate used by the recursive walk: directories are traversed
  /// but never shown as results (matching Linux filtered-search behaviour).
  bool _matchesTypeDate(FileItem item) {
    if (item.isDirectory) return false;
    if (_filterType != FileTypeFilter.all) {
      final exts = _kTypeExtensions[_filterType];
      if (exts != null && !exts.contains(item.extension.substring(1))) {
        return false;
      }
    }
    if (_dateFrom != null || _dateTo != null) {
      final d = item.lastModified;
      if (_dateFrom != null && d.isBefore(_dateFrom!)) return false;
      if (_dateTo != null && d.isAfter(_dateTo!.add(const Duration(days: 1))))
        return false;
    }
    return true;
  }

  Future<void> _loadDirectory({String? path, bool pushHistory = true}) async {
    if (path != null) {
      // Block navigation into system directories (matches Linux SwordFM).
      // Root Mode lifts the guard so /proc, /sys, /dev … can be browsed.
      if (!rootModeNotifier.value && isBlockedPath(path)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('System directory — enable Root Mode in Settings to browse'),
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
    try {
      final items = _isRecursiveFilterActive
          ? await FileUtils.listRecursiveFiltered(
              _currentPath,
              includeHidden: _showHidden,
              showJunk: _showJunk,
              keep: _matchesTypeDate,
            )
          : await FileUtils.listDirectory(
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
      widget.onItemCountChanged?.call(items.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      String msg = 'Could not open this folder';
      if (e.toString().contains('Permission denied') && rootModeNotifier.value) {
        msg = 'Access denied — you may need root privileges to view this folder.';
      } else if (e.toString().contains('Permission denied')) {
        msg = 'Access denied — please grant "All files access" in your device Settings.';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: OneDarkColors.red,
          duration: const Duration(seconds: 4),
        ),
      );
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

      final ext = item.extension.toLowerCase();
      // Video → built-in player
      if (_kVideoExtensions.contains(ext)) {
        _openVideo(item.path);
        return;
      }
      // Audio → built-in music player (with sibling playlist)
      if (_kAudioExtensions.contains(ext)) {
        await _openAudio(item);
        return;
      }
      // Text/code → notepad
      if (_kTextExtensions.contains(ext) && !item.isPdf) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NotepadScreen(filePath: item.path)),
        );
        return;
      }
      // PDF → built-in reader
      if (item.isPdf) {
        _openPdf(item.path);
        return;
      }
      // DOCX → built-in reader (headings, bold/italic, lists, tables, images)
      if (item.isDocx) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DocxReaderScreen(filePath: item.path),
          ),
        );
        WidgetService.addRecentFile(item.path);
        return;
      }
      // Images → built-in pinch-zoom viewer
      if (item.isImage) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(filePath: item.path),
          ),
        );
        WidgetService.addRecentFile(item.path);
        return;
      }
      // Everything else → external app
      try {
        await OpenWithService.openDefault(item.path);
      } catch (e) {
        _openFailed(e);
      }
      WidgetService.addRecentFile(item.path);
    }
  }

  /// Single-tap on a file: select it for the preview panel. On phones the
  /// side panel is hidden, so open the preview in a bottom sheet instead.
  /// Video/audio/PDF/images/DOCX open directly in their built-in readers.
  /// Only plain text/markdown/etc. use the preview bottom sheet.
  Future<void> _showFile(FileItem item) async {
    widget.onItemSelected(item);
    final ext = item.extension.toLowerCase();
    if (_kVideoExtensions.contains(ext)) {
      _openVideo(item.path);
      return;
    }
    if (_kAudioExtensions.contains(ext)) {
      await _openAudio(item);
      return;
    }
    // On mobile: open documents directly in fullscreen readers
    if (MediaQuery.of(context).size.width < 600) {
      if (ext == '.pdf') {
        _openPdf(item.path);
        return;
      }
      if (ext == '.docx') {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DocxReaderScreen(filePath: item.path)),
        );
        return;
      }
      if (item.isImage) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ImageViewerScreen(filePath: item.path)),
        );
        return;
      }
      // Text/markdown/code: show in bottom sheet with preview
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (sheetContext) => DraggableScrollableSheet(
          // Starts at 60% height like before; dragging the bar up expands the
          // preview (images/text/pdf/docx/md) to full screen, dragging down
          // dismisses it.
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 1.0,
          builder: (sheetContext, scrollController) => Container(
            decoration: BoxDecoration(
              color: OneDarkColors.bgDark,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                // Grab handle — drag up for fullscreen, down to close.
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: OneDarkColors.fgDim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: PreviewPanel(
                    item: item,
                    width: double.infinity,
                    onClose: () => Navigator.pop(sheetContext),
                    onSwipe: () {
                      Navigator.pop(sheetContext);
                      _openItem(item);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  void _openVideo(String path) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VideoPlayerScreen(filePath: path)),
    );
  }

  void _openPdf(String path) {
    // In-app reader (pinch-zoom, page nav, go-to-page). The old code handed
    // the file to an external app, which silently did nothing on devices
    // with no PDF viewer installed.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PdfReaderScreen(filePath: path)),
    );
  }

  /// Opens [item] in the music player, seeding a playlist with the other
  /// audio files in the same directory (the tapped file first if found).
  Future<void> _openAudio(FileItem item) async {
    final siblings = <String>[];
    try {
      final items = await FileUtils.listDirectory(_currentPath);
      for (final it in items) {
        if (_kAudioExtensions.contains(it.extension.toLowerCase())) {
          siblings.add(it.path);
        }
      }
    } catch (_) {}
    final index = siblings.indexOf(item.path);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MusicPlayerScreen(
          filePath: item.path,
          playlist: siblings,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
  }

  /// Shared tap handling for list/grid items: multi-select toggles the
  /// checkbox; folders keep select-then-open; a single tap on a file opens
  /// the preview (side panel on desktop, bottom sheet on phones).
  void _handleItemTap(FileItem item, bool isSelected) {
    if (_markMode) {
      // Mark mode: every tap toggles the mark so more documents can be marked
      // one after another (same affordance as the top "Select" button).
      _toggleMarkItem(item.path);
    } else if (_selectionMode == SelectionMode.multi) {
      _toggleSelection(item.path);
    } else if (item.isDirectory) {
      if (isSelected) {
        _openItem(item);
      } else {
        _toggleSelection(item.path);
      }
    } else {
      _showFile(item);
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
  // Marks (persistent across directory changes, Space to toggle)
  // ---------------------------------------------------------------------------

  /// Returns the paths to act on: marked items override selection.
  List<String> get _actionPaths =>
      _markedPaths.isNotEmpty ? _markedPaths.toList() : _selectedPaths.toList();

  void _toggleMarkSelection() {
    if (_selectedPaths.isEmpty) return;
    // If any selected item is unmarked, mark all; only unmark all if every
    // selected item is already marked (matching Linux SwordFM behaviour).
    final anyUnmarked = _selectedPaths.any((p) => !_markedPaths.contains(p));
    setState(() {
      for (final p in _selectedPaths) {
        if (anyUnmarked) {
          _markedPaths.add(p);
        } else {
          _markedPaths.remove(p);
        }
      }
    });
    _notifyMarksChanged();
  }

  /// Toggles the mark on a single item — used by the long-press context menu
  /// and by mark mode. Exits mark mode automatically when the last mark is
  /// cleared.
  void _toggleMarkItem(String path) {
    setState(() {
      if (_markedPaths.contains(path)) {
        _markedPaths.remove(path);
        if (_markedPaths.isEmpty) _markMode = false;
      } else {
        _markedPaths.add(path);
      }
    });
    _notifyMarksChanged();
  }

  void _clearMarks() {
    if (_markedPaths.isEmpty) return;
    setState(() {
      _markedPaths.clear();
      _markMode = false;
    });
    _notifyMarksChanged();
  }

  /// Marks every item currently visible in the folder (matching Linux
  /// SwordFM's "Marked → Mark all files").
  void _markAllInFolder() {
    final paths = _filteredItems.map((i) => i.path);
    setState(() => _markedPaths.addAll(paths));
    _notifyMarksChanged();
  }

  /// Inverts the mark on every item currently visible in the folder.
  void _invertMarks() {
    final paths = _filteredItems.map((i) => i.path).toSet();
    setState(() {
      for (final path in paths) {
        if (_markedPaths.contains(path)) {
          _markedPaths.remove(path);
        } else {
          _markedPaths.add(path);
        }
      }
    });
    _notifyMarksChanged();
  }

  void _notifyMarksChanged() {
    widget.onMarksChanged?.call(_markedPaths.length);
  }

  // ---------------------------------------------------------------------------
  // Selection / clipboard reporting to the parent (status bar)
  // ---------------------------------------------------------------------------

  /// Builds aggregate info about the current selection.
  /// Directories are recursively summed (matching Linux SwordFM behaviour).
  Future<SelectionInfo> _computeSelectionInfo() async {
    final selected = _items
        .where((i) => _selectedPaths.contains(i.path))
        .toList();
    int total = 0;
    for (final item in selected) {
      total += await FileItem.getTotalSize(item);
    }
    return SelectionInfo(
      count: _selectedPaths.length,
      totalSizeBytes: total,
      items: selected,
    );
  }

  void _notifySelectionChanged() async {
    final info = await _computeSelectionInfo();
    widget.onSelectionChanged?.call(info);
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
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final ch = event.character;

    // Ctrl+Shift+Space: clear all marks
    if (ctrl && shift && key == LogicalKeyboardKey.space) {
      _clearMarks();
      return true;
    }

    if (ctrl && ch != null) return _handleCtrlCharShortcuts(ch);
    if (ctrl) return _handleCtrlKeyShortcuts(key);
    if (alt) return _handleAltShortcuts(key);
    return _handlePlainKeyShortcuts(key);
  }

  bool _handleCtrlCharShortcuts(String ch) {
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
    return false;
  }

  bool _handleCtrlKeyShortcuts(LogicalKeyboardKey key) {
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
        _showHidden = !_showHidden;
        showHiddenNotifier.value = _showHidden;
        _loadDirectory();
        return true;
      case LogicalKeyboardKey.digit1:
        _setViewMode(ViewMode.details);
        return true;
      case LogicalKeyboardKey.digit2:
        _setViewMode(ViewMode.grid);
        return true;
      default:
        return false;
    }
  }

  bool _handleAltShortcuts(LogicalKeyboardKey key) {
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
        return false;
    }
  }

  bool _handlePlainKeyShortcuts(LogicalKeyboardKey key) {
    switch (key) {
      case LogicalKeyboardKey.space:
        _toggleMarkSelection();
        return true;
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
    FileUtils.paste(_currentPath)
        .then((_) {
          if (!mounted) return;
          // A 'cut' paste consumes the clipboard; a 'copy' paste keeps it.
          _setClipboardInfo(
            FileUtils.hasClipboard
                ? ClipboardInfo(
                    hasClipboard: true,
                    operation: FileUtils.clipboardOperation ?? 'copy',
                    count: FileUtils.clipboardCount,
                  )
                : const ClipboardInfo.empty(),
          );
          _clearMarks(); // auto-clear marks after paste (matching Linux SwordFM)
          _loadDirectory();
        })
        .catchError((Object e) {
          if (!mounted) return;
          final msg = e.toString().contains('Permission denied')
              ? 'Access denied — please grant "All files access" in Settings'
              : 'Paste failed: $e';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: OneDarkColors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        });
  }

  Future<void> _openTerminalHere(String path) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TerminalScreen(startPath: path)),
    );
  }

  /// Ctrl+L: jump to a typed path.
  void _showGoToPathDialog() {
    final controller = TextEditingController(text: _currentPath);
    showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Go to path', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: OneDarkColors.fg),
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
    final paths = _actionPaths;
    if (paths.isEmpty) return;
    // Honor the "Delete Confirmation" setting: when off, send straight to
    // trash without the dialog.
    if (!await FileUtils.loadDeleteConfirmation()) {
      for (final path in paths) {
        try {
          await FileUtils.moveToTrash(path);
        } catch (_) {}
      }
      _selectedPaths.clear();
      _markedPaths.removeAll(paths);
      _notifySelectionChanged();
      _notifyMarksChanged();
      if (mounted) _loadDirectory();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved ${paths.length} item(s) to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete ${paths.length} items?',
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
    if (choice == 'trash' && mounted) {
      for (final path in paths) {
        try {
          await FileUtils.moveToTrash(path);
        } catch (_) {}
      }
      _selectedPaths.clear();
      _markedPaths.removeAll(paths);
      _notifySelectionChanged();
      _notifyMarksChanged();
      if (mounted) _loadDirectory();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
    } else if (choice == 'delete' && mounted) {
      for (final path in paths) {
        try {
          await FileUtils.delete(path);
        } catch (_) {}
      }
      _selectedPaths.clear();
      _markedPaths.removeAll(paths);
      _notifySelectionChanged();
      _notifyMarksChanged();
      if (mounted) _loadDirectory();
    }
  }

  /// Shares [paths] (files only) through the Android share sheet.
  /// Directories are filtered out — the share sheet cannot share a folder.
  Future<void> _sharePaths(List<String> paths) async {
    final files = <String>[];
    for (final path in paths) {
      try {
        if (await FileSystemEntity.type(path) == FileSystemEntityType.file) {
          files.add(path);
        }
      } catch (_) {}
    }
    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Only files can be shared via the share sheet'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
      }
      return;
    }
    final ok = await ShareService.share(files);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Sharing ${files.length} item(s)…' : 'Share not available here',
        ),
        backgroundColor: ok ? OneDarkColors.cyan : OneDarkColors.red,
      ),
    );
  }

  /// Shares a folder over LAN: opens the LAN screen with this folder as
  /// the share root, so another device can browse/download it in a browser.
  void _shareFolderViaLan(String path) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF282C34),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Grab handle + title bar so the sheet is clearly draggable and
              // the LAN screen's controls (incl. its bottom action bar) get
              // the full remaining height.
              Container(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white54,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                child: const Text(
                  'LAN Share',
                  style: TextStyle(color: Color(0xFF61AFEF), fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: LANSharingScreen(initialShareRoot: path, server: null),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copySelected() {
    final paths = _actionPaths;
    FileUtils.setClipboardMultiple(paths, 'copy');
    _setClipboardInfo(
      ClipboardInfo(hasClipboard: true, operation: 'copy', count: paths.length),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${paths.length} item(s) copied'),
        backgroundColor: OneDarkColors.cyan,
      ),
    );
  }

  void _cutSelected() {
    final paths = _actionPaths;
    FileUtils.setClipboardMultiple(paths, 'cut');
    _setClipboardInfo(
      ClipboardInfo(hasClipboard: true, operation: 'cut', count: paths.length),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${paths.length} item(s) cut'),
        backgroundColor: OneDarkColors.amber,
      ),
    );
  }

  void _batchRename() {
    final paths = _actionPaths;
    if (paths.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => _BatchRenameDialog(selectedPaths: paths),
    ).then((_) {
      if (mounted) {
        _clearMarks();
        _loadDirectory();
      }
    });
  }

  /// Extracts [path] either into the current directory (Linux "Extract Here"
  /// semantics) or into a subfolder named after the archive.
  Future<void> _extractArchive(String path, {bool toSubfolder = true}) async {
    final destDir = toSubfolder
        ? p.join(p.dirname(path), p.basenameWithoutExtension(path))
        : p.dirname(path);
    // Show a loading dialog while extracting (can be slow for large archives).
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          backgroundColor: OneDarkColors.bg,
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Extracting ${p.basename(path)}…',
                  style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }
    try {
      await ArchiveService.extract(path, destDir);
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog
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
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extract failed: $e'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    }
  }

  /// Compresses [paths] into an archive (ZIP / TAR / TAR.GZ).
  ///
  /// Prompts for the archive name and format, appending the matching
  /// extension to the name when the user hasn't typed one explicitly.
  Future<void> _compressSelection(List<String> paths) async {
    if (paths.isEmpty) return;
    String defaultName = paths.length == 1
        ? p.basenameWithoutExtension(paths.first)
        : 'archive';
    defaultName += '.zip';
    final controller = TextEditingController(text: defaultName);
    ArchiveFormat format = ArchiveFormat.zip;

    String suffixFor(ArchiveFormat f) {
      switch (f) {
        case ArchiveFormat.tarGz:
          return '.tar.gz';
        case ArchiveFormat.tarXz:
          return '.tar.xz';
        case ArchiveFormat.tarBz2:
          return '.tar.bz2';
        default:
          return '.${f.name}';
      }
    }

    const multiPartSuffixes = ['tar.bz2', 'tar.gz', 'tar.xz'];

    final result = await showDialog<(String, ArchiveFormat)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) {
          void onFormatChanged(ArchiveFormat f) {
            final current = controller.text;
            String base = current;
            String? matched;
            for (final s in multiPartSuffixes) {
              if (base.endsWith('.$s')) {
                matched = s;
                break;
              }
            }
            if (matched != null) {
              base = base.substring(0, base.length - matched.length - 1);
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
            title: Text(
              'Compress ${paths.length} item${paths.length > 1 ? 's' : ''}',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 15),
            ),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: TextStyle(color: OneDarkColors.fg),
                    decoration: InputDecoration(
                      labelText: 'Archive name',
                      border: const OutlineInputBorder(),
                      labelStyle: TextStyle(color: OneDarkColors.fgDim),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Format',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in ArchiveFormat.values)
                        ChoiceChip(
                          label: Text(
                            suffixFor(f),
                            style: TextStyle(
                              fontSize: 12,
                              color: format == f
                                  ? Colors.black
                                  : OneDarkColors.fg,
                            ),
                          ),
                          selected: format == f,
                          selectedColor: OneDarkColors.cyan,
                          onSelected: (_) => onFormatChanged(f),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.archive, size: 16),
                onPressed: () => Navigator.pop(dialogContext, (
                  controller.text.trim(),
                  format,
                )),
                label: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;
    final (rawName, fmt) = result;
    var name = rawName.trim();
    if (name.isEmpty) return;
    final suffix = suffixFor(fmt);
    if (!name.toLowerCase().endsWith(suffix)) name += suffix;
    final outputPath = p.join(p.dirname(paths.first), name);

    if (await File(outputPath).exists()) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: OneDarkColors.bg,
          title: Text('Overwrite?', style: TextStyle(color: OneDarkColors.fg)),
          content: Text(
            '"$name" already exists. Overwrite?',
            style: TextStyle(color: OneDarkColors.fg),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      if (overwrite != true) return;
    }

    // Show a loading overlay while compressing
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => Center(
        child: Card(
          color: OneDarkColors.bgDark,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Compressing…'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      switch (fmt) {
        case ArchiveFormat.zip:
          await ArchiveService.createZip(
            outputPath: outputPath,
            sources: paths,
          );
          break;
        case ArchiveFormat.tar:
          await ArchiveService.createTar(
            outputPath: outputPath,
            sources: paths,
          );
          break;
        case ArchiveFormat.tarGz:
          await ArchiveService.createTarGz(
            outputPath: outputPath,
            sources: paths,
          );
          break;
        case ArchiveFormat.tarXz:
          await ArchiveService.createTarXz(
            outputPath: outputPath,
            sources: paths,
          );
          break;
        case ArchiveFormat.tarBz2:
          await ArchiveService.createTarBz2(
            outputPath: outputPath,
            sources: paths,
          );
          break;
      }
      if (mounted) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop(); // dismiss loading overlay
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
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop(); // dismiss loading overlay
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
        title: Text(item.name, style: TextStyle(color: OneDarkColors.fg)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _propRow('Name', item.name),
              _propRow('Type', item.isDirectory ? 'Folder' : item.mimeType),
              _propRow('Size', item.formattedSize),
              _propRow('Modified', item.formattedDate),
              _propRow('Path', item.path),
              _buildPermissionsEditor(item),
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

  /// Properties-dialog row: shows the rwx/permission string plus quick chmod
  /// presets (644 / 755 / 777). Best-effort on Android shared storage.
  Widget _buildPermissionsEditor(FileItem item) {
    return StatefulBuilder(
      builder: (ctx, setDialogState) {
        return FutureBuilder<String>(
          future: item.permissions,
          builder: (context, snap) {
            final perms = snap.data ?? '';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _propRow('Permissions', perms),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 80),
                  child: Wrap(
                    spacing: 8,
                    children: [644, 755, 777].map((mode) {
                      return ActionChip(
                        label: Text('chmod $mode'),
                        labelStyle: const TextStyle(fontSize: 11),
                        backgroundColor: OneDarkColors.dim,
                        onPressed: () async {
                          final ok = await FileUtils.setPermissions(
                            item.path,
                            mode,
                          );
                          if (!context.mounted) return;
                          setDialogState(() {});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? 'Permissions set to $mode'
                                    : 'chmod failed (read-only or FAT storage)',
                              ),
                              backgroundColor: ok
                                  ? OneDarkColors.green
                                  : OneDarkColors.amber,
                            ),
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          },
        );
      },
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
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                ),
              ),
              Expanded(
                child: Row(
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
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ),
            Expanded(
              child: Text(
                _formatBytes(size),
                style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
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
            () => _showOpenWithMenu(item, tapPosition),
          ),
        if (item.isDirectory)
          _menuItem(
            'Share via LAN…',
            Icons.wifi,
            () => _shareFolderViaLan(item.path),
          )
        else
          _menuItem('Share…', Icons.share, () => _sharePaths([item.path])),
        _menuItem(
          'Open Terminal Here',
          Icons.terminal,
          () => _openTerminalHere(item.path),
        ),
        const PopupMenuDivider(),
        _menuItem('Copy', Icons.copy, () {
          FileUtils.setClipboard(item.path, 'copy');
          _setClipboardInfo(
            ClipboardInfo(hasClipboard: true, operation: 'copy', count: 1),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied: ${item.name}'),
              backgroundColor: OneDarkColors.cyan,
            ),
          );
        }),
        _menuItem('Cut', Icons.content_cut, () {
          FileUtils.setClipboard(item.path, 'cut');
          _setClipboardInfo(
            ClipboardInfo(hasClipboard: true, operation: 'cut', count: 1),
          );
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
            try {
              await FileUtils.paste(destDir);
              if (mounted) {
                // A 'cut' paste consumes the clipboard; 'copy' keeps it.
                _setClipboardInfo(
                  FileUtils.hasClipboard
                      ? ClipboardInfo(
                          hasClipboard: true,
                          operation: FileUtils.clipboardOperation ?? 'copy',
                          count: FileUtils.clipboardCount,
                        )
                      : const ClipboardInfo.empty(),
                );
                _loadDirectory();
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Paste failed: $e'),
                    backgroundColor: OneDarkColors.red,
                  ),
                );
              }
            }
          }),
        const PopupMenuDivider(),
        if (_markedPaths.contains(item.path))
          _menuItem(
            'Unmark',
            Icons.check_circle,
            () => _toggleMarkItem(item.path),
          )
        else
          _menuItem(
            'Mark',
            Icons.check_circle_outline,
            () {
              // Enter mark mode so the user can keep tapping other documents
              // to mark them (same flow as the top "Select" button), instead
              // of being limited to one mark per long-press.
              setState(() => _markMode = true);
              _toggleMarkItem(item.path);
            },
          ),
        _menuItem(
          'Mark all in folder',
          Icons.done_all,
          _markAllInFolder,
        ),
        _menuItem(
          'Invert marks in folder',
          Icons.flip,
          _invertMarks,
        ),
        if (_markedPaths.isNotEmpty)
          _menuItem(
            'Clear ${_markedPaths.length} marks',
            Icons.clear_all,
            _clearMarks,
          ),
        if (_markedPaths.length > 1)
          _menuItem(
            'Batch Rename (${_markedPaths.length})',
            Icons.drive_file_rename_outline,
            _batchRename,
          ),
        const PopupMenuDivider(),
        _menuItem('Rename', Icons.edit, () => _showRenameDialog(item)),
        _menuItem('Delete', Icons.delete, () => _confirmDelete(item)),
        if (ArchiveService.isArchive(item.path)) ...[
          _menuItem('Browse Archive…', Icons.folder_special, () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArchiveBrowserScreen(archivePath: item.path),
              ),
            );
          }),
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
        if (item.extension == '.apk' || item.extension == '.xapk')
          _menuItem(
            'Install',
            Icons.system_update_alt,
            () => _installPackage(item),
          ),
        const PopupMenuDivider(),
        if (item.isText || item.isPdf || item.extension == '.docx')
          _menuItem('Convert…', Icons.transform, () {
            showDialog(
              context: context,
              builder: (_) => ConvertDialog(filePath: item.path),
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
          Text(title, style: TextStyle(color: OneDarkColors.fg)),
        ],
      ),
    );
  }

  /// Shows a nested "Open With" menu with app options for a file.
  void _showOpenWithMenu(FileItem item, [Offset? tapPosition]) {
    final box = context.findRenderObject() as RenderBox?;
    final RenderBox? parentBox = box?.parent as RenderBox?;
    if (box == null || parentBox == null) return;
    RelativeRect? position;
    if (tapPosition != null) {
      position = RelativeRect.fromLTRB(
        tapPosition.dx,
        tapPosition.dy,
        parentBox.paintBounds.width - tapPosition.dx,
        parentBox.paintBounds.height - tapPosition.dy,
      );
    } else {
      final offset = box.localToGlobal(Offset.zero);
      position = RelativeRect.fromLTRB(
        offset.dx,
        offset.dy,
        parentBox.paintBounds.width - offset.dx - 200,
        parentBox.paintBounds.height - offset.dy - 240,
      );
    }

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

    showMenu<String>(context: context, position: position, items: entries).then(
      (value) async {
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
          case 'copy':
            await Clipboard.setData(ClipboardData(text: item.path));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Path copied'),
                backgroundColor: OneDarkColors.green,
              ),
            );
            break;
        }
      },
    );
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

  Future<void> _installPackage(FileItem item) async {
    final error = item.extension == '.xapk'
        ? await InstallerService.installXapk(item.path)
        : await InstallerService.installApk(item.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Installing…'),
        backgroundColor: error == null ? OneDarkColors.cyan : OneDarkColors.red,
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
        title: Text('Rename', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          focusNode: focusNode,
          style: TextStyle(color: OneDarkColors.fg),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: ext.isNotEmpty ? ext : null,
            suffixStyle: TextStyle(color: OneDarkColors.fgDim),
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
    // Honor the "Delete Confirmation" setting: when off, send straight to
    // trash without the dialog.
    if (!await FileUtils.loadDeleteConfirmation()) {
      try {
        await FileUtils.moveToTrash(item.path);
      } catch (_) {}
      _markedPaths.remove(item.path);
      _notifyMarksChanged();
      if (mounted) {
        _loadDirectory();
        _exitSelectMode();
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Delete "${item.name}"?',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: !item.isDirectory
            ? Text(
                'The shredder uses a blazing-fast 64KB chunked I/O pattern — '
                'reads/writes in 64KB blocks to minimize syscalls while still '
                'securely overwriting every byte. The 3-pass pattern '
                '(random → complement → random) is the same approach used by '
                'shred on Linux.',
                style: TextStyle(
                  color: OneDarkColors.fgDim,
                  fontSize: 12,
                  height: 1.4,
                ),
              )
            : null,
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
          if (!item.isDirectory)
            TextButton(
              onPressed: () => Navigator.pop(context, 'shred'),
              child: Text('Shred', style: TextStyle(color: OneDarkColors.amber)),
            ),
        ],
      ),
    );
    if (choice == 'trash' && mounted) {
      try {
        await FileUtils.moveToTrash(item.path);
      } catch (_) {}
      _markedPaths.remove(item.path);
      _notifyMarksChanged();
      if (mounted) {
        _loadDirectory();
        _exitSelectMode();
      }
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved to trash'),
            backgroundColor: OneDarkColors.amber,
          ),
        );
    } else if (choice == 'delete' && mounted) {
      await FileUtils.delete(item.path);
      _markedPaths.remove(item.path);
      _notifyMarksChanged();
      if (mounted) {
        _loadDirectory();
        _exitSelectMode();
      }
    } else if (choice == 'shred' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Shredding…'), backgroundColor: OneDarkColors.amber),
      );
      try {
        await FileUtils.secureDelete(item.path);
        _markedPaths.remove(item.path);
        _notifyMarksChanged();
        if (mounted) {
          _loadDirectory();
          _exitSelectMode();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Shredded "${item.name}"'),
              backgroundColor: OneDarkColors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Shred failed: $e'),
              backgroundColor: OneDarkColors.red,
            ),
          );
        }
      }
    }
  }

  void _showNewFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('New Folder', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
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
        title: Text('New File', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
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
              icon: Icon(Icons.arrow_back, color: OneDarkColors.fg),
              onPressed: _historyIndex > 0 ? _goBack : null,
              tooltip: 'Back',
            ),
            IconButton(
              icon: Icon(Icons.arrow_upward, color: OneDarkColors.fg),
              onPressed: _currentPath != '/' ? _goUp : null,
              tooltip: 'Go up one level',
            ),
            IconButton(
              icon: Icon(Icons.arrow_forward, color: OneDarkColors.fg),
              onPressed: _historyIndex < _history.length - 1
                  ? _goForward
                  : null,
              tooltip: 'Forward',
            ),
            const SizedBox(width: 8),
            if (!inSelectMode) ...[
              IconButton(
                icon: Icon(Icons.create_new_folder, color: OneDarkColors.fgDim),
                onPressed: _showNewFolderDialog,
                tooltip: 'New Folder',
              ),
              IconButton(
                icon: Icon(Icons.note_add, color: OneDarkColors.fgDim),
                onPressed: _showNewFileDialog,
                tooltip: 'New File',
              ),
              IconButton(
                icon: Icon(Icons.edit, color: OneDarkColors.cyan),
                onPressed: _startInPlaceRename,
                tooltip: 'Rename (F2)',
              ),
            ],
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.check, color: OneDarkColors.green),
                onPressed: _exitSelectMode,
                tooltip: 'Done',
              )
            else
              IconButton(
                icon: Icon(Icons.select_all, color: OneDarkColors.fgDim),
                onPressed: _enterSelectMode,
                tooltip: 'Select',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.delete_outline, color: OneDarkColors.red),
                onPressed: _deleteSelected,
                tooltip: 'Delete selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.copy, color: OneDarkColors.cyan),
                onPressed: _copySelected,
                tooltip: 'Copy selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.content_cut, color: OneDarkColors.amber),
                onPressed: _cutSelected,
                tooltip: 'Cut selected',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.edit_note, color: OneDarkColors.cyan),
                onPressed: _batchRename,
                tooltip: 'Batch rename',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.archive, color: OneDarkColors.green),
                onPressed: () => _compressSelection(_actionPaths),
                tooltip: 'Compress…',
              ),
            if (inSelectMode)
              IconButton(
                icon: Icon(Icons.share, color: OneDarkColors.cyan),
                onPressed: () => _sharePaths(_actionPaths),
                tooltip: 'Share…',
              ),
            if (inSelectMode)
              PopupMenuButton<bool>(
                icon: Icon(Icons.tune, color: OneDarkColors.fgDim),
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
                icon: Icon(Icons.content_paste, color: OneDarkColors.green),
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
                _showHidden = !_showHidden;
                showHiddenNotifier.value = _showHidden;
                _loadDirectory();
              },
            ),
            // Open the built-in terminal at the current directory.
            IconButton(
              icon: Icon(Icons.terminal, color: OneDarkColors.fgDim),
              onPressed: () => _openTerminalHere(_currentPath),
              tooltip: 'Open Terminal',
            ),
            // Bookmark the current folder.
            IconButton(
              icon: Icon(Icons.bookmark_add, color: OneDarkColors.fgDim),
              onPressed: () => widget.onBookmarkCurrentPath?.call(_currentPath),
              tooltip: 'Bookmark This Folder',
            ),
            // Folder graph — same feature as Linux SwordFM F3.
            IconButton(
              icon: Icon(Icons.account_tree, color: OneDarkColors.fgDim),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FolderGraphScreen(startPath: _currentPath),
                  ),
                );
              },
              tooltip: 'Folder Graph',
            ),
            IconButton(
              icon: Icon(
                _viewMode == ViewMode.details
                    ? Icons.view_list
                    : Icons.grid_view,
                color: OneDarkColors.cyan,
              ),
              onPressed: () => _setViewMode(
                _viewMode == ViewMode.details
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
                  style: TextStyle(color: OneDarkColors.fg),
                ),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          child: Text(
            _sortDir == SortDir.asc ? 'Descending' : 'Ascending',
            style: TextStyle(color: OneDarkColors.fg),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fewer columns on narrow panes (e.g. phone with sidebar open) so
        // tiles stay readable instead of shrinking to ~44px with truncated
        // names.
        final crossAxisCount = constraints.maxWidth < 300
            ? 3
            : constraints.maxWidth < 520
            ? 4
            : 6;
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: crossAxisCount >= 6 ? 0.7 : 0.75,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: _filteredItems.length,
          itemBuilder: (context, index) {
            final item = _filteredItems[index];
            final isSelected = _selectedPaths.contains(item.path);
            final isMarked = _markedPaths.contains(item.path);
            return GestureDetector(
              onLongPressStart: (details) {
                // In mark mode, long-press toggles the mark so the user can
                // mark multiple documents by long-pressing each one (same
                // affordance as the top "Select" button). Otherwise, open
                // the context menu.
                if (_markMode) {
                  _toggleMarkItem(item.path);
                } else {
                  _showContextMenu(item, details.globalPosition);
                }
              },
              onSecondaryTapDown: (details) =>
                  _showContextMenu(item, details.globalPosition),
              onTap: () => _handleItemTap(item, isSelected),
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? OneDarkColors.select
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: isSelected
                          ? Border.all(color: OneDarkColors.cyan, width: 1.5)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        // Image files show a real thumbnail instead of an icon.
                        if (item.isImage)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: Image.file(
                                File(item.path),
                                cacheWidth: 200,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(
                                  item.icon,
                                  size: 32,
                                  color: item.iconColor,
                                ),
                              ),
                            ),
                          )
                        else if (item.isVideo)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: _VideoThumbnail(path: item.path, item: item),
                          )
                        else
                          Icon(item.icon, size: 32, color: item.iconColor),
                        const SizedBox(height: 4),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              item.name,
                              style: TextStyle(
                                color: isMarked
                                    ? OneDarkColors.amber
                                    : OneDarkColors.fg,
                                fontSize: 11,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isMarked)
                    Positioned(
                      top: 2,
                      left: 2,
                      child: Icon(
                        Icons.check_circle,
                        size: 16,
                        color: OneDarkColors.amber,
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
                            color: isSelected
                                ? Colors.black
                                : OneDarkColors.fgDim,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailsView() {
    final isMobile = MediaQuery.of(context).size.width < 600;
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
        final isMarked = _markedPaths.contains(item.path);
        return GestureDetector(
          onLongPressStart: (details) {
            // In mark mode, long-press toggles the mark so the user can
            // mark multiple documents by long-pressing each one (same
            // affordance as the top "Select" button). Otherwise, open
            // the context menu.
            if (_markMode) {
              _toggleMarkItem(item.path);
            } else {
              _showContextMenu(item, details.globalPosition);
            }
          },
          onSecondaryTapDown: (details) =>
              _showContextMenu(item, details.globalPosition),
          onTap: () => _handleItemTap(item, isSelected),
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
                if (isMarked)
                  Icon(
                    Icons.check_circle,
                    size: 14,
                    color: OneDarkColors.amber,
                  ),
                if (isMarked) const SizedBox(width: 3),
                Icon(item.icon, size: 18, color: item.iconColor),
                const SizedBox(width: 6),
                Expanded(
                  flex: 4,
                  child: Text(
                    item.name,
                    style: TextStyle(
                      color: isMarked ? OneDarkColors.amber : OneDarkColors.fg,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
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
                        Flexible(
                          child: FutureBuilder<int>(
                            future: _computeFolderSize(item),
                            builder: (ctx, snap) {
                              if (snap.connectionState ==
                                  ConnectionState.waiting)
                                return const SizedBox(
                                  width: 30,
                                  child: LinearProgressIndicator(minHeight: 4),
                                );
                              final s = snap.hasData && snap.data! >= 0
                                  ? snap.data!
                                  : 0;
                              return Text(
                                _formatBytes(s),
                                style: TextStyle(
                                  color: OneDarkColors.fgDim,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    flex: 2,
                    child: Text(
                      item.formattedSize,
                      style: TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (!isMobile)
                  Flexible(
                    flex: 1,
                    child: Text(
                      item.extension.isEmpty ? 'Folder' : item.extension,
                      style: TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Flexible(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text(
                      item.formattedDate,
                      style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                    ),
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
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Row(
      children: [
        // Matches the rows' leading: 8px container padding + checkbox (20)
        // + item icon (18) + gap (6), or without checkbox on desktop.
        SizedBox(width: _selectionMode == SelectionMode.multi ? 52 : 32),
        Expanded(
          flex: 4,
          child: Text(
            'Name',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
          ),
        ),
        Flexible(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Size',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
            ),
          ),
        ),
        if (!isMobile)
          Flexible(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Type',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
              ),
            ),
          ),
        Flexible(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Date Modified',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
              textAlign: TextAlign.right,
            ),
          ),
        ),
      ],
    );
  }

  /// Builds the in-place rename row (shown when [_renamingIndex] is active).
  Widget _buildRenameRow(FileItem item, int index) {
    final isMobile = MediaQuery.of(context).size.width < 600;
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
          const SizedBox(width: 6),
          Expanded(
            flex: 4, // matches the name column in _buildDetailsView
            child: TextField(
              controller: _renameController,
              focusNode: _renameFocusNode,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                suffixText: item.isDirectory ? null : p.extension(item.name),
                suffixStyle: TextStyle(color: OneDarkColors.fgDim),
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
                  Flexible(
                    child: FutureBuilder<int>(
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
                          style: TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
                  ),
                ],
              ),
            )
          else
            Flexible(
              flex: 2,
              child: Text(
                item.formattedSize,
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Flexible(
            flex: 3,
            child: Text(
              item.formattedDate,
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!isMobile)
            Flexible(
              flex: 1,
              child: Text(
                item.extension.isEmpty ? 'Folder' : item.extension,
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keyboard handling happens in the Focus.onKeyEvent below; the old
    // Shortcuts map was dead code (nothing consumed the intents).
    return Focus(
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
          // SwordFM-style marks action bar: visible whenever items are marked,
          // with the clipboard/delete actions users expect.
          if (_markedPaths.isNotEmpty) _buildMarksBar(),
        ],
      ),
    );
  }

  /// SwordFM-style bottom bar for marked items: count + quick actions
  /// (Copy / Move / Delete / Compress / Clear). Mirrors the desktop app's
  /// marked-items behaviour on touch devices.
  Widget _buildMarksBar() {
    final paths = _markedPaths.toList();
    return Container(
      color: OneDarkColors.bgDark,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: OneDarkColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _markMode
                    ? '${paths.length} marked — tap more documents to mark'
                    : '${paths.length} marked',
                style:
                    TextStyle(color: OneDarkColors.fg, fontSize: 13),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            if (_markMode)
              TextButton.icon(
                onPressed: () => setState(() => _markMode = false),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Done'),
              ),
            TextButton.icon(
              onPressed: () {
                FileUtils.setClipboardMultiple(paths, 'copy');
                _setClipboardInfo(
                  ClipboardInfo(
                    hasClipboard: true,
                    operation: 'copy',
                    count: paths.length,
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${paths.length} item(s) copied — use Paste'),
                    backgroundColor: OneDarkColors.green,
                  ),
                );
              },
              icon: Icon(Icons.content_copy, size: 16),
              label: const Text('Copy'),
            ),
            TextButton.icon(
              onPressed: () {
                FileUtils.setClipboardMultiple(paths, 'cut');
                _setClipboardInfo(
                  ClipboardInfo(
                    hasClipboard: true,
                    operation: 'cut',
                    count: paths.length,
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content:
                        Text('${paths.length} item(s) cut — use Paste to move'),
                    backgroundColor: OneDarkColors.amber,
                  ),
                );
              },
              icon: Icon(Icons.content_cut, size: 16),
              label: const Text('Move'),
            ),
            TextButton.icon(
              onPressed: _deleteSelected,
              icon: Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: TextButton.styleFrom(foregroundColor: OneDarkColors.red),
            ),
            TextButton.icon(
              onPressed: _clearMarks,
              icon: Icon(Icons.clear_all, size: 16),
              label: const Text('Clear'),
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
        _menuItem(
          'Bookmark This Folder',
          Icons.bookmark_add,
          () => widget.onBookmarkCurrentPath?.call(_currentPath),
        ),
        const PopupMenuDivider(),
        _menuItem('New Folder', Icons.create_new_folder, _showNewFolderDialog),
        _menuItem('New File', Icons.note_add, _showNewFileDialog),
        _menuItem('New Note', Icons.sticky_note_2, () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NotepadScreen(filePath: null)),
          );
        }),
        const PopupMenuDivider(),
        if (FileUtils.hasClipboard)
          _menuItem('Paste', Icons.content_paste, () async {
            try {
              await FileUtils.paste(_currentPath);
              if (mounted) {
                // 'cut' paste consumes the clipboard; 'copy' keeps it.
                _setClipboardInfo(
                  FileUtils.hasClipboard
                      ? ClipboardInfo(
                          hasClipboard: true,
                          operation: FileUtils.clipboardOperation ?? 'copy',
                          count: FileUtils.clipboardCount,
                        )
                      : const ClipboardInfo.empty(),
                );
                _loadDirectory();
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Paste failed: $e'),
                    backgroundColor: OneDarkColors.red,
                  ),
                );
              }
            }
          }),
        if (FileUtils.clipboardHistory.isNotEmpty)
          _menuItem('Clipboard History', Icons.history, _showClipboardHistory),
        _menuItem('Select All', Icons.select_all, _selectAll),
        _menuItem('Refresh', Icons.refresh, () => _loadDirectory()),
      ],
    );
  }

  void _showClipboardHistory() {
    final history = FileUtils.clipboardHistory;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Clipboard History', style: TextStyle(color: OneDarkColors.fg)),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: history.isEmpty
              ? Center(
                  child: Text('No history', style: TextStyle(color: OneDarkColors.fgDim)),
                )
              : ListView.separated(
                  itemCount: history.length,
                  separatorBuilder: (_, i) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final entry = history[i];
                    final paths = List<String>.from(entry['paths'] ?? []);
                    final op = entry['op'] as String? ?? '?';
                    final ts = entry['timestamp'] as int? ?? 0;
                    final date = DateTime.fromMillisecondsSinceEpoch(ts);
                    final timeStr = '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                    final name = paths.length == 1
                        ? p.basename(paths.first)
                        : '${paths.length} items';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        op == 'copy' ? Icons.copy : Icons.cut,
                        size: 18,
                        color: op == 'copy' ? OneDarkColors.cyan : OneDarkColors.amber,
                      ),
                      title: Text(name, style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                        overflow: TextOverflow.ellipsis, maxLines: 1),
                      subtitle: Text(
                        '$op \u2022 $timeStr',
                        style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.content_paste, size: 18, color: OneDarkColors.green),
                        tooltip: 'Restore',
                        onPressed: () {
                          FileUtils.restoreFromHistory(i);
                          _setClipboardInfo(ClipboardInfo(
                            hasClipboard: true,
                            operation: FileUtils.clipboardOperation ?? 'copy',
                            count: FileUtils.clipboardCount,
                          ));
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Restored ${paths.length} item(s)'),
                              backgroundColor: OneDarkColors.green,
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (history.isNotEmpty)
            TextButton(
              onPressed: () async {
                await FileUtils.clearClipboardHistory();
                Navigator.pop(context);
              },
              child: Text('Clear History', style: TextStyle(color: OneDarkColors.red)),
            ),
        ],
      ),
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
  String _mode = 'prefix'; // 'prefix', 'suffix', 'regex', 'number'
  final _regexController = TextEditingController();
  final _replacementController = TextEditingController();
  final _numberStartController = TextEditingController(text: '1');
  final _numberPadController = TextEditingController(text: '2');
  bool _numberBeforeExt = true;

  List<MapEntry<String, String>> get _previewEntries {
    final start = int.tryParse(_numberStartController.text) ?? 1;
    final pad = int.tryParse(_numberPadController.text) ?? 2;
    return widget.selectedPaths.asMap().entries.map((entry) {
      final path = entry.value;
      final name = p.basename(path);
      final ext = p.extension(name);
      final base = p.basenameWithoutExtension(name);
      String newName;
      if (_mode == 'prefix') {
        newName = '${_prefixController.text}$name';
      } else if (_mode == 'suffix') {
        newName = '$name${_suffixController.text}';
      } else if (_mode == 'number') {
        final num = (start + entry.key).toString().padLeft(pad, '0');
        newName = _numberBeforeExt ? '$num\_$name' : '${base}_$num$ext';
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
      return MapEntry(path, newName);
    }).toList();
  }

  @override
  void dispose() {
    _prefixController.dispose();
    _suffixController.dispose();
    _regexController.dispose();
    _replacementController.dispose();
    _numberStartController.dispose();
    _numberPadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: Text(
        'Batch Rename (${widget.selectedPaths.length})',
        style: TextStyle(color: OneDarkColors.fg),
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
                  ButtonSegment(
                    value: 'number',
                    label: Text('Number'),
                    icon: Icon(Icons.pin, size: 16),
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
                  style: TextStyle(color: OneDarkColors.fg),
                ),
              ] else if (_mode == 'suffix') ...[
                TextField(
                  controller: _suffixController,
                  decoration: const InputDecoration(
                    labelText: 'Suffix',
                    border: OutlineInputBorder(),
                  ),
                  style: TextStyle(color: OneDarkColors.fg),
                ),
              ] else if (_mode == 'number') ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _numberStartController,
                        decoration: const InputDecoration(
                          labelText: 'Start at',
                          border: OutlineInputBorder(),
                        ),
                        style: TextStyle(color: OneDarkColors.fg),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _numberPadController,
                        decoration: const InputDecoration(
                          labelText: 'Pad to',
                          border: OutlineInputBorder(),
                        ),
                        style: TextStyle(color: OneDarkColors.fg),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: _numberBeforeExt,
                      onChanged: (v) =>
                          setState(() => _numberBeforeExt = v ?? true),
                    ),
                    const Text('Number before original name'),
                  ],
                ),
              ] else ...[
                TextField(
                  controller: _regexController,
                  decoration: const InputDecoration(
                    labelText: 'Regex pattern',
                    border: OutlineInputBorder(),
                  ),
                  style: TextStyle(color: OneDarkColors.fg),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _replacementController,
                  decoration: const InputDecoration(
                    labelText: 'Replacement',
                    border: OutlineInputBorder(),
                  ),
                  style: TextStyle(color: OneDarkColors.fg),
                ),
              ],
              const SizedBox(height: 12),
              Text(
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
                          p.basename(e.key),
                          style: TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: OneDarkColors.fgDim,
                      ),
                      Expanded(
                        child: Text(
                          e.value,
                          style: TextStyle(
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
              if (p.basename(entry.key) != entry.value) {
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

/// Grid-tile video thumbnail: extracts a frame from the video with
/// [VideoThumbnail] and overlays a play glyph. Falls back to the generic
/// video icon when extraction fails.
class _VideoThumbnail extends StatefulWidget {
  final String path;
  final FileItem item;
  const _VideoThumbnail({required this.path, required this.item});

  // In-memory cache so re-entering a folder doesn't re-extract frames.
  static final Map<String, Uint8List?> _cache = {};

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Future<Uint8List?> _load() async {
    if (_VideoThumbnail._cache.containsKey(widget.path)) {
      return _VideoThumbnail._cache[widget.path];
    }
    Uint8List? bytes;
    try {
      bytes = await VideoThumbnail.thumbnailData(
        video: widget.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 256,
        quality: 60,
      );
    } catch (_) {
      bytes = null;
    }
    _VideoThumbnail._cache[widget.path] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _load(),
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes != null) {
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  );
                }
                return Icon(
                  widget.item.icon,
                  size: 32,
                  color: widget.item.iconColor,
                );
              },
            ),
            const Center(
              child: Icon(Icons.play_circle, size: 36, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
