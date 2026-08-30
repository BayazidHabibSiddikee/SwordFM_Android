import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../utils/file_utils.dart';

/// Search modes for filename matching.
enum SearchMode { substring, regex, glob }

/// Search service that runs recursive directory search on a background Isolate
/// with batched streaming results and extension pre-filtering.
class SearchService {
  static const int _batchSize = 100;

  /// Searches [root] recursively for entries whose name matches [query].
  /// Returns results via a stream that yields batches for progressive display.
  static Stream<List<FileItem>> searchDirectoryStream(
    String root,
    String query, {
    bool includeHidden = false,
    int limit = 500,
    SearchMode mode = SearchMode.substring,
    int minSize = 0,
    int maxSize = 0, // 0 = no limit
    bool allowRoot = false,
    bool searchContent = false,
  }) async* {
    if (!await Directory(root).exists()) return;

    // Pre-compile regex/glob if needed (done on main isolate, sent to worker).
    String? regexPattern;
    if (mode == SearchMode.regex) {
      try {
        RegExp(query, caseSensitive: false);
        regexPattern = query;
      } catch (_) {
        return; // invalid regex, no results
      }
    } else if (mode == SearchMode.glob) {
      regexPattern = _globToRegex(query);
    }

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
        mode: mode,
        regexPattern: regexPattern,
        minSize: minSize,
        maxSize: maxSize,
        allowRoot: allowRoot,
        searchContent: searchContent,
      ),
    );

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
                  snippet: map['snippet'] as String?,
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
    SearchMode mode = SearchMode.substring,
    int minSize = 0,
    int maxSize = 0,
    bool allowRoot = false,
    bool searchContent = false,
  }) async {
    final all = <FileItem>[];
    await for (final batch in searchDirectoryStream(
      root,
      query,
      includeHidden: includeHidden,
      limit: limit,
      mode: mode,
      minSize: minSize,
      maxSize: maxSize,
      allowRoot: allowRoot,
      searchContent: searchContent,
    )) {
      all.addAll(batch);
    }
    return all;
  }

  /// Converts a simple glob pattern (e.g. `*.jpg`, `photo*`, `*test?.txt`)
  /// to a regex string.
  static String _globToRegex(String glob) {
    var out = '';
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      switch (c) {
        case '*':
          out += '.*';
        case '?':
          out += '.';
        case '.':
          out += '\\.';
        case '[':
        case ']':
        case '(':
        case ')':
        case '{':
        case '}':
        case '+':
        case '^':
        case r'$':
        case '|':
        case '\\':
          out += '\\$c';
        default:
          out += c;
      }
    }
    return '^$out\$';
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
  final SearchMode mode;
  final String? regexPattern;
  final int minSize;
  final int maxSize;
  final bool allowRoot;
  final bool searchContent;
  _SearchArgs({
    required this.root,
    required this.query,
    required this.includeHidden,
    required this.limit,
    required this.batchSize,
    required this.sendPort,
    this.mode = SearchMode.substring,
    this.regexPattern,
    this.minSize = 0,
    this.maxSize = 0,
    this.allowRoot = false,
    this.searchContent = false,
  });
}

/// Entry point for the search isolate.
void _searchEntry(_SearchArgs args) {
  try {
    final results = <Map<String, dynamic>>[];
    // Pre-compile the regex on the isolate if a pattern was provided.
    RegExp? regex;
    if (args.regexPattern != null) {
      try {
        regex = RegExp(args.regexPattern!, caseSensitive: false);
      } catch (_) {}
    }
    _searchInDirSync(
      Directory(args.root),
      args.query,
      args.includeHidden,
      results,
      args.limit,
      args.batchSize,
      args.sendPort,
      args.mode,
      regex,
      args.minSize,
      args.maxSize,
      args.allowRoot,
      args.searchContent,
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
  SearchMode mode,
  RegExp? regex,
  int minSize,
  int maxSize,
  bool allowRoot,
  bool searchContent,
) {
  if (results.length >= limit) return;
  try {
    final entities = dir.listSync();
    for (final entity in entities) {
      if (results.length >= limit) return;
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;

      final nameLower = name.toLowerCase();
      final queryLower = query.toLowerCase();
      String? snippet;

      // Filename match based on mode.
      bool matched = false;
      switch (mode) {
        case SearchMode.substring:
          matched = nameLower.contains(queryLower);
        case SearchMode.regex:
          matched = regex?.hasMatch(name) ?? false;
        case SearchMode.glob:
          matched = regex?.hasMatch(nameLower) ?? false;
      }

      // Content match: scan the head of searchable text files. Glob mode is
      // filename-only (an anchored glob against file content is meaningless).
      if (!matched &&
          searchContent &&
          mode != SearchMode.glob &&
          isSearchableText(entity.path)) {
        snippet = _contentSnippet(entity.path, query, mode, regex);
        matched = snippet != null;
      }

      if (matched) {
        try {
          final stat = entity.statSync();
          // Size filter.
          if (minSize > 0 && stat.size < minSize) continue;
          if (maxSize > 0 && stat.size > maxSize) continue;
          results.add({
            'name': name,
            'path': entity.path,
            'isDir': entity is Directory,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
            'snippet': snippet,
          });
          if (results.length >= batchSize) {
            sendPort.send(_SearchBatch(List.from(results)));
            results.clear();
          }
        } catch (_) {}
      }
      if (entity is Directory &&
          (allowRoot || !isBlockedPath(entity.path))) {
        _searchInDirSync(
          entity,
          query,
          includeHidden,
          results,
          limit,
          batchSize,
          sendPort,
          mode,
          regex,
          minSize,
          maxSize,
          allowRoot,
          searchContent,
        );
      }
    }
  } catch (_) {}
}

const int _contentMaxBytes = 512 * 1024;

/// Reads the head of [path] and returns a snippet line containing the first
/// query/regex match, or null when the file is binary/unreadable/not matching.
String? _contentSnippet(
  String path,
  String query,
  SearchMode mode,
  RegExp? regex,
) {
  try {
    final file = File(path);
    final len = file.lengthSync();
    if (len == 0) return null;
    final raf = file.openSync();
    final List<int> bytes;
    try {
      bytes = raf.readSync(len < _contentMaxBytes ? len : _contentMaxBytes);
    } finally {
      raf.closeSync();
    }
    // NUL sniff on the first 8KB — binary files are skipped.
    final sniffLen = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < sniffLen; i++) {
      if (bytes[i] == 0) return null;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    switch (mode) {
      case SearchMode.substring:
        final idx = text.toLowerCase().indexOf(query.toLowerCase());
        if (idx < 0) return null;
        return _snippetLine(text, idx, idx + query.length);
      case SearchMode.regex:
        final m = regex?.firstMatch(text);
        if (m == null) return null;
        return _snippetLine(text, m.start, m.end);
      case SearchMode.glob:
        return null; // unreachable — glob skips content scan
    }
  } catch (_) {
    return null;
  }
}

/// Extracts the line containing [start]..[end] in [text], trimmed to ~120 chars.
String _snippetLine(String text, int start, int end) {
  var lineStart = text.lastIndexOf('\n', start) + 1;
  var lineEnd = text.indexOf('\n', end);
  if (lineEnd == -1 || lineEnd < lineStart) lineEnd = text.length;
  var line = text.substring(lineStart, lineEnd).trim();
  if (line.length > 120) {
    line = '${line.substring(0, 117)}…';
  }
  return line;
}
