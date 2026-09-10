import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles all storage-related permissions for Android.
class StoragePermissions {
  /// Requests all required media/storage permissions.
  ///
  /// On Android 11+ (API 30+) full file access requires the special
  /// MANAGE_EXTERNAL_STORAGE permission which must be granted through the
  /// system "All files access" settings page — it cannot be requested with a
  /// normal runtime dialog. This method prompts that page when needed.
  ///
  /// Returns true if full storage access is available.
  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;

    final sdkInt = await _sdkInt();

    // Android 13+ (API 33): notifications are a RUNTIME permission. Without
    // the grant, the audio_service media notification is silently dropped —
    // the user has no way to see or stop background audio from the shade.
    // Request it up front along with storage.
    if (sdkInt == null || sdkInt >= 33) {
      try {
        await Permission.notification.request();
      } catch (_) {}
    }

    // Android 11+: the app relies on MANAGE_EXTERNAL_STORAGE for arbitrary
    // file access. Try it first so the browser can read past scoped-storage
    // boundaries (Downloads, DCIM, external SD, etc.).
    final manage = await Permission.manageExternalStorage.status;
    if (manage.isGranted) return true;

    // Fall back to the legacy runtime permissions below API 30.
    if (sdkInt != null && sdkInt >= 30) {
      // Prompt the "All files access" settings page. We return true only once
      // granted; otherwise the caller (startup) will show the permission
      // explanation dialog.
      final granted = await requestAllFilesAccess();
      if (granted) return true;
    }

    final mediaStatus = await Permission.mediaLibrary.request();
    final storageStatus = await Permission.storage.request();
    final photosStatus = await Permission.photos.request();

    debugPrint(
      'Storage permissions: manage=$manage, media=$mediaStatus, '
      'storage=$storageStatus, photos=$photosStatus',
    );

    return manage.isGranted ||
        mediaStatus.isGranted ||
        storageStatus.isGranted ||
        photosStatus.isGranted;
  }

  /// Returns the current Android SDK int, or null on non-Android / failure.
  static Future<int?> _sdkInt() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return null;
    }
  }

  /// Opens the system "All files access" page. Returns true once granted.
  static Future<bool> requestAllFilesAccess() async {
    try {
      final status = await Permission.manageExternalStorage.request();
      return status.isGranted || await _isAllFilesAccessGranted();
    } catch (_) {
      return await _isAllFilesAccessGranted();
    }
  }

  static Future<bool> _isAllFilesAccessGranted() async {
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  }

  /// Opens the app settings page for the user to grant permissions manually.
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
    final manage = await Permission.manageExternalStorage.status;
    if (manage.isGranted) return true;
    final media = await Permission.mediaLibrary.status;
    final storage = await Permission.storage.status;
    return media.isGranted || storage.isGranted;
  }
}
