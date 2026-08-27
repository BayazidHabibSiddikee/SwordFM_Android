import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

/// Opens a file through Android's native "Open with…" app chooser
/// (Intent.createChooser + FileProvider, see MainActivity.kt).
///
/// Falls back to the default handler (`OpenFile.open`, ACTION_VIEW) when the
/// chooser channel is unavailable or the launch fails — the pre-existing
/// behavior, so nothing regresses on platforms without the native side.
class OpenWithService {
  static const MethodChannel _channel = MethodChannel('com.swordfm/openwith');

  /// Opens [path] with the system's default handler for its type.
  static Future<void> openDefault(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      throw Exception('Cannot open: ${result.message}');
    }
  }

  /// Launches the chooser for [path]. Throws [Exception] if nothing could be
  /// opened (including the fallback).
  static Future<void> openWithChooser(String path) async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('openWithChooser', {
            'path': path,
          }) ??
          false;
      if (ok) return;
    } on PlatformException {
      // fall through to the default opener below
    } on MissingPluginException {
      // non-Android embedder — fall through
    }

    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      throw Exception('Cannot open: ${result.message}');
    }
  }
}
