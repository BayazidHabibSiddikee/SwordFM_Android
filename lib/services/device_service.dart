/// Service that returns the Android storage volumes visible to the app, plus
/// any rclone remote mount directories.
///
/// - Local volumes are queried via a native Kotlin method that calls
///   [Environment.getExternalStorageDirectories()].
/// - Rclone mounts are listed from the user's config file (~/.config/rclone/rclone.conf).
import 'package:flutter/services.dart';

class StorageVolume {
  final String path;
  final String label;
  final bool isRemovable;
  const StorageVolume(this.path, this.label, this.isRemovable);

  factory StorageVolume.fromJson(Map<dynamic, dynamic> m) {
    return StorageVolume(
      m['path'] as String? ?? '',
      m['label'] as String? ?? '',
      (m['removable'] as bool?) ?? false,
    );
  }
}

/// Returns the storage volumes available on Android.
/// On non-Android platforms returns an empty list.
Future<List<StorageVolume>> getStorageVolumes() async {
  const _channel = MethodChannel('com.swordfm/devices');
  try {
    final raw = await _channel.invokeMethod<List<dynamic>>('getStorageVolumes');
    if (raw == null) return [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => StorageVolume.fromJson(m))
        .toList();
  } on PlatformException {
    return [];
  } catch (_) {
    return []; // e.g. MissingPluginException on desktop/tests
  }
}

/// Whether the app has "All files access" (MANAGE_EXTERNAL_STORAGE),
/// which unlocks read/write over the phone's full storage (not just the
/// ~app-scoped sandbox). Returns false when not granted.
Future<bool> allFilesAccessGranted() async {
  const _channel = MethodChannel('com.swordfm/devices');
  try {
    return await _channel.invokeMethod<bool>('allFilesAccessGranted') ?? false;
  } catch (_) {
    return false;
  }
}

/// Opens the system "All files access" settings screen so the user can
/// grant broad storage access. Returns true when the screen was launched.
Future<bool> requestAllFilesAccess() async {
  const _channel = MethodChannel('com.swordfm/devices');
  try {
    return await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
  } catch (_) {
    return false;
  }
}

/// Opens the system "App info" settings page for [packageName] (used by the
/// app analyzer's "App settings" action). Reliable on Android 12+ — a plain
/// `package:` URI via url_launcher does not resolve to an activity.
Future<bool> openAppInfoSettings(String packageName) async {
  const _channel = MethodChannel('com.swordfm/devices');
  try {
    return await _channel.invokeMethod<bool>(
          'openAppSettings',
          {'package': packageName},
        ) ??
        false;
  } catch (_) {
    return false;
  }
}
