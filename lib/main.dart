import 'package:flutter/material.dart';
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
import 'services/entitlement_service.dart';
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
  runApp(const SwordFM());
}

class SwordFM extends StatelessWidget {
  const SwordFM({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final baseTheme = buildOneDarkTheme();
        final theme = darkDynamic != null
            ? baseTheme.copyWith(colorScheme: baseTheme.colorScheme.copyWith(
                  primary: darkDynamic.primary,
                  secondary: darkDynamic.secondary,
                  error: darkDynamic.error,
                ))
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

  // ignore: prefer_final_fields — mutated via setState
  List<String> _bookmarks = []; // populated from prefs in real app
  final Set<int> _hoveredIndex = {}; // tracks which sidebar item is hovered

  @override
  void initState() {
    super.initState();
    // On Android, resolve the actual storage root synchronously after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _currentPath = AppPaths.home);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            // Tab 0: Files
            Row(
              children: [
                // ── Sidebar (slides in/out via clipping, always present) ──
                AnimatedSlide(
                  offset: _sidebarVisible ? Offset.zero : const Offset(-1, 0),
                  duration: const Duration(milliseconds: 220),
                  child: AnimatedOpacity(
                    opacity: _sidebarVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    child: IgnorePointer(
                      ignoring: !_sidebarVisible,
                      child: SizedBox(
                        width: 200,
                        child: Card(
                          color: OneDarkColors.bgDark,
                          elevation: 0,
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              // Sidebar header
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Icon(Icons.folder_special, color: OneDarkColors.cyan, size: 20),
                                    const SizedBox(width: 8),
                                    const Text('Places', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                                  ],
                                ),
                              ),
                              const Divider(height: 1),

                              // Places list
                              Expanded(
                                child: ListView(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: [
                                    _sidebarTile(0, Icons.home, 'Home', AppPaths.home),
                                    _sidebarTile(1, Icons.desktop_windows, 'Desktop', AppPaths.desktop),
                                    _sidebarTile(2, Icons.document_scanner, 'Documents', AppPaths.documents),
                                    _sidebarTile(3, Icons.download, 'Downloads', AppPaths.downloads),
                                    _sidebarTile(4, Icons.image, 'Pictures', AppPaths.pictures),
                                    _sidebarTile(5, Icons.music_note, 'Music', AppPaths.music),
                                    _sidebarTile(6, Icons.movie, 'Videos', AppPaths.videos),
                                    ListTile(
                                      leading: Icon(Icons.delete_outline, size: 18, color: OneDarkColors.fgDim),
                                      title: const Text('Trash', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13)),
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(builder: (_) => const TrashScreen()),
                                      ),
                                    ),
                                    const Divider(),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      child: Text('Bookmarks',
                                          style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                                    ),
                                    // Add bookmark button
                                    ListTile(
                                      leading: Icon(Icons.bookmark_add, size: 18, color: OneDarkColors.fgDim),
                                      title: const Text('Add Bookmark', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
                                      onTap: _addBookmark,
                                    ),
                                  ],
                                ),
                              ),

                              // Bottom spacer + status
                              const Spacer(),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Row(
                                  children: [
                                    Icon(Icons.info_outline, size: 14, color: OneDarkColors.fgDim),
                                    const SizedBox(width: 4),
                                    Text('$itemsCount items', style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 10)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Main file browser area ───────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      // Top bar
                      Container(
                        color: OneDarkColors.bgDark,
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.menu, color: OneDarkColors.fg),
                              onPressed: () => setState(() => _sidebarVisible = !_sidebarVisible),
                              tooltip: 'Toggle Sidebar',
                            ),
                            // Breadcrumb navigation
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: _buildBreadcrumbs(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.search, color: OneDarkColors.fgDim),
                              onPressed: () async {
                                final result = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => SearchScreen(startPath: _currentPath),
                                  ),
                                );
                                if (result != null && mounted) {
                                  setState(() => _currentPath = result);
                                }
                              },
                              tooltip: 'Search',
                            ),
                            IconButton(
                              icon: const Icon(Icons.account_tree, color: OneDarkColors.fgDim),
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
                              icon: Icon(_previewVisible ? Icons.unfold_less : Icons.unfold_more,
                                  color: _previewVisible ? OneDarkColors.cyan : OneDarkColors.fgDim),
                              onPressed: () => setState(() => _previewVisible = !_previewVisible),
                              tooltip: 'Toggle Preview',
                            ),
                          ],
                        ),
                      ),
                      // File browser — rebuilds with new _currentPath via key
                      Expanded(
                        child: FileBrowser(
                          key: ValueKey(_currentPath),
                          initialPath: _currentPath,
                          onItemSelected: (item) => setState(() => _selectedItem = item),
                        ),
                      ),
                      // Status bar
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        color: OneDarkColors.bgDark,
                        child: Row(
                          children: [
                            Icon(Icons.folder_open, size: 14, color: OneDarkColors.fgDim),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(_currentPath,
                                  style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                            ),
                            const Spacer(),
                            if (_selectedItem != null) ...[
                              const SizedBox(width: 12),
                              Icon(_selectedItem!.icon, size: 14, color: _selectedItem!.iconColor),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(_selectedItem!.name,
                                    style: const TextStyle(color: OneDarkColors.fg, fontSize: 11)),
                              ),
                              const SizedBox(width: 12),
                              Text(_selectedItem!.formattedSize,
                                  style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
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
                    isVisible: _previewVisible,
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
        backgroundColor: OneDarkColors.bgDark,
        indicatorColor: OneDarkColors.select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Bluetooth'),
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

    // Home root
    widgets.add(_breadcrumbChip('/', '/', isLast: true));

    for (final part in parts) {
      accumulated += '/$part';
      widgets.add(const SizedBox(width: 4));
      widgets.add(_breadcrumbChip(part, accumulated, isLast: part == parts.last));
    }
    return widgets;
  }

  Widget _breadcrumbChip(String label, String path, {required bool isLast}) {
    return TextButton(
      onPressed: () => setState(() => _currentPath = path),
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
      child: Text(label,
          style: TextStyle(
            color: isLast ? OneDarkColors.cyan : OneDarkColors.fg,
            fontSize: 13,
            fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
          )),
    );
  }

  Widget _sidebarTile(int index, IconData icon, String label, String path) {
    final isActive = _currentPath.startsWith(path) &&
        (_currentPath == path || _currentPath.startsWith('$path/'));
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex.add(index)),
      onExit: (_) => setState(() => _hoveredIndex.remove(index)),
      child: ListTile(
        leading: Icon(icon, size: 18, color: isActive ? OneDarkColors.cyan : OneDarkColors.fg),
        tileColor: _hoveredIndex.contains(index) ? OneDarkColors.dim.withValues(alpha: 0.3) : null,
        title: Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isActive ? OneDarkColors.selectFg : OneDarkColors.fg,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        selected: isActive,
        selectedTileColor: OneDarkColors.select,
        onTap: () => setState(() => _currentPath = path),
      ),
    );
  }

  void _addBookmark() {
    final controller = TextEditingController(text: _currentPath);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: const Text('Add Bookmark', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          decoration: const InputDecoration(
            labelText: 'Path',
            labelStyle: TextStyle(color: OneDarkColors.fgDim),
          ),
          style: const TextStyle(color: OneDarkColors.fg),
          controller: controller,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() => _bookmarks.add(controller.text));
              }
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Bookmark added'), backgroundColor: OneDarkColors.green),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // Count items placeholder — in production this would be a state manager
  int get itemsCount => 0;
}
