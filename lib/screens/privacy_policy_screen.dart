import 'package:flutter/material.dart';
import '../theme/theme.dart';

/// Privacy Policy screen — required for Play Store submission.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Privacy Policy', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SwordFM Android', style: TextStyle(color: OneDarkColors.cyan, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Last updated: August 2026', style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12)),
            const SizedBox(height: 24),
            _section('1. Information We Collect', [
              'Local file access: Files you choose to browse or share are accessed locally on your device. We do not upload or transmit your personal files to any server.',
              'Network connections: When you use LAN sharing or remote servers (WebDAV/SFTP), connection details such as server hostname and port are stored locally on your device for future use.',
              'Bluetooth pairing: Paired Bluetooth device names and addresses are stored locally and never transmitted to third parties.',
            ]),
            const SizedBox(height: 16),
            _section('2. How We Use Your Information', [
              'To provide file browsing, searching, and management features on your device.',
              'To enable local network file sharing via our HTTP server.',
              'To facilitate Bluetooth file transfers to paired devices.',
              'To connect to remote servers you configure (WebDAV, SFTP) for file operations.',
            ]),
            const SizedBox(height: 16),
            _section('3. Data Sharing and Disclosure', [
              'We do NOT sell, rent, or trade your personal data to any third party.',
              'Files you share via LAN or Bluetooth are transmitted directly between devices on your local network or via Bluetooth — we do not intercept or store them.',
              'Remote server connections (WebDAV/SFTP) communicate directly with the server you specify. We do not proxy or log this traffic.',
              'We may collect anonymous crash reports via Sentry (opt-in only) to help improve app stability.',
            ]),
            const SizedBox(height: 16),
            _section('4. Data Security', [
              'Credentials for remote servers (passwords) are encrypted using AES before being stored on your device.',
              'Bluetooth permissions are requested only when you initiate a Bluetooth sharing action.',
              'All network communication uses standard encryption (TLS for WebDAV, SSH for SFTP).',
            ]),
            const SizedBox(height: 16),
            _section('5. Permissions Used', [
              'Storage: Access files on your device for browsing and transfer.',
              'Bluetooth: Scan for and connect to paired devices for file transfer.',
              'Network: Connect to local WiFi networks for LAN sharing.',
              'Camera (optional): Scan QR codes to quickly connect to LAN shared folders.',
            ]),
            const SizedBox(height: 16),
            _section('6. Your Rights', [
              'You can revoke any permission at any time via your device settings.',
              'You can delete all stored connection profiles from Settings.',
              'You can request deletion of any data we collect by uninstalling the app.',
            ]),
            const SizedBox(height: 16),
            _section('7. Contact', [
              'Questions about this privacy policy? Contact us at: privacy@swordfm.app',
            ]),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'This privacy policy is subject to change. Please review it periodically.',
                style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<String> bullets) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: OneDarkColors.cyan, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...bullets.map((b) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ', style: TextStyle(color: OneDarkColors.fgDim)),
              Expanded(child: Text(b, style: const TextStyle(color: OneDarkColors.fg, fontSize: 13))),
            ],
          ),
        )),
      ],
    );
  }
}
