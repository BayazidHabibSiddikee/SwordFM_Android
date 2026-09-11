import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to [path]; if the target is not writable — the typical
/// cause on Android 11+ is "All files access" (MANAGE_EXTERNAL_STORAGE) not
/// being granted, which makes every write into Downloads/DCIM throw —
/// falls back to the app's documents directory instead.
///
/// Returns the path the file was ACTUALLY written to, so callers can show
/// the real location instead of a path that silently doesn't exist.
Future<String> writeBytesResilient(String path, List<int> bytes) async {
  try {
    final dir = p.dirname(path);
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  } catch (e) {
    debugPrint('writeBytesResilient: $path failed ($e) — falling back');
    final docs = await getApplicationDocumentsDirectory();
    final fallbackPath = p.join(docs.path, p.basename(path));
    await File(fallbackPath).writeAsBytes(bytes, flush: true);
    return fallbackPath;
  }
}
