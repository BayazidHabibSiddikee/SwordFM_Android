import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../utils/file_utils.dart';

/// Search result sent back from the isolate.
class _SearchResult {
  final List<Map<String, dynamic>> items;
  final String? error;
  _SearchResult(this.items, this.error);
}

/// Search service that runs recursive directory search on a background Isolate
/// to keep the UI responsive during large scans.
class SearchService {
  /// Searches [root] recursively for entries whose name contains [query].
  /// Runs on a background Isolate to avoid UI jank.
  static Future<List<FileItem>> searchDirectory(
    String root,
    String query, {
    bool includeHidden = false,
    int limit = 200,
  }) async {
    if (!Directory(root).existsSync()) return [];

    // Create receive port first, then get sendPort from it
    final receivePort = ReceivePort();

    // Spawn isolate with the search entry point
    await Isolate.spawn(_searchEntry, _SearchArgs(
      root: root,
      query: query.toLowerCase(),
      includeHidden: includeHidden,
      limit: limit,
      sendPort: receivePort.sendPort,
    ));

    // Wait for result
    final result = await receivePort.first as _SearchResult;
    receivePort.close();

    if (result.error != null) {
      return [];
    }

    return result.items.map((map) => FileItem(
      entity: Directory(map['path'] as String), // placeholder, not used for display
      name: map['name'] as String,
      path: map['path'] as String,
      isDirectory: map['isDir'] as bool,
      size: map['size'] as int,
      lastModified: DateTime.tryParse(map['modified'] as String) ?? DateTime.now(),
    )).toList();
  }
}

/// Arguments passed to the isolate.
class _SearchArgs {
  final String root;
  final String query;
  final bool includeHidden;
  final int limit;
  final SendPort sendPort;
  _SearchArgs({
    required this.root,
    required this.query,
    required this.includeHidden,
    required this.limit,
    required this.sendPort,
  });
}

/// Entry point for the search isolate — must be a top-level function.
void _searchEntry(_SearchArgs args) {
  final results = <Map<String, dynamic>>[];
  _searchInDirSync(Directory(args.root), args.query, args.includeHidden, results, args.limit);

  args.sendPort.send(_SearchResult(results, null));
}

/// Synchronous recursive search (runs inside the isolate).
void _searchInDirSync(
  Directory dir,
  String query,
  bool includeHidden,
  List<Map<String, dynamic>> results,
  int limit,
) {
  if (results.length >= limit) return;
  try {
    final entities = dir.listSync();
    for (final entity in entities) {
      if (results.length >= limit) return;
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;
      if (name.toLowerCase().contains(query)) {
        try {
          final stat = entity.statSync();
          results.add({
            'name': name,
            'path': entity.path,
            'isDir': entity is Directory,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          });
        } catch (_) {}
      }
      if (entity is Directory) {
        _searchInDirSync(entity, query, includeHidden, results, limit);
      }
    }
  } catch (e) {
    // Ignore permission errors etc.
  }
}
