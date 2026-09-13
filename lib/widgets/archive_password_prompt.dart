import 'package:flutter/material.dart';

/// Shared archive-password prompt. Replaces three copy-pasted dialogs
/// (archive browser, file browser, preview panel) with one dialog so the
/// service-layer [ArchivePasswordRequiredException] is always reachable
/// from every extraction entry point — the audit's "password support
/// UI-unreachable" finding.
///
/// Returns the entered password, or null when cancelled / empty.
Future<String?> promptForArchivePassword(
  BuildContext context, {
  required bool wasRejected,
}) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Password required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              wasRejected
                  ? 'That password was incorrect. Try again.'
                  : 'This archive is encrypted.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  } finally {
    controller.dispose();
  }
}
