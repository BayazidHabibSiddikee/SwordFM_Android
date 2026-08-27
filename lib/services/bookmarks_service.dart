import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persists user bookmarks as JSON at `<app-support>/bookmarks.json`.
///
/// The on-disk format is identical to the Linux SwordFM file
/// `~/.config/swordfm/bookmarks.json`:
///
/// ```json
/// {"bookmarks": ["/path1", "/path2"]}
/// ```
class BookmarksService {
  static Future<String> get _filePath async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/bookmarks.json';
  }

  /// Loads bookmarks from disk. Returns an empty list when the file is
  /// missing or unreadable (a fresh empty file is created in that case).
  static Future<List<String>> load() async {
    try {
      final file = File(await _filePath);
      if (!await file.exists()) {
        await file.create(recursive: true);
        await file.writeAsString(jsonEncode({'bookmarks': <String>[]}));
        return [];
      }
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded['bookmarks'] is List) {
        return (decoded['bookmarks'] as List).whereType<String>().toList();
      }
      return [];
    } catch (e) {
      debugPrint('BookmarksService.load failed: $e');
      return [];
    }
  }

  /// Writes [bookmarks] to disk as `{"bookmarks": [...]}`.
  static Future<void> save(List<String> bookmarks) async {
    try {
      final file = File(await _filePath);
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode({'bookmarks': bookmarks}));
    } catch (e) {
      debugPrint('BookmarksService.save failed: $e');
    }
  }
}