import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'theme/theme.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'utils/app_paths.dart' show StoragePermissions;
import 'widgets/file_browser.dart';
import 'utils/file_utils.dart' show FileItem, FileUtils;
import 'widgets/preview_panel.dart';
import 'screens/search_screen.dart';
import 'screens/trash_screen.dart';
import 'screens/lan_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_analysis_screen.dart';
import 'screens/network_screen.dart';
import 'screens/recent_files_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/notepad_screen.dart';
import 'screens/document_scanner_screen.dart';
import 'screens/app_analyzer_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/cloud_browser_screen.dart';
import 'services/widget_service.dart';
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
    // Load saved theme mode and view mode
  await loadThemeMode();
  await loadPersistedViewMode();
  await loadPersistedRootMode();
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

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _sidebarVisible = true;
  /// Collapsible sidebar sections (SwordFM-style headers with chevrons).
  /// 'places' starts open; the rest are collapsed until tapped.
  final Set<String> _openSections = {'places'};
  bool _previewVisible = true;
  String _currentPath = ''; // resolved in initState for Android
  FileItem? _selectedItem;

  int _itemCount = 0; // item count in the current directory

  /// When a tool from the left sidebar (Scanner, Notepad, App Analyzer, Cast)
  /// is opened, it is embedded here inside the Files tab so the bottom
  /// navigation bar stays visible instead of being covered by a pushed full
  /// screen route. LAN/Network/Cloud map to their existing bottom-bar tabs.
  Widget? _sidebarTool;
  bool _toolFullscreen = false;

  // The Terminal tab is built lazily on first visit (the IndexedStack builds
  // all children eagerly, and spawning a PTY at app start would be wasteful).
  bool _terminalVisited = false;

  // "All files access" grant prompt is shown at most once per session.
  bool _storagePromptShown = false;

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
    WidgetsBinding.instance.addObserver(this);
    // On Android, resolve the actual storage root synchronously after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _currentPath = AppPaths.home);
      _loadVolumes();
      _loadBookmarks();
      _loadHomeDirs();
      _ensureStorageAccess();
      FileUtils.autoEmptyTrashFromPrefs();
      FileUtils.loadClipboardHistory();
      checkAutoTheme();
      _syncWidgetBookmarks();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // After the user returns from the system "All files access" settings
    // screen, re-check the grant and refresh storage volumes / home dirs so
    // the real (e.g. 120GB) storage shows instead of the scoped sandbox.
    if (state == AppLifecycleState.resumed) {
      _ensureStorageAccess();
      _loadVolumes();
      _loadHomeDirs();
      checkAutoTheme();
    }
  }

  /// On Android, "All files access" unlocks the phone's real storage
  /// (120GB in the user's case) instead of the ~1.5GB scoped sandbox.
  /// Fire-and-forget: surface the system grant screen only once per launch.
  Future<void> _ensureStorageAccess() async {
    if (kIsWeb) return;
    try {
      final granted = await allFilesAccessGranted();
      if (granted) return;
      if (_storagePromptShown) return; // don't nag on every resume
      _storagePromptShown = true;
      // Ask the user (non-blocking) so they can grant full storage access
      // once, which also fixes paste / duplicate-scan permission errors.
      final go = await _promptAllFilesAccess();
      if (go) await requestAllFilesAccess();
    } catch (_) {}
  }

  Future<bool> _promptAllFilesAccess() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'Allow full storage access?',
          style: TextStyle(color: OneDarkColors.fg, fontSize: 16),
        ),
        content: Text(
          'To browse all folders, view your real storage capacity, paste files '
          'and scan duplicates, SwordFM needs "Files & media → All files access". '
          'You can grant it in the next screen.',
          style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (messenger.mounted) messenger.hideCurrentSnackBar();
    return ok ?? false;
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await BookmarksService.load();
    if (mounted) {
      setState(() => _bookmarks = bookmarks);
      WidgetService.syncBookmarks(bookmarks);
    }
  }

  Future<void> _syncWidgetBookmarks() async {
    final bookmarks = await BookmarksService.load();
    WidgetService.syncBookmarks(bookmarks);
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
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedIndex != 0) {
          setState(() => _selectedIndex = 0);
        }
      },
      child: Scaffold(
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
                            // Square corners — no angular radius.
                            shape: const RoundedRectangleBorder(),
                            child: Column(
                              children: [
                                // Sidebar header — collapsible "Places"
                                _sectionHeader('places', 'Places',
                                    Icons.folder_special),

                                // Places list — scrolls when the drawer is short
                                Expanded(
                                  child: ListView(
                                    children: [
                                      if (_openSections
                                          .contains('places')) ...[
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
                                            fontSize: 14,
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
                                            vertical: 6,
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
                                            fontSize: 14,
                                          ),
                                        ),
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => const TrashScreen(),
                                          ),
                                        ),
                                      ),
                                      ], // places
                                      const Divider(),
                                      // ── Tools section ──────────────────────
                                      _sectionHeader(
                                          'tools', 'Tools', Icons.build_rounded),
                                      if (_openSections.contains('tools')) ...[
                                        _sidebarAction(
                                          Icons.document_scanner,
                                          'Scanner',
                                          () => _openSidebarTool(
                                            const DocumentScannerScreen(),
                                          ),
                                        ),
                                      _sidebarAction(
                                        Icons.note_add,
                                        'Notepad',
                                        () => _openSidebarTool(
                                          const NotepadScreen(),
                                        ),
                                      ),
                                      _sidebarAction(
                                        Icons.apps,
                                        'App Analyzer',
                                        () => _openSidebarTool(
                                          const AppAnalyzerScreen(),
                                        ),
                                      ),
                                      _sidebarAction(
                                        Icons.cast,
                                        'Cast',
                                        () => _openSidebarTool(
                                          const CastScreen(),
                                        ),
                                      ),
                                      ], // tools
                                      const Divider(),
                                      // ── Network section ─────────────────────
                                      _sectionHeader('network', 'Network',
                                          Icons.lan_rounded),
                                      if (_openSections
                                          .contains('network')) ...[
                                        _sidebarAction(
                                          Icons.wifi,
                                          'LAN Sharing',
                                          () => _openSidebarTab(1),
                                        ),
                                        _sidebarAction(
                                          Icons.cloud,
                                          'Network (FTP/WebDAV)',
                                          () => _openSidebarTab(4),
                                        ),
                                      ], // network
                                      const Divider(),
                                      // ── Devices section ──────────────────────
                                      _sectionHeader('devices', 'Devices',
                                          Icons.storage_rounded),
                                      if (_openSections
                                          .contains('devices')) ...[
                                        if (_volumes == null)
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
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
                                        else if (_volumes!.isEmpty)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            child: Text(
                                              'No removable devices',
                                              style: TextStyle(
                                                color: onSurfaceDim,
                                                fontSize: 12,
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
                                                fontSize: 14,
                                              ),
                                            ),
                                            subtitle: Text(
                                              _shortPath(vol.path),
                                              style: TextStyle(
                                                color: onSurfaceDim,
                                                fontSize: 11,
                                              ),
                                            ),
                                            onTap: () {
                                              setState(
                                                () => _currentPath = vol.path,
                                              );
                                            },
                                          ),
                                        ),
                                      ], // devices
                                      const Divider(),
                                      // ── Cloud Storage section ──────────────────
                                      _sectionHeader('cloud', 'Cloud',
                                          Icons.cloud_rounded),
                                      if (_openSections.contains('cloud')) ...[
                                        _sidebarAction(
                                          Icons.cloud,
                                          'Cloud Storage',
                                          () => _openSidebarTab(5),
                                        ),
                                      ], // cloud
                                      const Divider(),
                                      // ── Bookmarks section ──────────────────────
                                      _sectionHeader('bookmarks', 'Bookmarks',
                                          Icons.bookmark_rounded),
                                      if (_openSections
                                          .contains('bookmarks')) ...[
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
                                            fontSize: 14,
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
                                              fontSize: 14,
                                            ),
                                          ),
                                          onTap: () => setState(
                                            () => _currentPath = path,
                                          ),
                                          onLongPress: () =>
                                              _confirmRemoveBookmark(path),
                                        ),
                                      ),
                                      ], // bookmarks
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
                                          fontSize: 11,
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
                            // Desktop-only actions — on phones (width < 600) the
                            // 5 fixed buttons overflow the 200px browser pane
                            // when the sidebar is open (RenderFlex overflow).
                            // The preview panel is never shown on mobile and the
                            // folder graph is a niche desktop feature.
                            if (!isMobile) ...[
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
                          ],
                        ),
                      ),
                      Expanded(
                        child: _sidebarTool != null
                            // Tool opened from the sidebar (Scanner, Notepad, …).
                            // Rendered inside the Files tab so the bottom
                            // navigation bar stays visible. No key: the widget
                            // is rebuilt on each open so state starts fresh.
                            ? _buildSidebarToolView()
                            : GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: _sidebarVisible
                                    ? () => setState(
                                        () => _sidebarVisible = false,
                                      )
                                    : null,
                                child: FileBrowser(
                                  initialPath: _currentPath,
                                  onItemSelected: (item) =>
                                      setState(() => _selectedItem = item),
                                  onPathChanged: (path) => setState(() {
                                    _currentPath = path;
                                    _selectedItem = null;
                                  }),
                                  onItemCountChanged: (count) =>
                                      setState(() => _itemCount = count),
                                  onBookmarkCurrentPath: (path) =>
                                      _addBookmark(path),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),

                // ── Preview panel (collapsible) ──────────────────────────
                                if (_previewVisible && !isMobile)
                  GestureDetector(
                    // Tapping anywhere in the right-preview area closes it.
                    onTap: () => setState(() => _previewVisible = false),
                    behavior: HitTestBehavior.opaque,
                    child: PreviewPanel(
                      item: _selectedItem,
                      width: 280,
                      onClose: () => setState(() => _previewVisible = false),
                    ),
                  ),
              ],
            ),
            // Tab 1-6: Full-screen screens.
            LANSharingScreen(),
                        SettingsScreen(
              onToolTap: (index) {
                // Navigate to the corresponding bottom-bar tab instead of
                // pushing a full-screen route that hides the nav bar.
                setState(() {
                  _selectedIndex = index;
                  _sidebarTool = null;
                  if (index == 0) _previewVisible = true;
                });
              },
            ),
            StorageAnalysisScreen(rootPath: AppPaths.home),
            const NetworkScreen(),
            const CloudBrowserScreen(),
            // Terminal — lazy: only spawns the PTY shell after first visit.
            _terminalVisited
                ? TerminalScreen(startPath: AppPaths.home)
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() {
          _selectedIndex = index;
          if (index == 0) _previewVisible = true;
          if (index == 6) _terminalVisited = true;
        }),
        backgroundColor: surface,
        indicatorColor: cs.primaryContainer,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.wifi), label: 'LAN'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Storage'),
          NavigationDestination(icon: Icon(Icons.cloud), label: 'Network'),
          NavigationDestination(icon: Icon(Icons.cloud_queue), label: 'Cloud'),
          NavigationDestination(icon: Icon(Icons.terminal), label: 'Terminal'),
        ],
      ),
    ),
    ); // PopScope
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

  /// Expandable sidebar section header — tap to show/hide the items below
  /// it (like the desktop SwordFM sidebar's collapsible groups).
  Widget _sectionHeader(String key, String title, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    final open = _openSections.contains(key);
    return InkWell(
      onTap: () => setState(() {
        open ? _openSections.remove(key) : _openSections.add(key);
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
            ),
            AnimatedRotation(
              turns: open ? 0 : -0.25,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
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
          size: 20,
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
                  fontSize: 16,
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

    Widget _sidebarAction(IconData icon, String label, VoidCallback onTap) {
    final onSurfaceDim = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      minLeadingWidth: 0,
      horizontalTitleGap: 6,
      leading: Icon(icon, size: 20, color: onSurfaceDim),
      title: Text(
        label,
        style: TextStyle(color: onSurfaceDim, fontSize: 16),
      ),
      onTap: onTap,
    );
  }

  /// Opens a sidebar tool embedded in the Files tab so the bottom navigation
  /// bar stays visible (instead of pushing a full-screen route over it).
  void _openSidebarTool(Widget tool) {
    setState(() {
      _selectedIndex = 0; // stay on Files
      _toolFullscreen = false;
      _sidebarTool = tool;
    });
  }

  /// Switches to an existing bottom-bar tab (LAN=1, Network=4, Cloud=5) so the
  /// bottom navigation bar remains visible when opened from the left sidebar.
  void _openSidebarTab(int index) {
    setState(() {
      _sidebarTool = null;
      _selectedIndex = index;
      if (index == 0) _previewVisible = true;
    });
  }

  void _closeSidebarTool() {
    setState(() => _sidebarTool = null);
  }

  /// Toggles the embedded tool between the browser area and full screen.
  /// Full screen also collapses the sidebar for maximum width; switching to
  /// another bottom-bar tab always clears the embedded tool so navigation
  /// never gets stuck on a tool.
  void _toggleToolFullscreen() {
    setState(() {
      _toolFullscreen = !_toolFullscreen;
      if (_toolFullscreen) _sidebarVisible = false;
    });
  }

  /// Renders a sidebar-launched tool inside the Files tab. The slim header
  /// offers a Back (close) button and a full-screen toggle, and the tool sits
  /// below it — all while the bottom navigation bar remains visible.
  Widget _buildSidebarToolView() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          color: cs.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: cs.onSurface),
                tooltip: 'Back to files',
                onPressed: _closeSidebarTool,
              ),
              Expanded(
                child: Text(
                  _toolFullscreen ? 'Full screen' : 'Tool',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(
                  _toolFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: cs.onSurfaceVariant,
                ),
                tooltip: _toolFullscreen ? 'Exit full screen' : 'Full screen',
                onPressed: _toggleToolFullscreen,
              ),
            ],
          ),
        ),
        Expanded(child: _sidebarTool!),
      ],
    );
  }

  void _addBookmark([String? path]) {
    final target = path ?? _currentPath;
    final controller = TextEditingController(text: target);
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

  /// Strips the primary emulated storage prefix for display.
  String _shortPath(String path) {
    final home = AppPaths.home;
    if (path.startsWith('$home/')) return path.substring(home.length + 1);
    if (path == home) return 'SD Card';
    return path.split('/').where((p) => p.isNotEmpty).last;
  }
}
