import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Common paths used across the app.
class AppPaths {
  static String get home => Platform.environment['HOME'] ?? '/home/user';
  static String get desktop => '$home/Desktop';
  static String get documents => '$home/Documents';
  static String get downloads => '$home/Downloads';
  static String get pictures => '$home/Pictures';
  static String get music => '$home/Music';
  static String get videos => '$home/Videos';
  static String get trash => '$home/.local/share/Trash';

  /// App-local trash directory — created on first use via path_provider.
  /// Uses the support directory so it survives across launches and matches
  /// Linux ~/.local/share/Trash convention where possible.
  static Future<String> get trashDir async {
    if (Platform.isAndroid) {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}/trash';
    }
    return trash;
  }

  /// SwordFM-specific directories
  static String get swordfmDownloads => '$home/Downloads/SwordFM';
  static const String bookmarksFile = '.swordfm_bookmarks';

  static List<String> get places => [home, desktop, documents, downloads, pictures, music, videos];
}
