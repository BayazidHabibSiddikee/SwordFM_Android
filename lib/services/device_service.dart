/// Service that returns the Android storage volumes visible to the app, plus
/// any rclone remote mount directories.
///
/// - Local volumes are queried via a native Kotlin method that calls
///   [Environment.getExternalStorageDirectories()].
/// - Rclone mounts are listed from the user's config file (~/.config/rclone/rclone.conf).
import 'dart:async';
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
    return raw.whereType<Map<dynamic, dynamic>>().map((m) => StorageVolume.fromJson(m)).toList();
  } on PlatformException {
    return [];
  }
}
