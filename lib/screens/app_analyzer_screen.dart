import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:installed_apps/installed_apps.dart';
import '../theme/theme.dart';

/// Shows device information and installed apps with details.
class AppAnalyzerScreen extends StatefulWidget {
  const AppAnalyzerScreen({super.key});
  @override
  State<AppAnalyzerScreen> createState() => _AppAnalyzerState();
}

class _AppAnalyzerState extends State<AppAnalyzerScreen> {
  bool _loading = true;
  String _deviceInfo = '';
  List<_AppInfo> _apps = [];
  List<_AppInfo> _filteredApps = [];
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInfo();
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      _filteredApps = q.isEmpty
          ? List.from(_apps)
          : _apps.where((a) => a.name.toLowerCase().contains(q) || a.pkg.toLowerCase().contains(q)).toList();
    });
  }

  Future<void> _loadInfo() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      _deviceInfo = '${android.model} (${android.brand})\n'
          'Android ${android.version.release} (SDK ${android.version.sdkInt})\n'
          'Board: ${android.board}\n'
          'Hardware: ${android.hardware}';
      // Get installed apps via MethodChannel-like approach
      _apps = await _getInstalledApps();
      _apps.sort((a, b) => a.name.compareTo(b.name));
      _filteredApps = List.from(_apps);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<List<_AppInfo>> _getInstalledApps() async {
    final apps = <_AppInfo>[];
    try {
      // Query ALL apps — system + user. The first arg is excludeSystemApps
      // (must be false to show every app, not just the ~50 user-installed
      // ones); the second enables icons so each app shows its real launcher
      // icon instead of a generic placeholder.
      final installedApps = await InstalledApps.getInstalledApps(false, true);
      for (final app in installedApps) {
        apps.add(_AppInfo(
          name: app.name,
          pkg: app.packageName,
          version: app.getVersionInfo(),
          icon: app.icon,
        ));
      }
    } catch (e) {
      debugPrint('AppAnalyzer: failed to get installed apps: $e');
    }
    return apps;
  }

  void _sortApps(String sortBy) {
    setState(() {
      switch (sortBy) {
        case 'name':
          _filteredApps.sort((a, b) => a.name.compareTo(b.name));
        case 'pkg':
          _filteredApps.sort((a, b) => a.pkg.compareTo(b.pkg));
        case 'version':
          _filteredApps.sort((a, b) => a.version.compareTo(b.version));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('App Analyzer', style: TextStyle(fontSize: 16)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.sort, color: OneDarkColors.fgDim),
            onSelected: _sortApps,
            color: OneDarkColors.bgDark,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'name', child: Text('Sort by Name', style: TextStyle(color: OneDarkColors.fg))),
              PopupMenuItem(value: 'pkg', child: Text('Sort by Package', style: TextStyle(color: OneDarkColors.fg))),
              PopupMenuItem(value: 'version', child: Text('Sort by Install Date', style: TextStyle(color: OneDarkColors.fg))),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Device info card
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: OneDarkColors.bgDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: OneDarkColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.phone_android, size: 18, color: OneDarkColors.cyan),
                          const SizedBox(width: 8),
                          Text('Device Info', style: TextStyle(color: OneDarkColors.cyan, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(_deviceInfo, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12, height: 1.5)),
                    ],
                  ),
                ),
                // Search
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search ${_apps.length} apps…',
                      hintStyle: TextStyle(color: OneDarkColors.fgDim),
                      prefixIcon: Icon(Icons.search, size: 18, color: OneDarkColors.fgDim),
                      isDense: true,
                      border: OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.border)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // App count
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.apps, size: 14, color: OneDarkColors.fgDim),
                      const SizedBox(width: 6),
                      Text(
                        '${_filteredApps.length} apps',
                        style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // App list
                Expanded(
                  child: ListView.separated(
                    itemCount: _filteredApps.length,
                    separatorBuilder: (_, i) => const Divider(height: 1, indent: 56),
                    itemBuilder: (_, i) {
                      final app = _filteredApps[i];
                      return ListTile(
                        dense: true,
                        leading: app.icon != null
                            ? Image.memory(
                                app.icon!,
                                width: 32,
                                height: 32,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.apps,
                                  size: 20,
                                  color: OneDarkColors.cyan,
                                ),
                              )
                            : Icon(
                                Icons.apps,
                                size: 20,
                                color: OneDarkColors.cyan,
                              ),
                        title: Text(
                          app.name,
                          style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          app.version.isNotEmpty ? '${app.pkg}  v${app.version}' : app.pkg,
                          style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _AppInfo {
  final String name;
  final String pkg;
  final String version;
  final Uint8List? icon;
  const _AppInfo({
    required this.name,
    required this.pkg,
    this.version = '',
    this.icon,
  });
}
