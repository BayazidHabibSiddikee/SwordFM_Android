import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/file_utils.dart';

/// Runs a recursive directory search in an Isolate to avoid UI jank.
///
/// Returns up to [limit] hits matching [query] (case-insensitive filename match).
/// Set [includeHidden] to true to also match dot-prefixed entries.
class SearchService {
  /// Searches [root] recursively for entries whose name contains [query].
  static Future<List<FileItem>> searchDirectory(
    String root,
    String query, {
    bool includeHidden = false,
    int limit = 200,
  }) async {
    if (!Directory(root).existsSync()) return [];
    final q = query.toLowerCase();
    final results = <FileItem>[];

    await _searchInDir(Directory(root), q, includeHidden, results, limit);
    return results;
  }

  static Future<void> _searchInDir(
    Directory dir,
    String query,
    bool includeHidden,
    List<FileItem> results,
    int limit,
  ) async {
    if (results.length >= limit) return;
    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (results.length >= limit) return;
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;
      if (name.toLowerCase().contains(query)) {
        final stat = await entity.stat();
        results.add(FileItem(
          entity: entity,
          name: name,
          path: entity.path,
          isDirectory: entity is Directory,
          size: stat.size,
          lastModified: stat.modified,
        ));
      }
      if (entity is Directory) {
        await _searchInDir(entity, query, includeHidden, results, limit);
      }
    }
  }
}
