import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart' as fa;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/donation_service.dart';
import '../widgets/file_browser.dart'
    show
        ViewMode,
        viewModeNotifier,
        savePersistedViewMode,
        showHiddenNotifier,
        rootModeNotifier,
        savePersistedRootMode;
import 'privacy_policy_screen.dart';
import 'auth_screen.dart';
import 'duplicates_screen.dart';
import 'document_scanner_screen.dart';
import 'cast_screen.dart';
import 'notepad_screen.dart';
import 'cloud_browser_screen.dart';
import 'storage_analysis_screen.dart';

/// Settings screen for configuring the app.
class SettingsScreen extends StatefulWidget {
  /// Callback fired when a settings button maps to an existing bottom-bar tab
  /// (Storage=3, Cloud=5, App Analyzer=2+tool, Terminal=6). Instead of pushing
  /// a full-screen route (which hides the bottom navigation bar), the caller
  /// switches the bottom tab via this callback.
  final void Function(int index)? onToolTap;

  const SettingsScreen({super.key, this.onToolTap});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _email;
  bool? _emailVerified;
  bool _isPremium = false;
  bool _loading = true;
  String _sortBy = 'Name';
  bool _bluetoothAutoConnect = false;
  int _lanPort = 8080;
  int _trashAutoEmpty = 0;
  bool _deleteConfirmation = true;
  bool _autoThemeEnabled = false;
  int _autoThemeStartHour = 19;
  int _autoThemeStartMinute = 0;
  int _autoThemeEndHour = 7;
  int _autoThemeEndMinute = 0;

  @override
  void initState() {
    super.initState();
    _refreshAccount();
    _loadTrashAutoEmpty();
    _loadDeleteConfirmation();
    _loadAutoThemeSettings();
  }

  Future<void> _loadDeleteConfirmation() async {
    final value = await FileUtils.loadDeleteConfirmation();
    if (mounted) setState(() => _deleteConfirmation = value);
  }

  Future<void> _loadTrashAutoEmpty() async {
    final policy = await FileUtils.loadTrashAutoEmpty();
    if (mounted) setState(() => _trashAutoEmpty = policy);
  }

  Future<void> _loadAutoThemeSettings() async {
    final (enabled, startH, startM, endH, endM) = await loadAutoThemeSettings();
    if (mounted) setState(() {
      _autoThemeEnabled = enabled;
      _autoThemeStartHour = startH;
      _autoThemeStartMinute = startM;
      _autoThemeEndHour = endH;
      _autoThemeEndMinute = endM;
    });
  }

  Future<void> _refreshAccount() async {
    final auth = AuthService();
    fa.User? user;
    try {
      user = auth.currentUser;
    } catch (_) {
      // Firebase not initialized in test environment -- proceed with null user
    }
    final entService = context.read<EntitlementService>();
    setState(() {
      _email = user?.email;
      _emailVerified = user?.emailVerified;
      _isPremium = entService.isPremium;
      _loading = false;
    });
  }

