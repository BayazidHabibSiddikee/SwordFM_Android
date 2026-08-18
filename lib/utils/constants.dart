import 'dart:io';

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

  /// SwordFM-specific directories
  static String get swordfmDownloads => '$home/Downloads/SwordFM';
  static const String bookmarksFile = '.swordfm_bookmarks';

  static List<String> get places => [home, desktop, documents, downloads, pictures, music, videos];
}
