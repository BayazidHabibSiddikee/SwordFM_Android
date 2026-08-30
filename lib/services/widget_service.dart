import 'dart:convert';
import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the home screen widget — pushes recent files + bookmarks to the OS.
class WidgetService {
  static const _kRecentKey = 'widget_recent_files';
  static const _kBookmarkKey = 'widget_bookmarks';
  static const _maxRecent = 5;
  static const _maxBookmarks = 3;

  /// Android widget provider class name.
  static const _androidProvider = 'com.swordfm.swordfm.SwordFmWidgetProvider';

  /// Saves recent files and pushes them to the home widget.
  static Future<void> updateWidget({
    List<String>? recentFiles,
    List<String>? bookmarks,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (recentFiles != null) {
        final limited = recentFiles.take(_maxRecent).toList();
        await prefs.setStringList(_kRecentKey, limited);
      }

      if (bookmarks != null) {
        final limited = bookmarks.take(_maxBookmarks).toList();
        await prefs.setStringList(_kBookmarkKey, limited);
      }

      final recent = prefs.getStringList(_kRecentKey) ?? [];
      final bmarks = prefs.getStringList(_kBookmarkKey) ?? [];

      for (var i = 0; i < _maxRecent; i++) {
        if (i < recent.length) {
          await HomeWidget.saveWidgetData<String>(
            'recent_$i',
            jsonEncode({
              'name': p.basename(recent[i]),
              'path': recent[i],
            }),
          );
        } else {
          await HomeWidget.saveWidgetData<String>('recent_$i', null);
        }
      }

      for (var i = 0; i < _maxBookmarks; i++) {
        if (i < bmarks.length) {
          await HomeWidget.saveWidgetData<String>(
            'bookmark_$i',
            jsonEncode({
              'name': p.basename(bmarks[i]),
              'path': bmarks[i],
            }),
          );
        } else {
          await HomeWidget.saveWidgetData<String>('bookmark_$i', null);
        }
      }

      await HomeWidget.saveWidgetData<String>('recent_count', '${recent.length}');
      await HomeWidget.saveWidgetData<String>('bookmark_count', '${bmarks.length}');

      await HomeWidget.updateWidget(androidName: _androidProvider);
    } catch (_) {}
  }

  /// Saves a file path to the recent files list.
  static Future<void> addRecentFile(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final recent = prefs.getStringList(_kRecentKey) ?? [];
      recent.remove(path);
      recent.insert(0, path);
      if (recent.length > _maxRecent) recent.removeLast();
      await prefs.setStringList(_kRecentKey, recent);
      // Also push to widget immediately
      await updateWidget(recentFiles: recent);
    } catch (_) {}
  }

  /// Saves bookmarks to widget.
  static Future<void> syncBookmarks(List<String> bookmarks) async {
    await updateWidget(bookmarks: bookmarks);
  }
}
