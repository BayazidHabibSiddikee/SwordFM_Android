import 'package:flutter/services.dart';

/// Shares files through Android's native share sheet
/// (`Intent.ACTION_SEND_MULTIPLE` + FileProvider, see MainActivity.kt).
///
/// Returns false when sharing is unavailable (non-Android embedder, no channel,
/// or no shareable files) so the caller can surface a fallback message.
class ShareService {
  static const MethodChannel _channel = MethodChannel(
    'com.swordfm/share',
  );

  /// Shares [paths] via the system share sheet.
  ///
  /// Returns true when a chooser was launched. Only file paths are sent —
  /// directories are ignored (the Android share sheet cannot share a folder).
  static Future<bool> share(List<String> paths) async {
    final files = paths.where((p) => !p.endsWith('/')).toList();
    if (files.isEmpty) return false;
    try {
      return await _channel
              .invokeMethod<bool>('shareFiles', {'paths': files}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}