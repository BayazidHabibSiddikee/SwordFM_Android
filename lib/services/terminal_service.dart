import 'dart:io';
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

  /// True if the Termux app is installed. Asks the native side first (the
  /// authoritative check); falls back to the well-known python binary path
  /// for unit tests / non-Android hosts.
  static Future<bool> isInstalled() async {
    if (!Platform.isAndroid) {
      return File('/data/data/com.termux/files/usr/bin/python3').existsSync();
    }
    try {
      final v = await _channel.invokeMethod<bool>('isTermuxInstalled');
      if (v != null) return v;
    } on PlatformException {
      // fall through to filesystem probe
    }
    return File('/data/data/com.termux/files/usr/bin/bash').existsSync();
  }

  /// Returns the install instructions that match the situation the user is
  /// in. Empty string when Termux is already installed.
  static String installInstructions() {
    return 'Termux is not installed on this device.\n\n'
        'SwordFM uses Termux to provide a real bash shell with a package '
        'manager (apt / pkg). Install Termux from the Play Store or '
        'F-Droid, then return here.\n\n'
        'Tip: after installing Termux, open it once and run:\n'
        '  pkg update && pkg upgrade\n'
        'so the toolchain is ready.';
  }

  /// Returns the URL the install button should deep-link to. F-Droid is
  /// preferred because it is the official Termux distribution and the
  /// Play Store version lags behind; we still fall back to the Play Store
  /// because it is the path the user is most likely to find.
  static Uri installUri() {
    return Uri.parse(
        'https://f-droid.org/packages/com.termux/');
  }

  /// Launches Termux's install page in the user's default browser.
  /// Returns true if the intent was dispatched.
  static Future<bool> openInstallPage() async {
    final uri = installUri();
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    // Fall back to Play Store if F-Droid isn't reachable for some reason.
    final play = Uri.parse(
        'https://play.google.com/store/apps/details?id=com.termux');
    if (await canLaunchUrl(play)) {
      await launchUrl(play, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

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