  Future<void> _handleSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Sign Out', style: TextStyle(color: OneDarkColors.fg)),
        content: Text(
          'Are you sure you want to sign out?',
          style: TextStyle(color: OneDarkColors.fgDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              foregroundColor: OneDarkColors.red,
              backgroundColor: OneDarkColors.red.withValues(alpha: 0.15),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await AuthService().signOut();
      setState(() {
        _email = null;
        _emailVerified = null;
        _isPremium = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Signed out'),
          backgroundColor: OneDarkColors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settings',
            style: TextStyle(
              color: OneDarkColors.cyan,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          // Account section
          _sectionTitle('Account'),
          if (_loading)
            ListTile(
              leading: Icon(Icons.person_outline, color: OneDarkColors.cyan),
              title: Text(
                'Loading…',
                style: TextStyle(color: OneDarkColors.fgDim),
              ),
            )
          else if (_email != null)
            _accountCard()
          else
            _settingTile(
              icon: Icons.person_outline,
              title: 'Sign In',
              subtitle: 'Use email/password to sync & unlock premium',
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final result = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                );
                if (result == true && mounted) {
                  _refreshAccount();
                }
              },
            ),

          const SizedBox(height: 16),

          // Premium
          _sectionTitle('Premium'),
          _settingTile(
            icon: _isPremium ? Icons.star : Icons.workspace_premium,
            title: _isPremium ? 'Premium Unlocked' : 'Get Premium',
            subtitle: _isPremium
                ? 'Enjoy ad-free, unlimited conversions'
                : 'Support development -- remove limits',
            trailing: _isPremium
                ? Icon(Icons.check_circle, color: OneDarkColors.amber)
                : const Icon(Icons.chevron_right),
            onTap: _isPremium
                ? null
                : () => DonationService.showDonateDialog(context),
          ),

          const SizedBox(height: 16),

          // Appearance
          _sectionTitle('Appearance'),
          _settingTile(
            icon: isDarkTheme ? Icons.dark_mode : Icons.light_mode,
            title: 'Theme',
            subtitle: isDarkTheme ? 'One Dark (Default)' : 'Cream Light',
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final newMode = isDarkTheme ? 'light' : 'dark';
              await saveThemeMode(newMode);
              // Set manual override so auto-theme doesn't immediately undo it.
              try {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('auto_theme_manual_override', true);
              } catch (_) {}
              themeNotifier.value++;
            },
          ),
          ValueListenableBuilder<ViewMode>(
            valueListenable: viewModeNotifier,
            builder: (context, viewMode, _) {
              return _settingTile(
                icon: Icons.grid_view,
                title: 'Default View',
                subtitle: viewMode == ViewMode.grid ? 'Grid' : 'Details',
                trailing: DropdownButton<ViewMode>(
                  value: viewMode,
                  dropdownColor: OneDarkColors.bgDark,
                  items: const [
                    DropdownMenuItem(
                      value: ViewMode.details,
                      child: Text('Details'),
                    ),
                    DropdownMenuItem(value: ViewMode.grid, child: Text('Grid')),
                  ],
                  onChanged: (v) {
                    if (v != null) savePersistedViewMode(v);
                  },
                ),
              );
            },
          ),

          // Night Mode Schedule
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.schedule,
            title: 'Night Mode Schedule',
            subtitle: _autoThemeEnabled
                ? 'Dark ${_autoThemeStartHour.toString().padLeft(2, '0')}:${_autoThemeStartMinute.toString().padLeft(2, '0')} \u2013 ${_autoThemeEndHour.toString().padLeft(2, '0')}:${_autoThemeEndMinute.toString().padLeft(2, '0')}'
                : 'Disabled',
            trailing: Switch(
              value: _autoThemeEnabled,
              onChanged: (v) async {
                setState(() => _autoThemeEnabled = v);
                await saveAutoThemeSettings(
                  enabled: v,
                  startHour: _autoThemeStartHour,
                  startMinute: _autoThemeStartMinute,
                  endHour: _autoThemeEndHour,
                  endMinute: _autoThemeEndMinute,
                );
                if (v) await checkAutoTheme();
              },
            ),
          ),
          if (_autoThemeEnabled) ...[
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              dense: true,
              title: Text('Dark starts at', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: _autoThemeStartHour, minute: _autoThemeStartMinute),
                  );
                  if (picked != null) {
                    setState(() {
                      _autoThemeStartHour = picked.hour;
                      _autoThemeStartMinute = picked.minute;
                    });
                    await saveAutoThemeSettings(
                      enabled: _autoThemeEnabled,
                      startHour: picked.hour,
                      startMinute: picked.minute,
                      endHour: _autoThemeEndHour,
                      endMinute: _autoThemeEndMinute,
                    );
                    await checkAutoTheme();
                  }
                },
                child: Text(
                  '${_autoThemeStartHour.toString().padLeft(2, '0')}:${_autoThemeStartMinute.toString().padLeft(2, '0')}',
                  style: TextStyle(color: OneDarkColors.cyan),
                ),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              dense: true,
              title: Text('Light starts at', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
              trailing: TextButton(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: _autoThemeEndHour, minute: _autoThemeEndMinute),
                  );
                  if (picked != null) {
                    setState(() {
                      _autoThemeEndHour = picked.hour;
                      _autoThemeEndMinute = picked.minute;
                    });
                    await saveAutoThemeSettings(
                      enabled: _autoThemeEnabled,
                      startHour: _autoThemeStartHour,
                      startMinute: _autoThemeStartMinute,
                      endHour: picked.hour,
                      endMinute: picked.minute,
                    );
                    await checkAutoTheme();
                  }
                },
                child: Text(
                  '${_autoThemeEndHour.toString().padLeft(2, '0')}:${_autoThemeEndMinute.toString().padLeft(2, '0')}',
                  style: TextStyle(color: OneDarkColors.cyan),
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // File Management
          _sectionTitle('File Management'),
          ValueListenableBuilder<bool>(
            valueListenable: showHiddenNotifier,
            builder: (context, showHidden, _) {
              return _settingTile(
                icon: Icons.visibility,
                title: 'Show Hidden Files',
                subtitle: 'Toggle to show dotfiles',
                trailing: Switch(
                  value: showHidden,
                  onChanged: (v) => showHiddenNotifier.value = v,
                ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: rootModeNotifier,
            builder: (context, rootMode, _) {
              return FutureBuilder<bool>(
                future: FileUtils.isRooted,
                builder: (context, snapshot) {
                  final isRooted = snapshot.data ?? false;
                  return _settingTile(
                    icon: Icons.admin_panel_settings,
                    title: 'Root Mode',
                    subtitle: isRooted
                        ? 'System dirs browsable -- requires rooted device for /system, /data'
                        : 'Enable to browse /proc, /sys, /dev and other system dirs (requires root)',
                    trailing: isRooted
                        ? Switch(
                            value: rootMode,
                            onChanged: (v) => savePersistedRootMode(v),
                          )
                        : IconButton(
                            icon: const Icon(Icons.lock_outline, size: 18),
                            tooltip: 'Device is not rooted',
                            onPressed: () {},
                          ),
                  );
                },
              );
            },
          ),
          _settingTile(
            icon: Icons.sort,
            title: 'Sort By',
            subtitle: _sortBy,
            trailing: const Icon(Icons.chevron_right),
            onTap: _showSortByPicker,
          ),
          _settingTile(
            icon: Icons.delete_outline,
            title: 'Delete Confirmation',
            subtitle: 'Ask before deleting files',
            trailing: Switch(
              value: _deleteConfirmation,
              activeColor: OneDarkColors.cyan,
              onChanged: (v) async {
                await FileUtils.saveDeleteConfirmation(v);
                if (mounted) setState(() => _deleteConfirmation = v);
              },
            ),
          ),
          _trashAutoEmptyTile(),

          const SizedBox(height: 16),

          // Sharing
          _sectionTitle('Sharing'),
          _settingTile(
            icon: Icons.bluetooth,
            title: 'Bluetooth Auto-Connect',
            subtitle: 'Connect to paired devices',
            trailing: Switch(
              value: _bluetoothAutoConnect,
              onChanged: (v) => setState(() => _bluetoothAutoConnect = v),
            ),
          ),
          _settingTile(
            icon: Icons.wifi,
            title: 'LAN Server Port',
            subtitle: '$_lanPort',
            trailing: const Icon(Icons.chevron_right),
            onTap: _showPortPicker,
          ),

          const SizedBox(height: 16),

                  // Tools
          _sectionTitle('Tools'),
          _settingTile(
            icon: Icons.bar_chart,
            title: 'Storage Analysis',
            subtitle: 'See disk usage by folder',
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (widget.onToolTap != null) {
                widget.onToolTap!(3);
              } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          StorageAnalysisScreen(rootPath: AppPaths.home),
                    ),
                  );
              }
            },
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.all_inclusive,
            title: 'Find Duplicates',
            subtitle: 'Scan for duplicate files by hash',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DuplicatesScreen())),
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.cloud_sync,
            title: 'Cloud Storage',
            subtitle: 'Connect Google Drive or Dropbox',
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (widget.onToolTap != null) {
                widget.onToolTap!(5);
              } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CloudBrowserScreen()),
                  );
              }
            },
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.cloud,
            title: 'rclone Cloud Mounts',
            subtitle: 'Browse cloud storage via rclone (requires Termux)',
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRcloneBrowser,
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.document_scanner,
            title: 'Document Scanner',
            subtitle: 'Scan pages into a PDF',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DocumentScannerScreen()),
            ),
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.cast,
            title: 'Cast',
            subtitle: 'Discover Chromecast / DLNA devices',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const CastScreen())),
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.sticky_note_2,
            title: 'Notepad',
            subtitle: 'Create and edit text documents',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const NotepadScreen())),
          ),

          const SizedBox(height: 16),

          // About
          _sectionTitle('About'),
          _settingTile(
            icon: Icons.info_outline,
            title: 'Version',
            subtitle: '1.0.0',
          ),
          _settingTile(
            icon: Icons.privacy_tip,
            title: 'Privacy Policy',
            subtitle: 'How we handle your data',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          _settingTile(
            icon: Icons.code,
            title: 'Source Code',
            subtitle: 'Open source (MIT)',
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final uri = Uri.parse(
                'https://github.com/BayazidHabibSiddikee/SwordFM_Android',
              );
              try {
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } else {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text("Couldn't open link -- please check your connection"),
                      backgroundColor: OneDarkColors.bgDark,
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Could not open link: $e'),
                    backgroundColor: OneDarkColors.red,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _accountCard() {
    return Card(
      color: OneDarkColors.bgDark,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: OneDarkColors.dim),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: _isPremium
                      ? OneDarkColors.amber
                      : OneDarkColors.cyan,
                  child: Text(
                    (_email != null && _email!.isNotEmpty)
                        ? _email![0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: OneDarkColors.bg,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _email!,
                            style: TextStyle(
                              color: OneDarkColors.fg,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (_emailVerified == true)
                            Icon(
                              Icons.verified,
                              size: 16,
                              color: OneDarkColors.green,
                            )
                          else if (_emailVerified == false)
                            Icon(
                              Icons.error_outline,
                              size: 16,
                              color: OneDarkColors.amber,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (_isPremium) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: OneDarkColors.amber.withValues(
                                  alpha: 0.2,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Premium',
                                style: TextStyle(
                                  color: OneDarkColors.amber,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            _emailVerified == true
                                ? 'Email verified'
                                : _emailVerified == false
                                ? 'Verify email'
                                : '',
                            style: TextStyle(
                              color: OneDarkColors.fgDim,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                if (!_isPremium)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          DonationService.showDonateDialog(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.amber,
                        side: BorderSide(color: OneDarkColors.amber),
                      ),
                      child: const Text('Support / Premium'),
                    ),
                  ),
                if (_isPremium) const Spacer(),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _handleSignOut,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: OneDarkColors.red,
                      side: BorderSide(color: OneDarkColors.red),
                    ),
                    child: const Text('Sign Out'),
                  ),
                ),
              ],
            ),
            if (_emailVerified == false) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  await AuthService().sendEmailVerification();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Verification email sent'),
                        backgroundColor: OneDarkColors.green,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.email_outlined, size: 16),
                label: const Text(
                  'Resend Verification Email',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: OneDarkColors.fgDim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _settingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: OneDarkColors.cyan),
      title: Text(title, style: TextStyle(color: OneDarkColors.fg)),
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(color: OneDarkColors.fgDim))
          : null,
      trailing: trailing,
      onTap: onTap,
    );
  }

  Future<void> _showSortByPicker() async {
    final options = ['Name', 'Size', 'Date', 'Type'];
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Sort By', style: TextStyle(color: OneDarkColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options
              .map(
                (opt) => RadioListTile<String>(
                  value: opt,
                  groupValue: _sortBy,
                  title: Text(opt, style: TextStyle(color: OneDarkColors.fg)),
                  activeColor: OneDarkColors.cyan,
                  dense: true,
                  onChanged: (v) => Navigator.pop(context, v),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (result != null && mounted) setState(() => _sortBy = result);
  }

  Future<void> _showPortPicker() async {
    final controller = TextEditingController(text: '$_lanPort');
    final result = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text(
          'LAN Server Port',
          style: TextStyle(color: OneDarkColors.fg),
        ),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: TextStyle(color: OneDarkColors.fg),
          decoration: const InputDecoration(
            labelText: 'Port',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text);
              if (port != null && port > 0 && port < 65536)
                Navigator.pop(context, port);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && mounted) setState(() => _lanPort = result);
  }

  /// Opens rclone browser via Termux. Prefers URL scheme; falls back to
  /// instructions if the scheme is unavailable.
  Future<void> _openRcloneBrowser() async {
    // Try opening rclone browser in Termux via URI scheme
    final uri = Uri.parse(
      'termux://com.termux.app?action=run_command&command=rclone%20browser',
    );
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        // Fallback: show instructions
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: OneDarkColors.bg,
            title: Text(
              'rclone Browser',
              style: TextStyle(color: OneDarkColors.fg),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Open Termux and run:',
                  style: TextStyle(color: OneDarkColors.fg),
                ),
                SizedBox(height: 8),
                Text(
                  'rclone browser',
                  style: TextStyle(
                    color: OneDarkColors.cyan,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Or browse a specific remote:',
                  style: TextStyle(color: OneDarkColors.fgDim),
                ),
                SizedBox(height: 4),
                Text(
                  'rclone browser remote:path',
                  style: TextStyle(
                    color: OneDarkColors.cyan,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Prerequisites: Termux + rclone installed.',
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open rclone: $e'),
          backgroundColor: OneDarkColors.red,
        ),
      );
    }
  }

  Widget _trashAutoEmptyTile() {
    final labels = {0: 'Never', 1: 'After 7 days', 2: 'After 30 days'};
    return _settingTile(
      icon: Icons.auto_delete,
      title: 'Auto-Empty Trash',
      subtitle: labels[_trashAutoEmpty] ?? 'Never',
      trailing: DropdownButton<int>(
        value: _trashAutoEmpty,
        dropdownColor: OneDarkColors.bgDark,
        items: const [
          DropdownMenuItem(value: 0, child: Text('Never')),
          DropdownMenuItem(value: 1, child: Text('7 days')),
          DropdownMenuItem(value: 2, child: Text('30 days')),
        ],
        onChanged: (v) async {
          if (v == null) return;
          await FileUtils.saveTrashAutoEmpty(v);
          setState(() => _trashAutoEmpty = v);
        },
      ),
    );
  }
}
