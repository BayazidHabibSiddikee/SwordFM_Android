import 'package:flutter/material.dart';
import '../theme/theme.dart';
import 'privacy_policy_screen.dart';
import 'auth_screen.dart';
import 'duplicates_screen.dart';

/// Settings screen for configuring the app.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings', style: TextStyle(color: OneDarkColors.cyan, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),

          // Account
          _settingTile(
            icon: Icons.person_outline,
            title: 'Account',
            subtitle: 'Sign in with email/password',
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const AuthScreen()),
              );
              if (result == true && mounted) {
                setState(() {}); // refresh
              }
            },
          ),

          const SizedBox(height: 16),

          // Appearance
          _sectionTitle('Appearance'),
          _settingTile(
            icon: Icons.dark_mode,
            title: 'Theme',
            subtitle: 'One Dark (Default)',
            trailing: const Icon(Icons.chevron_right),
          ),
          _settingTile(
            icon: Icons.grid_view,
            title: 'Default View',
            subtitle: 'Details',
            trailing: DropdownButton<String>(
              value: 'Details',
              items: ['Details', 'Grid'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (_) {},
            ),
          ),

          const SizedBox(height: 16),

          // File Management
          _sectionTitle('File Management'),
          _settingTile(
            icon: Icons.visibility,
            title: 'Show Hidden Files',
            subtitle: 'Toggle to show dotfiles',
            trailing: Switch(value: false, onChanged: (_) {}),
          ),
          _settingTile(
            icon: Icons.sort,
            title: 'Sort By',
            subtitle: 'Name',
            trailing: const Icon(Icons.chevron_right),
          ),
          _settingTile(
            icon: Icons.delete_outline,
            title: 'Delete Confirmation',
            subtitle: 'Ask before deleting',
            trailing: Switch(value: true, onChanged: (_) {}),
          ),

          const SizedBox(height: 16),

          // Sharing
          _sectionTitle('Sharing'),
          _settingTile(
            icon: Icons.bluetooth,
            title: 'Bluetooth Auto-Connect',
            subtitle: 'Connect to paired devices',
            trailing: Switch(value: false, onChanged: (_) {}),
          ),
          _settingTile(
            icon: Icons.wifi,
            title: 'LAN Server Port',
            subtitle: '8080',
            trailing: const Icon(Icons.chevron_right),
          ),

          const SizedBox(height: 16),

          // Tools
          _sectionTitle('Tools'),
          _settingTile(
            icon: Icons.all_inclusive,
            title: 'Find Duplicates',
            subtitle: 'Scan for duplicate files by hash',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DuplicatesScreen()),
            ),
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
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12, fontWeight: FontWeight.w600)),
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
      title: Text(title, style: const TextStyle(color: OneDarkColors.fg)),
      subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(color: OneDarkColors.fgDim)) : null,
      trailing: trailing,
      onTap: onTap ?? (trailing is Switch ? null : () {}),
    );
  }
}
