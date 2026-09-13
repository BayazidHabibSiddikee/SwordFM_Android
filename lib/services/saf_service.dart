import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A folder grant obtained through the Storage Access Framework tree picker.
///
/// [uri] is the `content://…tree/…` URI the OS handed back; [documentId]
/// addressing inside the tree is relative to it. Grants survive app restarts
/// (persistable URI permission) so the folder list is restored from prefs.
class SafTree {
  final String uri;
  final String displayName;
  const SafTree({required this.uri, required this.displayName});

  Map<String, String> toJson() => {'uri': uri, 'displayName': displayName};

  factory SafTree.fromJson(Map<String, dynamic> m) => SafTree(
        uri: m['uri'] as String? ?? '',
        displayName: m['displayName'] as String? ?? 'Shared folder',
      );
}

/// One entry inside a SAF tree.
class SafEntry {
  final String documentId;
  final String name;
  final String mimeType;
  final int size;
  final DateTime lastModified;
  final bool isDir;
  const SafEntry({
    required this.documentId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.lastModified,
    required this.isDir,
  });

  factory SafEntry.fromJson(Map<dynamic, dynamic> m) => SafEntry(
        documentId: m['documentId'] as String? ?? '',
        name: (m['name'] as String?)?.isNotEmpty == true
            ? m['name'] as String
            : 'item',
        mimeType: m['mimeType'] as String? ?? 'application/octet-stream',
        size: (m['size'] as num?)?.toInt() ?? 0,
        lastModified: DateTime.fromMillisecondsSinceEpoch(
          (m['lastModified'] as num?)?.toInt() ?? 0,
        ),
        isDir: (m['isDir'] as bool?) ?? false,
      );
}

/// Storage Access Framework fallback — the file-access path when the user
/// denies "All files access" (MANAGE_EXTERNAL_STORAGE).
///
/// Without this, the browser shows an empty sandbox and the app is a
/// non-starter; with it, the user can grant individual folders through the
/// system picker and browse/open them read-only. Writes stay inside the
/// app sandbox / share root, which Dart already handles.
///
/// No-op on non-Android platforms (every method returns empty/null).
class SafService {
  static const _channel = MethodChannel('com.swordfm/saf');
  static const _prefsKey = 'saf_trees_v1';

  /// Test override for [isAndroid] — the SAF channel only exists on Android,
  /// so unit tests running on the host must force the gate open to exercise
  /// the parsing/sorting logic against a mocked channel.
  @visibleForTesting
  static bool? debugForceAndroid;

  static bool get _isAndroid =>
      debugForceAndroid ?? Platform.isAndroid;

  /// True when the native SAF channel exists (Android with SafBridge wired).
  static Future<bool> get isAvailable async {
    if (!_isAndroid) return false;
    try {
      await _channel.invokeMethod<List<dynamic>>('persistedTrees');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Launches the system folder picker (`ACTION_OPEN_DOCUMENT_TREE`) and
  /// persists the grant. Returns the new tree, or null when cancelled.
  static Future<SafTree?> openTree() async {
    if (!_isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('openTree');
      if (raw == null) return null;
      final tree = SafTree(
        uri: raw['uri'] as String? ?? '',
        displayName: raw['displayName'] as String? ?? 'Shared folder',
      );
      if (tree.uri.isEmpty) return null;
      await _remember(tree);
      return tree;
    } on PlatformException {
      return null; // SAF_CANCELLED / SAF_NO_PICKER — caller shows the hint
    } catch (_) {
      return null;
    }
  }

  /// Trees the OS still holds read grants for, merged with the remembered
  /// list (a grant revoked in system settings disappears here).
  static Future<List<SafTree>> persistedTrees() async {
    if (!_isAndroid) return [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('persistedTrees');
      final live = (raw ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => SafTree(
                uri: m['uri'] as String? ?? '',
                displayName: m['displayName'] as String? ?? 'Shared folder',
              ))
          .where((t) => t.uri.isNotEmpty)
          .toList();
      await _pruneTo(live.map((t) => t.uri).toSet());
      return live;
    } catch (_) {
      return [];
    }
  }

  /// Lists the children of [tree], or of [parentDocumentId] when browsing
  /// deeper. Directories sort first (matching the file browser), then by name.
  static Future<List<SafEntry>> listChildren(
    SafTree tree, {
    String? parentDocumentId,
  }) async {
    if (!_isAndroid) return [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listChildren', {
        'treeUri': tree.uri,
        if (parentDocumentId case final parentId) 'parentDocumentId': parentId,
      });
      final entries = (raw ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map(SafEntry.fromJson)
          .where((e) => e.documentId.isNotEmpty)
          .toList();
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } catch (_) {
      return [];
    }
  }

  /// Copies [entry] into the app cache dir and returns the local path so the
  /// existing viewers (PDF/DOCX/image/…) can open it unchanged. Returns null
  /// on failure.
  static Future<String?> openDocument(SafTree tree, SafEntry entry) async {
    if (entry.isDir) return null;
    if (!_isAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>('openDocument', {
        'treeUri': tree.uri,
        'documentId': entry.documentId,
      });
      return (path?.isNotEmpty == true) ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Drops the persisted grant for [tree] and forgets it.
  static Future<bool> releaseTree(SafTree tree) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('releaseTree', {
        'treeUri': tree.uri,
      }) ??
          false;
      await _forget(tree.uri);
      return ok;
    } catch (_) {
      return false;
    }
  }

  // --- Remembered tree list (prefs mirror of the OS grants) ---------------

  static Future<void> _remember(SafTree tree) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await _remembered(prefs);
      current.removeWhere((t) => t.uri == tree.uri);
      current.add(tree);
      await prefs.setStringList(
        _prefsKey,
        current
            .map((t) => jsonEncode({'uri': t.uri, 'displayName': t.displayName}))
            .toList(),
      );
    } catch (_) {}
  }

  static Future<void> _forget(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await _remembered(prefs);
      current.removeWhere((t) => t.uri == uri);
      await prefs.setStringList(
        _prefsKey,
        current.map((t) => jsonEncode({'uri': t.uri, 'displayName': t.displayName})).toList(),
      );
    } catch (_) {}
  }

  static Future<void> _pruneTo(Set<String> liveUris) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await _remembered(prefs);
      final kept = current.where((t) => liveUris.contains(t.uri)).toList();
      if (kept.length != current.length) {
        await prefs.setStringList(
          _prefsKey,
          kept.map((t) => jsonEncode({'uri': t.uri, 'displayName': t.displayName})).toList(),
        );
      }
    } catch (_) {}
  }

  static Future<List<SafTree>> _remembered(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_prefsKey) ?? [];
    final out = <SafTree>[];
    for (final s in raw) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        final tree = SafTree.fromJson(m);
        if (tree.uri.isNotEmpty) out.add(tree);
      } catch (_) {
        // Tolerate the legacy control-char encoding from earlier builds.
        final i = s.indexOf('\u0001');
        if (i < 0) {
          if (s.isNotEmpty) {
            out.add(SafTree(uri: s, displayName: 'Shared folder'));
          }
        } else {
          final uri = s.substring(0, i);
          if (uri.isNotEmpty) {
            out.add(SafTree(uri: uri, displayName: s.substring(i + 1)));
          }
        }
      }
    }
    return out;
  }
}
