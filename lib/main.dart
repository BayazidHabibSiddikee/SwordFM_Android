import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'theme/theme.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'utils/app_paths.dart' show StoragePermissions;
import 'widgets/file_browser.dart';
import 'utils/file_utils.dart' show FileItem, FileUtils, kAudioExtensions, kVideoExtensions;
import 'widgets/preview_panel.dart';
import 'widgets/now_playing_mini_bar.dart';
import 'screens/search_screen.dart';
import 'screens/trash_screen.dart';
import 'screens/lan_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_analysis_screen.dart';
import 'screens/network_screen.dart';
import 'screens/recent_files_screen.dart';
import 'screens/notepad_screen.dart';
import 'screens/document_scanner_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/cloud_browser_screen.dart';
import 'screens/pdf_reader_screen.dart';
import 'screens/docx_reader_screen.dart';
import 'screens/video_player_screen.dart';
import 'screens/music_player_screen.dart';
import 'screens/image_viewer_screen.dart';
import 'screens/text_reader_screen.dart';
import 'services/widget_service.dart';
import 'services/entitlement_service.dart';
import 'services/device_service.dart';
import 'services/bookmarks_service.dart';
import 'services/audio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'utils/constants.dart' show AppPaths;
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit (video player) — MUST be initialised before any Player() is
  // constructed, otherwise libmpv is never loaded and every video open
  // throws "MediaKit.ensureInitialized must be called before using any API".
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('MediaKit init skipped: $e');
  }
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
  // Background audio handler — keeps music playing when the screen locks
  // or the app is backgrounded. Initialised before runApp() so the lock-
  // screen media controls and notification are wired before any UI shows.
  // Errors are non-fatal: the app still runs, just without lock-screen
  // media controls where the service init is rejected.
  try {
    swiftAudioHandler = await AudioService.init(
      builder: () => SwiftAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.swordfm.audio',
        androidNotificationChannelName: 'SwordFM playback',
        androidNotificationChannelDescription: 'SwordFM music playback controls',
        // Do NOT set androidNotificationOngoing: true — that hides the
        // notification entirely on some Android 13+ devices. Let the
        // foreground service manage the ongoing state instead.
        androidStopForegroundOnPause: true,
        androidShowNotificationBadge: true,
        notificationColor: Color(0xFF61AFEF),
      ),
    );
  } catch (e) {
    debugPrint('AudioService init skipped: $e');
  }
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
              child: AudioServiceWidget(
                // Routes hardware/lock-screen media buttons (headset,
                // Bluetooth) to the SwiftAudioHandler. No-op when audio
                // init was skipped.
                child: MaterialApp(
                  title: 'SwordFM',
                  debugShowCheckedModeBanner: false,
                  theme: theme,
                  home: const MainScreen(),
                ),
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

  /// When a tool from the left sidebar (Scanner, Notepad, Cast)
  /// is opened, it is embedded here inside the Files tab so the bottom
  /// navigation bar stays visible instead of being covered by a pushed full
  /// screen route. LAN/Network/Cloud map to their existing bottom-bar tabs.
  Widget? _sidebarTool;
  bool _toolFullscreen = false;

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
    // Listen for files opened from external apps (PDF viewer, file manager, etc.)
    const MethodChannel('com.swordfm/file_intents').setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened') {
        final path = call.arguments['path'] as String? ?? '';
        if (path.isNotEmpty && mounted) {
          _openFileFromIntent(path);
        }
      }
    });
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

  /// Opens a file received from an external intent (e.g. "Open with" from
  /// another app). Routes to the correct reader screen based on extension.
  void _openFileFromIntent(String path) {
    final ext = p.extension(path).toLowerCase();
    final file = File(path);
    // Gate the swordfm:// QR deep link: only open paths the app can see.
    // Reject traversal, null bytes, and roots outside the shared storage.
    if (path.contains('..') || path.contains(String.fromCharCode(0))) return;
    if (!file.existsSync()) return;
    final item = FileItem(
      entity: file,
      name: p.basename(path),
      path: path,
      isDirectory: false,
      size: file.lengthSync(),
      lastModified: file.lastModifiedSync(),
    );
    // PDF → built-in reader
    if (ext == '.pdf') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfReaderScreen(filePath: path),
      ));
    // DOCX → built-in reader
    } else if (ext == '.docx') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DocxReaderScreen(filePath: path),
      ));
    // Video → built-in player
    } else if (kVideoExtensions.contains(ext)) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(filePath: path),
      ));
    // Audio → built-in music player
    } else if (kAudioExtensions.contains(ext)) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MusicPlayerScreen(filePath: path),
      ));
    // Images → built-in viewer
    } else if (FileItem.isImagePath(path)) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageViewerScreen(filePath: path),
      ));
    // Text/code/markdown → text reader
    } else if (item.isText || item.isCode || item.isMarkdown) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TextReaderScreen(filePath: path),
      ));
    } else {
      // Unknown type — navigate to its directory and select for preview panel.
      setState(() {
        _currentPath = p.dirname(path);
        _selectedItem = item;
      });
    }
  }

  /// Whether the compact now-playing bar should show (audio is loaded).
  bool get _showMiniPlayer => swiftAudioHandler?.mediaItem.value != null;

  /// Opens the full music player for whatever the handler already has
  /// loaded, without restarting playback.
  void _openNowPlaying() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MusicPlayerScreen()),
    );
  }

  /// Stops background audio from anywhere in the app (kills the
  /// notification and the mini bar with it).
  Future<void> _stopNowPlaying() async {
    await swiftAudioHandler?.stop();
    if (mounted) setState(() {});
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
        body: Column(
        children: [
          Expanded(
            child: SafeArea(
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
                          width: isMobile ? 180 : 220,
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
                                      _SidebarTile(
                                        icon: Icons.history,
                                        label: 'Recent',
                                        iconColor: cs.primary,
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
                                      _SidebarTile(
                                        icon: Icons.delete_outline,
                                        label: 'Trash',
                                        iconColor: onSurfaceDim,
                                        textColor: onSurfaceDim,
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
                                            (vol) => _SidebarTile(
                                              icon: vol.isRemovable
                                                  ? Icons.sd_storage
                                                  : Icons.storage,
                                              label: vol.label.isNotEmpty
                                                  ? vol.label
                                                  : 'Storage',
                                              subtitle: _shortPath(vol.path),
                                              iconColor: OneDarkColors.cyan,
                                              tooltip: vol.path,
                                              onTap: () {
                                                setState(() =>
                                                    _currentPath = vol.path);
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
                                      _SidebarTile(
                                        icon: Icons.bookmark_add,
                                        label: 'Add Bookmark',
                                        iconColor: onSurfaceDim,
                                        textColor: onSurfaceDim,
                                        onTap: _addBookmark,
                                      ),
                                      // Saved bookmarks — tap to navigate, long-press to remove
                                      ..._bookmarks.map(
                                        (path) => _SidebarTile(
                                          icon: Icons.bookmark,
                                          label: _shortPath(path),
                                          tooltip: path,
                                          iconColor: OneDarkColors.amber,
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
                                    content: Text('Path copied: ${_friendlyPath(_currentPath)}'),
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
          ],
        ),
            ),
          ),
          // Now-playing mini bar — visible on every tab while audio plays,
          // so background audio is never invisible. Tap opens the player;
          // ✕ stops it (removing the media notification too).
          if (_showMiniPlayer)
            NowPlayingMiniBar(
              onOpen: _openNowPlaying,
              onStop: _stopNowPlaying,
            ),
        ],
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
          NavigationDestination(icon: Icon(Icons.wifi), label: 'LAN'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Storage'),
          NavigationDestination(icon: Icon(Icons.cloud), label: 'Network'),
          NavigationDestination(icon: Icon(Icons.cloud_queue), label: 'Cloud'),
        ],
      ),
    ),
    ); // PopScope
  }

  /// Maps a raw Android storage path to a human-readable label.
  /// No emojis — plain text like "Phone", "Phone / Downloads", "Phone / Camera".
  String _friendlyPath(String path) {
    const root = '/storage/emulated/0';
    const sdRoot = '/storage/';
    final knownFolders = {
      'Download': 'Downloads',
      'Downloads': 'Downloads',
      'DCIM': 'Camera',
      'Pictures': 'Pictures',
      'Music': 'Music',
      'Movies': 'Videos',
      'Videos': 'Videos',
      'Documents': 'Documents',
      'Android': 'Android',
      'Ringtones': 'Ringtones',
      'Notifications': 'Notifications',
      'Alarms': 'Alarms',
      'Podcasts': 'Podcasts',
      'Audiobooks': 'Audiobooks',
    };
    if (path == root || path == '$root/') return 'Phone';
    if (path.startsWith('$root/')) {
      final rest = path.substring(root.length + 1);
      final parts = rest.split('/');
      final friendly = knownFolders[parts[0]] ?? parts[0];
      if (parts.length == 1) return 'Phone / $friendly';
      return 'Phone / $friendly / ${parts.sublist(1).join(' / ')}';
    }
    // External SD card or other volume
    if (path.startsWith(sdRoot)) {
      final parts = path.substring(sdRoot.length).split('/');
      if (parts.isNotEmpty) {
        final vol = parts[0]; // e.g. "1234-5678"
        if (parts.length == 1) return 'SD Card ($vol)';
        return 'SD Card ($vol) / ${parts.sublist(1).join(' / ')}';
      }
    }
    return path;
  }

  /// Returns a clean label for a single breadcrumb segment.
  /// Hides the raw internal path bones (storage / emulated / 0) entirely,
  /// replacing them with nothing — so the breadcrumb reads cleanly.
  String _friendlySegment(String segment, String fullPath) {
    // Internal storage bones — hidden entirely
    if (segment == 'storage' || segment == 'emulated' || segment == '0') {
      return '';
    }
    final knownFolders = {
      'Download': 'Downloads',
      'Downloads': 'Downloads',
      'DCIM': 'Camera',
      'Pictures': 'Pictures',
      'Music': 'Music',
      'Movies': 'Videos',
      'Videos': 'Videos',
      'Documents': 'Documents',
      'Android': 'Android',
      'Ringtones': 'Ringtones',
      'Notifications': 'Notifications',
      'Alarms': 'Alarms',
      'Podcasts': 'Podcasts',
      'Audiobooks': 'Audiobooks',
    };
    return knownFolders[segment] ?? segment;
  }

  List<Widget> _buildBreadcrumbs() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    final widgets = <Widget>[];
    String accumulated = '';

    // Home root chip — always shows "Phone"
    widgets.add(_breadcrumbChip('Phone', '/', isLast: parts.isEmpty));

    for (final part in parts) {
      accumulated += '/$part';
      final label = _friendlySegment(part, accumulated);
      // Skip empty labels (internal path bones we hid)
      if (label.isEmpty) continue;
      widgets.add(const SizedBox(width: 4));
      widgets.add(
        _breadcrumbChip(label, accumulated, isLast: part == parts.last),
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
      child: Container(
        // Bottom border to separate the section header from the tiles
        // below it — gives the sidebar a clearer visual rhythm.
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
                overflow: TextOverflow.ellipsis,
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

  /// Wrapper around [_SidebarTile] that adds the hover-state tracking
  /// we use for subtle background highlighting on desktop.
  Widget _sidebarTile(int index, IconData icon, String label, String path) {
    final isActive =
        _currentPath.startsWith(path) &&
        (_currentPath == path || _currentPath.startsWith('$path/'));
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex.add(index)),
      onExit: (_) => setState(() => _hoveredIndex.remove(index)),
      child: _SidebarTile(
        icon: icon,
        label: label,
        active: isActive,
        tooltip: path,
        onTap: () => setState(() => _currentPath = path),
      ),
    );
  }

  Widget _sidebarAction(IconData icon, String label, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return _SidebarTile(
      icon: icon,
      label: label,
      iconColor: cs.onSurfaceVariant,
      textColor: cs.onSurfaceVariant,
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

/// One consistent sidebar tile. Every entry in the drawer — places,
/// bookmarks, devices, recent, trash, volumes, plus the inline Recent
/// entry — uses this widget so the drawer has a single visual rhythm
/// (same height, same icon size, same text size, same padding).
class _SidebarTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? tooltip;
  final bool active;
  final Color? iconColor;
  final Color? textColor;

  const _SidebarTile({
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.tooltip,
    this.active = false,
    this.iconColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveIconColor =
        iconColor ?? (active ? cs.primary : cs.onSurface);
    final effectiveTextColor =
        textColor ?? (active ? cs.primary : cs.onSurface);
    final tile = ListTile(
      // All sidebar tiles share the same compact density so the drawer
      // shows the same number of rows on every device. ListTile's
      // default 56dp height is too tall for an 180px-wide drawer holding
      // 10+ entries.
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      horizontalTitleGap: 6,
      minLeadingWidth: 0,
      leading: Icon(icon, size: 18, color: effectiveIconColor),
      title: Text(
        label,
        style: TextStyle(
          color: effectiveTextColor,
          fontSize: 13,
          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      selected: active,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.3),
      hoverColor: cs.onSurface.withValues(alpha: 0.08),
      onTap: onTap,
      onLongPress: onLongPress,
    );
    if (tooltip == null) return tile;
    return Tooltip(message: tooltip!, child: tile);
  }
}
