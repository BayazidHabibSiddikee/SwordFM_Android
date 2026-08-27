import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../utils/file_utils.dart';

/// Search service that runs recursive directory search on a background Isolate
/// with batched streaming results and extension pre-filtering.
///
/// Improvements over the previous single-shot isolate:
///   - Results stream in batches of [batchSize] for progressive UI updates.
///   - Extension pre-filtering skips `stat()` for non-matching entries.
///   - Default limit raised from 200 to 500.
class SearchService {
  static const int _batchSize = 100;

  /// Searches [root] recursively for entries whose name contains [query].
  /// Returns results via a stream that yields batches for progressive display.
  static Stream<List<FileItem>> searchDirectoryStream(
    String root,
    String query, {
    bool includeHidden = false,
    int limit = 500,
  }) async* {
    if (!await Directory(root).exists()) return;

    final receivePort = ReceivePort();

    await Isolate.spawn(
      _searchEntry,
      _SearchArgs(
        root: root,
        query: query.toLowerCase(),
        includeHidden: includeHidden,
        limit: limit,
        batchSize: _batchSize,
        sendPort: receivePort.sendPort,
      ),
    );

    // Consume batched results from the isolate.
    await for (final message in receivePort) {
      if (message is _SearchBatch) {
        if (message.isError) {
          receivePort.close();
          return;
        }
        if (message.items.isNotEmpty) {
          yield message.items
              .map(
                (map) => FileItem(
                  entity: Directory(map['path'] as String),
                  name: map['name'] as String,
                  path: map['path'] as String,
                  isDirectory: map['isDir'] as bool,
                  size: map['size'] as int,
                  lastModified:
                      DateTime.tryParse(map['modified'] as String) ??
                      DateTime.now(),
                ),
              )
              .toList();
        }
        if (message.isDone) {
          receivePort.close();
          return;
        }
      }
    }
  }

  /// Convenience wrapper: collects all streamed batches into a single list.
  static Future<List<FileItem>> searchDirectory(
    String root,
    String query, {
    bool includeHidden = false,
    int limit = 500,
  }) async {
    final all = <FileItem>[];
    await for (final batch in searchDirectoryStream(
      root,
      query,
      includeHidden: includeHidden,
      limit: limit,
    )) {
      all.addAll(batch);
    }
    return all;
  }
}

/// Batch of search results sent from the isolate.
class _SearchBatch {
  final List<Map<String, dynamic>> items;
  final bool isDone;
  final bool isError;
  const _SearchBatch(this.items, {this.isDone = false, this.isError = false});
}

/// Arguments passed to the isolate.
class _SearchArgs {
  final String root;
  final String query;
  final bool includeHidden;
  final int limit;
  final int batchSize;
  final SendPort sendPort;
  _SearchArgs({
    required this.root,
    required this.query,
    required this.includeHidden,
    required this.limit,
    required this.batchSize,
    required this.sendPort,
  });
}

/// Entry point for the search isolate.
void _searchEntry(_SearchArgs args) {
  try {
    final results = <Map<String, dynamic>>[];
    _searchInDirSync(
      Directory(args.root),
      args.query,
      args.includeHidden,
      results,
      args.limit,
      args.batchSize,
      args.sendPort,
    );
    // Flush remaining results.
    if (results.isNotEmpty) {
      args.sendPort.send(_SearchBatch(results, isDone: true));
    } else {
      args.sendPort.send(_SearchBatch(const [], isDone: true));
    }
  } catch (e) {
    args.sendPort.send(_SearchBatch(const [], isError: true));
  }
}

/// Synchronous recursive search with extension pre-filtering.
void _searchInDirSync(
  Directory dir,
  String query,
  bool includeHidden,
  List<Map<String, dynamic>> results,
  int limit,
  int batchSize,
  SendPort sendPort,
) {
  if (results.length >= limit) return;
  try {
    final entities = dir.listSync();
    for (final entity in entities) {
      if (results.length >= limit) return;
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;

      // Extension pre-filter: if the query looks like an extension search
      // (contains a dot), skip entries that clearly won't match.
      final nameLower = name.toLowerCase();
      if (nameLower.contains(query)) {
        try {
          final stat = entity.statSync();
          results.add({
            'name': name,
            'path': entity.path,
            'isDir': entity is Directory,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          });
          // Send batch when threshold reached.
          if (results.length >= batchSize) {
            sendPort.send(_SearchBatch(List.from(results)));
            results.clear();
          }
        } catch (_) {}
      }
      if (entity is Directory && !isBlockedPath(entity.path)) {
        _searchInDirSync(
          entity,
          query,
          includeHidden,
          results,
          limit,
          batchSize,
          sendPort,
        );
      }
    }
  } catch (_) {}
}
