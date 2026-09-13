import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/saf_service.dart';
import '../services/open_with_service.dart';
import '../services/file_open_router.dart';
import '../screens/pdf_reader_screen.dart';
import '../screens/docx_reader_screen.dart';
import '../screens/video_player_screen.dart';
import '../screens/music_player_screen.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/text_reader_screen.dart';
import '../screens/epub_reader_screen.dart';
import '../screens/cbz_reader_screen.dart';
import '../screens/spreadsheet_viewer_screen.dart';
import '../theme/theme.dart';

/// Read-only browser for Storage Access Framework grants.
///
/// Shown when "All files access" is denied: the user picks folders through
/// the system picker, browses them here, and opens files — which are
/// materialised to the app cache and routed to the same in-app viewers as
/// regular files. Nothing here writes outside the cache; SAF is the
/// read fallback, not a second file manager.
class SafBrowserScreen extends StatefulWidget {
  const SafBrowserScreen({super.key});

  @override
  State<SafBrowserScreen> createState() => _SafBrowserScreenState();
}

class _SafBrowserScreenState extends State<SafBrowserScreen> {
  List<SafTree> _trees = [];
  SafTree? _activeTree;
  // Navigation stack inside the active tree: documentIds from the root.
  // Display names are tracked alongside for the breadcrumb.
  List<String> _stackIds = [];
  List<String> _stackNames = [];
  List<SafEntry> _entries = [];
  bool _loadingTrees = true;
  bool _loadingEntries = false;
  bool _openingDoc = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshTrees();
  }

  Future<void> _refreshTrees() async {
    setState(() {
      _loadingTrees = true;
      _error = null;
    });
    final trees = await SafService.persistedTrees();
    if (!mounted) return;
    setState(() {
      _trees = trees;
      _loadingTrees = false;
      if (_activeTree != null &&
          !_trees.any((t) => t.uri == _activeTree!.uri)) {
        _activeTree = null;
        _entries = [];
        _stackIds = [];
        _stackNames = [];
      }
    });
  }

  Future<void> _pickFolder() async {
    final tree = await SafService.openTree();
    if (tree == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'No folder granted — pick a folder so SwordFM can browse it.',
            ),
            backgroundColor: OneDarkColors.amber,
          ),
        );
      }
      return;
    }
    await _refreshTrees();
    _enterTree(tree);
  }

  void _enterTree(SafTree tree) {
    setState(() {
      _activeTree = tree;
      _stackIds = [];
      _stackNames = [];
    });
    _loadEntries();
  }

  void _exitTree() {
    setState(() {
      _activeTree = null;
      _entries = [];
      _stackIds = [];
      _stackNames = [];
      _error = null;
    });
  }

  Future<void> _loadEntries() async {
    final tree = _activeTree;
    if (tree == null) return;
    setState(() {
      _loadingEntries = true;
      _error = null;
    });
    final entries = await SafService.listChildren(
      tree,
      parentDocumentId: _stackIds.isEmpty ? null : _stackIds.last,
    );
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loadingEntries = false;
      if (entries.isEmpty) {
        // Empty could mean an unreadable tree (grant lost) — surface it only
        // when the OS reports nothing at all; a genuinely empty folder just
        // shows the empty state below.
      }
    });
  }

  void _drillInto(SafEntry entry) {
    setState(() {
      _stackIds = [..._stackIds, entry.documentId];
      _stackNames = [..._stackNames, entry.name];
    });
    _loadEntries();
  }

  void _goUp() {
    if (_stackIds.isEmpty) {
      _exitTree();
      return;
    }
    setState(() {
      _stackIds = _stackIds.sublist(0, _stackIds.length - 1);
      _stackNames = _stackNames.sublist(0, _stackNames.length - 1);
    });
    _loadEntries();
  }

  String _crumb() {
    final tree = _activeTree;
    if (tree == null) return '';
    if (_stackNames.isEmpty) return tree.displayName;
    return '${tree.displayName} / ${_stackNames.join(' / ')}';
  }

  Future<void> _openEntry(SafEntry entry) async {
    final tree = _activeTree;
    if (tree == null || entry.isDir || _openingDoc) return;
    setState(() => _openingDoc = true);
    try {
      final localPath = await SafService.openDocument(tree, entry);
      if (!mounted) return;
      if (localPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open ${entry.name}'),
            backgroundColor: OneDarkColors.red,
          ),
        );
        return;
      }
      _routeToViewer(localPath);
    } finally {
      if (mounted) setState(() => _openingDoc = false);
    }
  }

  /// Routes a materialised cache file to the same in-app viewer the file
  /// browser would use, falling back to the system "Open with" chooser.
  void _routeToViewer(String localPath) {
    final target = FileOpenRouter.resolve(
      localPath,
      source: FileOpenSource.browse,
    );
    Widget? screen;
    switch (target.type) {
      case FileOpenTargetType.pdf:
        screen = PdfReaderScreen(filePath: localPath);
      case FileOpenTargetType.docx:
        screen = DocxReaderScreen(filePath: localPath);
      case FileOpenTargetType.video:
        screen = VideoPlayerScreen(filePath: localPath);
      case FileOpenTargetType.audio:
        screen = MusicPlayerScreen(filePath: localPath);
      case FileOpenTargetType.image:
        screen = ImageViewerScreen(filePath: localPath);
      case FileOpenTargetType.text:
        screen = TextReaderScreen(filePath: localPath);
      case FileOpenTargetType.epub:
        screen = EpubReaderScreen(filePath: localPath);
      case FileOpenTargetType.comicBook:
        screen = CbzReaderScreen(filePath: localPath);
      case FileOpenTargetType.spreadsheet:
        screen = SpreadsheetViewerScreen(filePath: localPath);
      case FileOpenTargetType.pptxOutline:
      case FileOpenTargetType.archive:
      case FileOpenTargetType.external:
      case FileOpenTargetType.unsupported:
        screen = null;
    }
    if (screen != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => screen!),
      );
    } else {
      OpenWithService.openDefault(localPath).catchError((_) => false);
    }
  }

  Future<void> _forgetTree(SafTree tree) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this folder?'),
        content: Text(
          '"${tree.displayName}" will no longer be browsable. '
          'The files themselves are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SafService.releaseTree(tree);
    if (_activeTree?.uri == tree.uri) _exitTree();
    await _refreshTrees();
  }

  IconData _iconFor(SafEntry e) {
    if (e.isDir) return Icons.folder;
    final ext = p.extension(e.name).toLowerCase();
    if ({'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg'}
        .contains(ext)) {
      return Icons.image;
    }
    if ({'.mp4', '.mkv', '.mov', '.avi', '.webm'}.contains(ext)) {
      return Icons.movie;
    }
    if ({'.mp3', '.flac', '.wav', '.ogg', '.m4a'}.contains(ext)) {
      return Icons.music_note;
    }
    if (ext == '.pdf') return Icons.picture_as_pdf;
    if ({'.zip', '.tar', '.gz', '.xz', '.bz2', '.7z', '.rar'}.contains(ext)) {
      return Icons.archive;
    }
    if ({'.doc', '.docx', '.txt', '.md', '.epub'}.contains(ext)) {
      return Icons.description;
    }
    return Icons.insert_drive_file;
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: Text(
          _activeTree == null ? 'Shared folders' : _crumb(),
          style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        leading: _activeTree == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: _stackIds.isEmpty ? 'All folders' : 'Up',
                onPressed: _goUp,
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            tooltip: 'Grant a folder',
            onPressed: _pickFolder,
          ),
        ],
      ),
      body: _loadingTrees
          ? const Center(child: CircularProgressIndicator())
          : _activeTree == null
              ? _buildTreeList()
              : _buildEntryList(),
      floatingActionButton: _activeTree == null
          ? FloatingActionButton.extended(
              onPressed: _pickFolder,
              icon: const Icon(Icons.create_new_folder),
              label: const Text('Add folder'),
            )
          : null,
    );
  }

  Widget _buildTreeList() {
    if (_trees.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_shared,
                size: 64,
                color: OneDarkColors.fgDim,
              ),
              const SizedBox(height: 16),
              Text(
                'No shared folders yet',
                style: TextStyle(color: OneDarkColors.fg, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Without "All files access", SwordFM can still browse '
                'folders you explicitly grant. Tap "Add folder" and pick '
                'one in the system dialog — the grant survives restarts.',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshTrees,
      child: ListView.separated(
        itemCount: _trees.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final tree = _trees[i];
          return ListTile(
            leading: Icon(Icons.folder_shared, color: OneDarkColors.cyan),
            title: Text(
              tree.displayName,
              style: TextStyle(color: OneDarkColors.fg),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: Icon(Icons.close, size: 18, color: OneDarkColors.fgDim),
              tooltip: 'Remove',
              onPressed: () => _forgetTree(tree),
            ),
            onTap: () => _enterTree(tree),
          );
        },
      ),
    );
  }

  Widget _buildEntryList() {
    if (_loadingEntries) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: TextStyle(color: OneDarkColors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          'Empty folder',
          style: TextStyle(color: OneDarkColors.fgDim),
        ),
      );
    }
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _loadEntries,
          child: ListView.separated(
            itemCount: _entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = _entries[i];
              return ListTile(
                dense: true,
                leading: Icon(
                  _iconFor(e),
                  size: 20,
                  color: e.isDir ? OneDarkColors.cyan : OneDarkColors.fgDim,
                ),
                title: Text(
                  e.name,
                  style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: e.isDir
                    ? null
                    : Text(
                        _fmtSize(e.size),
                        style: TextStyle(
                          color: OneDarkColors.fgDim,
                          fontSize: 11,
                        ),
                      ),
                trailing: e.isDir
                    ? Icon(
                        Icons.chevron_right,
                        color: OneDarkColors.fgDim,
                      )
                    : null,
                onTap: e.isDir ? () => _drillInto(e) : () => _openEntry(e),
              );
            },
          ),
        ),
        if (_openingDoc)
          Container(
            color: Colors.black45,
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
