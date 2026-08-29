import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'theme/theme.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'utils/app_paths.dart' show StoragePermissions;
import 'widgets/file_browser.dart';
import 'utils/file_utils.dart' show FileItem;
import 'widgets/preview_panel.dart';
import 'screens/folder_graph_screen.dart';
import 'screens/search_screen.dart';
import 'screens/trash_screen.dart';
import 'screens/bluetooth_screen.dart';
import 'screens/lan_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_analysis_screen.dart';
import 'screens/network_screen.dart';
import 'screens/recent_files_screen.dart';
import 'services/entitlement_service.dart';
import 'services/device_service.dart';
import 'services/bookmarks_service.dart';
import 'utils/constants.dart' show AppPaths;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase init skipped: $e');
  }
  // Request storage/media permissions before app starts
  try {
    await StoragePermissions.ensurePermissions();
  } catch (e) {
    debugPrint('Permission request failed: $e');
  }
  // Load saved theme mode
  await loadThemeMode();
  runApp(const SwordFM());
}

class SwordFM extends StatelessWidget {
  const SwordFM({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: themeNotifier,
      builder: (context, _, __) {
        return DynamicColorBuilder(
          builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
            final baseTheme = isDarkTheme
                ? buildOneDarkTheme()
                : buildCreamTheme();
            // Blend the matching dynamic palette: dark scheme for dark mode,
            // light scheme for cream/light mode.
            final dynamicScheme = isDarkTheme ? darkDynamic : lightDynamic;
            final theme = dynamicScheme != null
                ? baseTheme.copyWith(
                    colorScheme: baseTheme.colorScheme.copyWith(
                      primary: dynamicScheme.primary,
                      secondary: dynamicScheme.secondary,
                      error: dynamicScheme.error,
                    ),
                  )
                : baseTheme;
            return MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => EntitlementService()),
              ],
              child: MaterialApp(
                title: 'SwordFM',
                debugShowCheckedModeBanner: false,
                theme: theme,
                home: const MainScreen(),
              ),
            );
          },
        );
      },
    );
  }
}

