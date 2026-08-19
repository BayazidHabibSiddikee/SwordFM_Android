import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart' as fa;
import '../theme/theme.dart';
import '../services/auth_service.dart';
import '../services/entitlement_service.dart';
import '../services/donation_service.dart';
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
  String? _email;
  bool? _emailVerified;
  bool _isPremium = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refreshAccount();
  }

  Future<void> _refreshAccount() async {
    final auth = AuthService();
    fa.User? user;
    try {
      user = auth.currentUser;
    } catch (_) {
      // Firebase not initialized in test environment — proceed with null user
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
        title: const Text('Sign Out', style: TextStyle(color: OneDarkColors.fg)),
        content: const Text('Are you sure you want to sign out?',
            style: TextStyle(color: OneDarkColors.fgDim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              foregroundColor: OneDarkColors.red,
              backgroundColor: OneDarkColors.red.withOpacity(0.15),
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
        const SnackBar(content: Text('Signed out'), backgroundColor: OneDarkColors.green),
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
          const Text('Settings', style: TextStyle(color: OneDarkColors.cyan, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),

          // Account section
          _sectionTitle('Account'),
          if (_loading)
            const ListTile(
              leading: Icon(Icons.person_outline, color: OneDarkColors.cyan),
              title: Text('Loading…', style: TextStyle(color: OneDarkColors.fgDim)),
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
                : 'Support development — remove limits',
            trailing: _isPremium
                ? const Icon(Icons.check_circle, color: OneDarkColors.amber)
                : const Icon(Icons.chevron_right),
            onTap: _isPremium ? null : () => DonationService.showDonateDialog(context),
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

  Widget _accountCard() {
    return Card(
      color: OneDarkColors.bgDark,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: OneDarkColors.dim)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: _isPremium ? OneDarkColors.amber : OneDarkColors.cyan,
                  child: Text(
                    (_email ?? '?')[0].toUpperCase(),
                    style: const TextStyle(color: OneDarkColors.bg, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(_email!, style: const TextStyle(color: OneDarkColors.fg, fontSize: 15, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          if (_emailVerified == true)
                            const Icon(Icons.verified, size: 16, color: OneDarkColors.green)
                          else if (_emailVerified == false)
                            const Icon(Icons.error_outline, size: 16, color: OneDarkColors.amber),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (_isPremium) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: OneDarkColors.amber.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                              child: const Text('Premium', style: TextStyle(color: OneDarkColors.amber, fontSize: 11, fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(_emailVerified == true ? 'Email verified' : _emailVerified == false ? 'Verify email' : '',
                              style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
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
                      onPressed: () => DonationService.showDonateDialog(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.amber,
                        side: const BorderSide(color: OneDarkColors.amber),
                      ),
                      child: const Text('Support / Premium'),
                    ),
                  ),
                if (_isPremium)
                  const Spacer(),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _handleSignOut,
                    style: OutlinedButton.styleFrom(foregroundColor: OneDarkColors.red, side: const BorderSide(color: OneDarkColors.red)),
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
                      const SnackBar(content: Text('Verification email sent'), backgroundColor: OneDarkColors.green),
                    );
                  }
                },
                icon: const Icon(Icons.email_outlined, size: 16),
                label: const Text('Resend Verification Email', style: TextStyle(fontSize: 12)),
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
