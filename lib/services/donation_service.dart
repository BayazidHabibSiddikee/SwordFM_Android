import 'package:flutter/material.dart';
import '../theme/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Handles donation flows for SwordFM.
/// Supports bKash (BD) and BNB crypto donations.
class DonationService {
  /// The app's bKash number for receiving donations.
  static const String bKashNumber = '+8801723977791';

  /// The BNB (BEP-20) wallet address for receiving donations.
  static const String bnbAddress = '0x1Aeb51EeA471f6B7a826DE01e2c1381b8e618894';

  /// Opens the bKash app directly (if installed) to send money.
  static Future<bool> openBkashApp() async {
    final uri = Uri.parse('bkash://sendmoney?recipient=$bKashNumber');
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri);
    }
    return false;
  }

  /// Copies the bKash number to clipboard.
  static Future<void> copyBkashNumber(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('bKash number copied'),
        backgroundColor: OneDarkColors.green,
      ),
    );
  }

  /// Copies the BNB address to clipboard.
  static Future<void> copyBnbAddress(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('BNB address copied'),
        backgroundColor: OneDarkColors.green,
      ),
    );
  }

  /// Shows the full donation dialog.
  static void showDonateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _DonationDialog(),
    );
  }
}

class _DonationDialog extends StatefulWidget {
  const _DonationDialog();

  @override
  State<_DonationDialog> createState() => _DonationDialogState();
}

class _DonationDialogState extends State<_DonationDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: const Text(
        'Support SwordFM',
        style: TextStyle(color: OneDarkColors.cyan),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your donations help keep SwordFM alive and growing. Thank you!',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _donationCard(
              icon: Icons.account_balance_wallet,
              title: 'bKash',
              subtitle: 'Bangladesh mobile banking',
              value: DonationService.bKashNumber,
              action: () => DonationService.copyBkashNumber(context),
            ),
            const SizedBox(height: 12),
            _donationCard(
              icon: Icons.token,
              title: 'BNB (BEP-20)',
              subtitle: 'Binance Smart Chain only',
              value: DonationService.bnbAddress,
              action: () => DonationService.copyBnbAddress(context),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: OneDarkColors.dim,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'After donating, email your UID/email to support@swordfm.app with your transaction ID. We\'ll activate your premium within 24 hours.',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);
            await DonationService.openBkashApp();
          },
          child: const Text('Open bKash'),
        ),
      ],
    );
  }

  Widget _donationCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required VoidCallback action,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OneDarkColors.bgDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OneDarkColors.dim),
      ),
      child: Row(
        children: [
          Icon(icon, color: OneDarkColors.amber, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: OneDarkColors.fg, fontWeight: FontWeight.w600)),
                Text(subtitle, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                SelectableText(
                  value,
                  style: const TextStyle(color: OneDarkColors.cyan, fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            color: OneDarkColors.cyan,
            onPressed: action,
            tooltip: 'Copy',
          ),
        ],
      ),
    );
  }
}
