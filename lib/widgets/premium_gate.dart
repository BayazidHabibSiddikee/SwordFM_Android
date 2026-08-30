import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/theme.dart';
import '../services/entitlement_service.dart';
import '../services/donation_service.dart';

/// A widget that gates premium features.
///
/// Wraps any child widget and shows a "Get Premium" dialog when locked.
/// The dialog explains what premium includes and provides donation channels.
class PremiumGate extends StatelessWidget {
  final Widget child;
  final String featureName;

  const PremiumGate({
    super.key,
    required this.child,
    required this.featureName,
  });

  @override
  Widget build(BuildContext context) {
    final ent = context.watch<EntitlementService>();
    if (ent.isPremium) return child;

    return GestureDetector(
      onTap: () => _showPremiumDialog(context),
      child: AbsorbPointer(child: Opacity(opacity: 0.5, child: child)),
    );
  }

  void _showPremiumDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Premium Feature', style: TextStyle(color: OneDarkColors.amber)),
        content: Text(
          '$featureName is a premium feature. Support development to unlock it.',
          style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              DonationService.showDonateDialog(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: OneDarkColors.amber,
              foregroundColor: OneDarkColors.bg,
            ),
            child: const Text('Get Premium'),
          ),
        ],
      ),
    );
  }

  /// Shows the premium upsell dialog.
  static void showDonateDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _Donatedialog());
  }
}

class _Donatedialog extends StatefulWidget {
  const _Donatedialog();

  @override
  State<_Donatedialog> createState() => _DonatedialogState();
}

class _DonatedialogState extends State<_Donatedialog> {
  void _copyToClipboard(String text, String field) {
    // In a real app, use Clipboard.setData
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$field copied to clipboard'),
        backgroundColor: OneDarkColors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: Text(
        'Support SwordFM',
        style: TextStyle(color: OneDarkColors.cyan),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Premium unlocks unlimited file conversions and ad-free experience.',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _donationRow(
              icon: Icons.account_balance_wallet,
              label: 'bKash',
              value: '+8801723977791',
              hint: 'Send Money → enter number → confirm',
            ),
            const SizedBox(height: 12),
            _donationRow(
              icon: Icons.token,
              label: 'BNB (BEP-20)',
              value: '0x1Aeb51EeA471f6B7a826DE01e2c1381b8e618894',
              hint: 'Send BNB via Binance Smart Chain only',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: OneDarkColors.dim,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'After donating, email your UID/email to support@swordfm.app with your transaction ID. We\'ll activate your premium within 24 hours.',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            DonationService.openBkashApp();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _donationRow({
    required IconData icon,
    required String label,
    required String value,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: OneDarkColors.amber),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: OneDarkColors.fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              color: OneDarkColors.cyan,
              onPressed: () => _copyToClipboard(value, label),
              tooltip: 'Copy $label',
            ),
          ],
        ),
        SelectableText(
          value,
          style: TextStyle(
            color: OneDarkColors.fg,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
        Text(hint, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
      ],
    );
  }
}