/// Main app screen with responsive layout matching Linux SwordFM.
/// - Left sidebar: places, bookmarks, devices
/// - Center: file browser
/// - Right (collapsible): preview panel
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  bool _sidebarVisible = true;
  bool _previewVisible = true;
  String _currentPath = ''; // resolved in initState for Android
  FileItem? _selectedItem;
  SelectionInfo? _selectionInfo; // aggregate multi-select info from FileBrowser
  ClipboardInfo? _clipboardInfo; // clipboard state from FileBrowser
  int _markCount = 0; // mark count from FileBrowser
  int _itemCount = 0; // item count in the current directory

  // ignore: prefer_final_fields — mutated via setState
  List<String> _bookmarks =
      []; // loaded/persisted via BookmarksService (bookmarks.json)
  final Set<int> _hoveredIndex = {}; // tracks which sidebar item is hovered

  // Storage volumes from Android device service (null until loaded)
  List<StorageVolume>? _volumes;

  // Real directories found in the home folder
  List<FileSystemEntity> _homeDirs = [];
  bool _homeDirsLoaded = false;

  @override
  void initState() {
    super.initState();
    // On Android, resolve the actual storage root synchronously after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _currentPath = AppPaths.home);
      _loadVolumes();
      _loadBookmarks();
      _loadHomeDirs();
    });
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await BookmarksService.load();
    if (mounted) setState(() => _bookmarks = bookmarks);
  }

  Future<void> _loadHomeDirs() async {
    try {
      final home = Directory(AppPaths.home);
      if (await home.exists()) {
        final entities = await home.list().toList();
        final dirs = entities.whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        if (mounted)
          setState(() {
            _homeDirs = dirs;
            _homeDirsLoaded = true;
          });
      }
    } catch (_) {
      if (mounted) setState(() => _homeDirsLoaded = true);
    }
  }

  IconData _iconForDir(String name) {
    switch (name.toLowerCase()) {
      case 'dcim':
        return Icons.camera_alt;
      case 'download':
      case 'downloads':
        return Icons.download;
      case 'music':
        return Icons.music_note;
      case 'pictures':
        return Icons.image;
      case 'movies':
      case 'videos':
        return Icons.movie;
      case 'documents':
        return Icons.description;
      case 'android':
        return Icons.android;
      case 'alarms':
        return Icons.alarm;
      case 'notifications':
        return Icons.notifications;
      case 'podcasts':
        return Icons.podcasts;
      case 'ringtones':
        return Icons.music_note;
      default:
        return Icons.folder;
    }
  }

  Future<void> _loadVolumes() async {
    final volumes = await getStorageVolumes();
    if (mounted) setState(() => _volumes = volumes);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final cs = Theme.of(context).colorScheme;
    final surfaceHighest = cs.surfaceContainerHighest;
    final surface = cs.surfaceContainer;
    final onSurface = cs.onSurface;
    final onSurfaceDim = cs.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            // Tab 0: Files
            Row(
              children: [
                // ── Sidebar (collapses smoothly when hidden) ──
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  child: _sidebarVisible
                      ? SizedBox(
                          width: isMobile ? 160 : 200,
                          child: Card(
                            color: surfaceHighest,
                            elevation: 0,
                            margin: EdgeInsets.zero,
                            child: Column(
                              children: [
                                // Sidebar header
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.folder_special,
                                        color: cs.primary,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Places',
                                        style: TextStyle(
                                          color: onSurfaceDim,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),

                                // Places list — scrolls when the drawer is short
                                Expanded(
                                  child: ListView(
                                    children: [
                                      _sidebarTile(
                                        0,
                                        Icons.home,
                                        'Home',
                                        AppPaths.home,
                                      ),
                                      ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                        minLeadingWidth: 0,
                                        horizontalTitleGap: 6,
                                        leading: Icon(
                                          Icons.history,
                                          size: 18,
                                          color: cs.primary,
                                        ),
                                        title: Text(
                                          'Recent',
                                          style: TextStyle(
                                            color: cs.onSurface,
                                            fontSize: 13,
                                          ),
                                        ),
                                        onTap: () => Navigator.of(context)
                                            .push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const RecentFilesScreen(),
                                          ),
                                        ),
                                      ),
                                      if (_homeDirsLoaded)
                                        ..._homeDirs
                                            .where((d) {
                                              final name = d.path
                                                  .split('/')
                                                  .last;
                                              return !name.startsWith('.');
                                            })
                                            .take(15)
                                            .toList()
                                            .asMap()
                                            .entries
                                            .map((entry) {
                                              final i = entry.key;
                                              final dir = entry.value;
                                              final name = dir.path
                                                  .split('/')
                                                  .last;
                                              final icon = _iconForDir(name);
                                              final tileIndex = 100 + i;
                                              return _sidebarTile(
                                                tileIndex,
                                                icon,
                                                name,
                                                dir.path,
                                              );
                                            })
                                      else
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          child: SizedBox(
                                            height: 16,
                                            child: Center(
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      const Divider(),
                                      ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                        minLeadingWidth: 0,
                                        horizontalTitleGap: 6,
                                        leading: Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                          color: onSurfaceDim,
                                        ),
                                        title: Text(
                                          'Trash',
                                          style: TextStyle(
                                            color: onSurfaceDim,
                                            fontSize: 13,
                                          ),
                                        ),
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => const TrashScreen(),
                                          ),
                                        ),
                                      ),
                                      const Divider(),
                                      // ── Devices section ──────────────────────
                                      if (_volumes != null &&
                                          _volumes!.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                        child: Text(
                                          'Devices',
                                          style: TextStyle(
                                            color: onSurfaceDim,
                                            fontSize: 11,
                                          ),
                                          ),
                                        ),
                                      if (_volumes == null)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          child: SizedBox(
                                            height: 16,
                                            child: Center(
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          ),
                                        )
                                      else
                                        ..._volumes!.map(
                                          (vol) => ListTile(
                                            dense: true,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                ),
                                            horizontalTitleGap: 4,
                                            minLeadingWidth: 0,
                                            leading: Icon(
                                              vol.isRemovable
                                                  ? Icons.sd_storage
                                                  : Icons.storage,
                                              size: 18,
                                              color: OneDarkColors.cyan,
                                            ),
                                            title: Text(
                                              vol.label.isNotEmpty
                                                  ? vol.label
                                                  : 'Storage',
                                              style: TextStyle(
                                                color: onSurface,
                                                fontSize: 13,
                                              ),
                                            ),
                                            subtitle: Text(
                                              _shortPath(vol.path),
                                              style: TextStyle(
                                                color: onSurfaceDim,
                                                fontSize: 10,
                                              ),
                                            ),
                                            onTap: () {
                                              setState(
                                                () => _currentPath = vol.path,
                                              );
                                            },
                                          ),
                                        ),
                                      const Divider(),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        child: Text(
                                          'Bookmarks',
                                          style: TextStyle(
                                            color: onSurfaceDim,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                      // Add bookmark button
                                      ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                        minLeadingWidth: 0,
                                        horizontalTitleGap: 6,
                                        leading: Icon(
                                          Icons.bookmark_add,
                                          size: 18,
                                          color: onSurfaceDim,
                                        ),
                                        title: Text(
                                          'Add Bookmark',
                                          style: TextStyle(
                                            color: onSurfaceDim,
                                            fontSize: 12,
                                          ),
                                        ),
                                        onTap: _addBookmark,
                                      ),
                                      // Saved bookmarks — tap to navigate, long-press to remove
                                      ..._bookmarks.map(
                                        (path) => ListTile(
                                          dense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 8,
                                              ),
                                          minLeadingWidth: 0,
                                          horizontalTitleGap: 6,
                                          leading: Icon(
                                            Icons.bookmark,
                                            size: 18,
                                            color: OneDarkColors.amber,
                                          ),
                                          title: Text(
                                            _shortPath(path),
                                            style: TextStyle(
                                              color: onSurface,
                                              fontSize: 13,
                                            ),
                                          ),
                                          onTap: () => setState(
                                            () => _currentPath = path,
                                          ),
                                          onLongPress: () =>
                                              _confirmRemoveBookmark(path),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Bottom status row
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.info_outline,
                                        size: 14,
                                        color: onSurfaceDim,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '$_itemCount items',
                                        style: TextStyle(
                                          color: onSurfaceDim,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : const SizedBox(width: 0),
                ),

                // ── Main file browser area ───────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      // Top bar
                      Container(
                        color: surfaceHighest,
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(Icons.menu, color: onSurface),
                              onPressed: () => setState(
                                () => _sidebarVisible = !_sidebarVisible,
                              ),
                              tooltip: 'Toggle Sidebar',
                            ),
                            // Breadcrumb navigation
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(children: _buildBreadcrumbs()),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Copy current path to clipboard
                            IconButton(
                              icon: Icon(
                                Icons.copy,
                                size: 18,
                                color: onSurfaceDim,
                              ),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                await Clipboard.setData(
                                  ClipboardData(text: _currentPath),
                                );
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text('Path copied: $_currentPath'),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                              tooltip: 'Copy Path',
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.search,
                                color: onSurfaceDim,
                              ),
                              onPressed: () async {
                                final result = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        SearchScreen(startPath: _currentPath),
                                  ),
                                );
                                if (result != null && mounted) {
                                  setState(() => _currentPath = result);
                                }
                              },
                              tooltip: 'Search',
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.account_tree,
                                color: onSurfaceDim,
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => FolderGraphScreen(
                                      startPath: _currentPath,
                                    ),
                                  ),
                                );
                              },
                              tooltip: 'Folder Graph',
                            ),
                            IconButton(
                              icon: Icon(
                                _previewVisible
                                    ? Icons.unfold_less
                                    : Icons.unfold_more,
                                color: _previewVisible
                                    ? cs.primary
                                    : onSurfaceDim,
                              ),
                              onPressed: () => setState(
                                () => _previewVisible = !_previewVisible,
                              ),
                              tooltip: 'Toggle Preview',
                            ),
                          ],
                        ),
                      ),
                      // File browser — persists across path changes (no key).
                      // Sidebar/breadcrumb navigation pushes path via initialPath;
                      // internal navigation fires onPathChanged to sync breadcrumbs.
                      Expanded(
                        child: FileBrowser(
                          initialPath: _currentPath,
                          onItemSelected: (item) =>
                              setState(() => _selectedItem = item),
                          onSelectionChanged: (info) =>
                              setState(() => _selectionInfo = info),
                          onClipboardChanged: (info) =>
                              setState(() => _clipboardInfo = info),
                          onPathChanged: (path) => setState(() {
                            _currentPath = path;
                            _selectedItem = null;
                          }),
                          onMarksChanged: (count) =>
                              setState(() => _markCount = count),
                          onItemCountChanged: (count) =>
                              setState(() => _itemCount = count),
                        ),
                      ),
                      // Status bar
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        color: surfaceHighest,
                        child: Row(
                          children: [
                            // Clipboard indicator (copy = cyan, cut = amber)
                            if (_clipboardInfo != null &&
                                _clipboardInfo!.hasClipboard) ...[
                              const SizedBox(width: 8),
                              Icon(
                                _clipboardInfo!.operation == 'cut'
                                    ? Icons.content_cut
                                    : Icons.content_copy,
                                size: 14,
                                color: _clipboardInfo!.operation == 'cut'
                                    ? OneDarkColors.amber
                                    : OneDarkColors.cyan,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '${_clipboardInfo!.operation == 'cut' ? 'Cut' : 'Copied'}: ${_clipboardInfo!.count}',
                                  style: TextStyle(
                                    color: _clipboardInfo!.operation == 'cut'
                                        ? OneDarkColors.amber
                                        : OneDarkColors.cyan,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            // Mark count indicator
                            if (_markCount > 0) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check_circle,
                                size: 14,
                                color: OneDarkColors.amber,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$_markCount marked',
                                style: TextStyle(
                                  color: OneDarkColors.amber,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            // Multi-select aggregate summary
                            if (_selectionInfo != null &&
                                _selectionInfo!.count > 1) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${_selectionInfo!.count} selected (${_formatBytes(_selectionInfo!.totalSizeBytes)})',
                                  style: TextStyle(
                                    color: onSurface,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            const Spacer(),
                            if (_selectedItem != null) ...[
                              const SizedBox(width: 12),
                              Icon(
                                _selectedItem!.icon,
                                size: 14,
                                color: _selectedItem!.iconColor,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _selectedItem!.name,
                                  style: TextStyle(
                                    color: onSurface,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _selectedItem!.formattedSize,
                                  style: TextStyle(
                                    color: onSurfaceDim,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Preview panel (collapsible) ──────────────────────────
                if (_previewVisible && !isMobile)
                  PreviewPanel(
                    item: _selectedItem,
                    width: 280,
                    onClose: () => setState(() => _previewVisible = false),
                  ),
              ],
            ),
            // Tab 1-4: Full-screen screens
            const BluetoothScreen(),
            const LANSharingScreen(),
            const SettingsScreen(),
            StorageAnalysisScreen(rootPath: AppPaths.home),
            const NetworkScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() {
          _selectedIndex = index;
          if (index == 0) _previewVisible = true;
        }),
        backgroundColor: surface,
        indicatorColor: cs.primaryContainer,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
          NavigationDestination(
            icon: Icon(Icons.bluetooth),
            label: 'Bluetooth',
          ),
          NavigationDestination(icon: Icon(Icons.wifi), label: 'LAN'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Storage'),
          NavigationDestination(icon: Icon(Icons.cloud), label: 'Network'),
        ],
      ),
    );
  }

  List<Widget> _buildBreadcrumbs() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    final widgets = <Widget>[];
    String accumulated = '';

    // Home root — only styled as the last crumb when we're actually at '/'
    widgets.add(_breadcrumbChip('/', '/', isLast: parts.isEmpty));

    for (final part in parts) {
      accumulated += '/$part';
      widgets.add(const SizedBox(width: 4));
      widgets.add(
        _breadcrumbChip(part, accumulated, isLast: part == parts.last),
      );
    }
    return widgets;
  }

  Widget _breadcrumbChip(String label, String path, {required bool isLast}) {
    final cs = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: () => setState(() => _currentPath = path),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isLast ? cs.primary : cs.onSurface,
          fontSize: 13,
          fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _sidebarTile(int index, IconData icon, String label, String path) {
    final cs = Theme.of(context).colorScheme;
    final onSurface = cs.onSurface;
    final isActive =
        _currentPath.startsWith(path) &&
        (_currentPath == path || _currentPath.startsWith('$path/'));
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex.add(index)),
      onExit: (_) => setState(() => _hoveredIndex.remove(index)),
      child: ListTile(
        // Compact padding so tiles fit the narrow (160px) mobile sidebar.
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minLeadingWidth: 0,
        horizontalTitleGap: 6,
        leading: Icon(
          icon,
          size: 18,
          color: isActive ? cs.primary : onSurface,
        ),
        tileColor: _hoveredIndex.contains(index)
            ? onSurface.withValues(alpha: 0.08)
            : null,
        title: Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isActive ? cs.primary : onSurface,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        selected: isActive,
        selectedTileColor: cs.primaryContainer.withValues(alpha: 0.3),
        onTap: () => setState(() => _currentPath = path),
      ),
    );
  }

  void _addBookmark() {
    final controller = TextEditingController(text: _currentPath);
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Add Bookmark', style: TextStyle(color: cs.onSurface)),
        content: TextField(
          decoration: InputDecoration(
            labelText: 'Path',
            labelStyle: TextStyle(color: cs.onSurfaceVariant),
          ),
          style: TextStyle(color: cs.onSurface),
          controller: controller,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final path = controller.text.trim();
              if (path.isEmpty) return;
              if (_bookmarks.contains(path)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Already bookmarked'),
                    backgroundColor: OneDarkColors.amber,
                  ),
                );
                return;
              }
              final dir = Directory(path);
              if (!await dir.exists()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Path does not exist'),
                    backgroundColor: OneDarkColors.red,
                  ),
                );
                return;
              }
              setState(() => _bookmarks.add(path));
              BookmarksService.save(_bookmarks);
              if (!mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Bookmark added'),
                  backgroundColor: OneDarkColors.green,
                ),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  /// Long-press on a bookmark tile: confirm before removing it.
  void _confirmRemoveBookmark(String path) {
    final cs = Theme.of(context).colorScheme;
    showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(
          'Remove bookmark?',
          style: TextStyle(color: cs.onSurface),
        ),
        content: Text(
          _shortPath(path),
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove', style: TextStyle(color: cs.error)),
          ),
        ],
      ),
    ).then((remove) {
      if (remove == true) {
        setState(() => _bookmarks.remove(path));
        BookmarksService.save(_bookmarks);
      }
    });
  }

  /// Formats a byte count for the status bar (B / KB / MB / GB).
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Strips the primary emulated storage prefix for display.
  String _shortPath(String path) {
    final home = AppPaths.home;
    if (path.startsWith('$home/')) return path.substring(home.length + 1);
    if (path == home) return 'SD Card';
    return path.split('/').where((p) => p.isNotEmpty).last;
  }
}
