import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Common paths used across the app. On Android, uses platform-appropriate
/// storage directories instead of Linux home-directory paths.
class AppPaths {
  static String get home {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0');
      if (dir.existsSync()) return dir.path;
      return '/storage/emulated/0';
    }
    return Platform.environment['HOME'] ?? '/home/user';
  }

  static String get desktop => Platform.isAndroid ? '$home/DCIM' : '$home/Desktop';

  static String get documents => Platform.isAndroid ? '$home/Documents' : '$home/Documents';

  static String get downloads => Platform.isAndroid ? '$home/Download' : '$home/Downloads';

  static String get pictures => Platform.isAndroid ? '$home/DCIM' : '$home/Pictures';

  static String get music => Platform.isAndroid ? '$home/Music' : '$home/Music';

  static String get videos => Platform.isAndroid ? '$home/Videos' : '$home/Videos';

  static String get trash => Platform.isAndroid ? '' : '$home/.local/share/Trash';

  /// App-local trash directory — created on first use via path_provider.
  static Future<String> get trashDir async {
    if (Platform.isAndroid) {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}/trash';
    }
    return trash;
  }

  /// SwordFM-specific directories
  static String get swordfmDownloads => Platform.isAndroid
      ? '$downloads/SwordFM'
      : '$downloads/SwordFM';

  static const String bookmarksFile = '.swordfm_bookmarks';

  static List<String> get places => [
    home,
    desktop,
    documents,
    downloads,
    pictures,
    music,
    videos,
  ];
}
