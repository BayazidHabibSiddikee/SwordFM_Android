import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles all storage-related permissions for Android.
class StoragePermissions {
  /// Requests all required media/storage permissions.
  /// Returns true if at least one is granted.
  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;

    final mediaStatus = await Permission.mediaLibrary.request();
    final storageStatus = await Permission.storage.request();
    final photosStatus = await Permission.photos.request();

    debugPrint(
      'Storage permissions: media=$mediaStatus, storage=$storageStatus, photos=$photosStatus',
    );

    return mediaStatus.isGranted ||
        storageStatus.isGranted ||
        photosStatus.isGranted;
  }

  /// Opens the app settings so user can grant MANAGE_EXTERNAL_STORAGE manually.
  static Future<void> openStorageSettings() async {
    if (await Permission.storage.isPermanentlyDenied) {
      await openAppSettings();
    } else {
      await Permission.storage.request();
    }
  }

  /// Returns whether storage permission is currently granted.
  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    final media = await Permission.mediaLibrary.status;
    final storage = await Permission.storage.status;
    return media.isGranted || storage.isGranted;
  }
}
