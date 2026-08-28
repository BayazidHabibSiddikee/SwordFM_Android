import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a terminal emulator (Termux) at a given directory — the Android
/// equivalent of the Linux build's F4 "Open Terminal Here".
///
/// Launch chain:
///   1. Native `com.termux.RUN_COMMAND` intent with RUN_COMMAND_WORKDIR
///      (see MainActivity.kt `com.swordfm/terminal` channel) — preferred,
///      sets the working directory directly without shell quoting.
///   2. `termux://` URL scheme (command = `cd '<dir>' && exec bash`).
///   3. Returns false — caller should show install instructions.
///
/// Termux "Allow external apps" must be enabled; the Android manifest already
/// declares `<queries>` for com.termux so the app is visible on Android 11+.
class TerminalService {
  static const MethodChannel _channel = MethodChannel('com.swordfm/terminal');

  /// Returns true if a terminal session was launched.
  static Future<bool> openTerminalAt(String path) async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('openTerminalAt', {'path': path}) ??
          false;
      if (ok) return true;
    } on PlatformException {
      // Termux missing or disallowed — try the URL scheme below.
    } on MissingPluginException {
      // Non-Android embedder.
    }

    final quoted = path.replaceAll("'", "'\\''");
    final cmd = "cd '$quoted' && exec bash";
    final uri = Uri.parse(
      'termux://com.termux.app?action=run_command&command=${Uri.encodeComponent(cmd)}',
    );
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    return false;
  }
}
