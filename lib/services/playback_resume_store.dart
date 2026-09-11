import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The version of the persisted playback-resume record format.
const int playbackResumeSchemaVersion = 1;

/// A stable description of a media file.
///
/// The complete identity, rather than a [hashCode], is used when constructing
/// the preference key. [storageRef] leaves room for non-local media providers
/// to add a stable bucket/object id (or similar) in the future.
class PlaybackMediaIdentity {
  PlaybackMediaIdentity({
    required String path,
    required this.fileSize,
    required DateTime modifiedAt,
    Map<String, String>? storageRef,
  }) : canonicalPath = canonicalizePlaybackPath(path),
       modifiedAtMillis = modifiedAt.millisecondsSinceEpoch,
       storageRef = _copyStorageRef(storageRef) {
    _validate();
  }

  /// Creates an identity when the caller already has a millisecond timestamp.
  PlaybackMediaIdentity.fromMilliseconds({
    required String path,
    required this.fileSize,
    required this.modifiedAtMillis,
    Map<String, String>? storageRef,
  }) : canonicalPath = canonicalizePlaybackPath(path),
       storageRef = _copyStorageRef(storageRef) {
    _validate();
  }

  /// Reconstructs an identity from a validated persisted JSON object.
  factory PlaybackMediaIdentity.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final fileSize = json['fileSize'];
    final modifiedAtMillis = json['modifiedAtMillis'];
    final storageRef = _decodeStorageRef(json['storageRef']);
    if (path is! String || fileSize is! int || modifiedAtMillis is! int) {
      throw const FormatException('Invalid playback media identity');
    }
    return PlaybackMediaIdentity.fromMilliseconds(
      path: path,
      fileSize: fileSize,
      modifiedAtMillis: modifiedAtMillis,
      storageRef: storageRef,
    );
  }

  /// The normalized path used for identity comparisons and storage keys.
  final String canonicalPath;
  final int fileSize;
  final int modifiedAtMillis;
  final Map<String, String>? storageRef;

  /// Alias useful to callers that work with filesystem metadata.
  int get size => fileSize;

  /// Alias useful to callers that use "timestamp" terminology.
  int get modifiedTimestampMillis => modifiedAtMillis;

  DateTime get modifiedAt =>
      DateTime.fromMillisecondsSinceEpoch(modifiedAtMillis);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': canonicalPath,
      'fileSize': fileSize,
      'modifiedAtMillis': modifiedAtMillis,
      if (storageRef != null) 'storageRef': _sortedStorageRef(storageRef!),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is PlaybackMediaIdentity &&
        canonicalPath == other.canonicalPath &&
        fileSize == other.fileSize &&
        modifiedAtMillis == other.modifiedAtMillis &&
        _mapsEqual(storageRef, other.storageRef);
  }

  @override
  int get hashCode => Object.hash(
    canonicalPath,
    fileSize,
    modifiedAtMillis,
    storageRef == null ? null : jsonEncode(_sortedStorageRef(storageRef!)),
  );

  void _validate() {
    if (canonicalPath.isEmpty || canonicalPath.length > 4096) {
      throw ArgumentError.value(canonicalPath, 'path', 'must be a valid path');
    }
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'cannot be negative');
    }
    if (modifiedAtMillis < 0) {
      throw ArgumentError.value(
        modifiedAtMillis,
        'modifiedAtMillis',
        'cannot be negative',
      );
    }
    if (storageRef != null && storageRef!.length > 32) {
      throw ArgumentError.value(
        storageRef,
        'storageRef',
        'has too many fields',
      );
    }
  }

  static Map<String, String>? _copyStorageRef(Map<String, String>? value) {
    if (value == null) return null;
    for (final entry in value.entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 128 ||
          entry.value.length > 2048) {
        throw ArgumentError.value(
          value,
          'storageRef',
          'contains an invalid field',
        );
      }
    }
    return Map.unmodifiable(Map<String, String>.from(value));
  }

  static Map<String, String>? _decodeStorageRef(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('Invalid storage reference');
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid storage reference');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }
}

/// Normalizes path spelling without touching the filesystem.
///
/// This deliberately does not resolve symlinks: resolving them would make
/// identity creation asynchronous and would make unavailable media impossible
/// to identify. URI schemes are preserved for future content/cloud refs.
String canonicalizePlaybackPath(String path) {
  if (path.isEmpty) return path;
  final separators = path.replaceAll('\\', '/');
  final scheme = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.-]*://)',
  ).firstMatch(separators);
  if (scheme != null) {
    final prefix = scheme.group(1)!;
    final remainder = separators.substring(prefix.length);
    final slash = remainder.indexOf('/');
    if (slash < 0) return '$prefix$remainder';
    final authority = remainder.substring(0, slash);
    final normalized = _normalizePathParts(remainder.substring(slash));
    return '$prefix$authority$normalized';
  }
  return _normalizePathParts(separators);
}

String _normalizePathParts(String path) {
  final absolute = path.startsWith('/');
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add(part);
      }
    } else {
      parts.add(part);
    }
  }
  final result = parts.join('/');
  if (absolute) return '/$result';
  return result;
}

Map<String, String> _sortedStorageRef(Map<String, String> value) {
  final entries = value.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return <String, String>{for (final entry in entries) entry.key: entry.value};
}

bool _mapsEqual(Map<String, String>? left, Map<String, String>? right) {
  if (left == null || right == null) return left == right;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

/// A versioned point that can be restored by an audio or video player.
class PlaybackResumePoint {
  PlaybackResumePoint({
    required this.positionMs,
    this.durationMs,
    this.queueIndex,
    int? updatedAtMillis,
    DateTime? updatedAt,
    this.schemaVersion = playbackResumeSchemaVersion,
  }) : updatedAtMillis =
           updatedAtMillis ??
           updatedAt?.millisecondsSinceEpoch ??
           DateTime.now().millisecondsSinceEpoch {
    _validate();
  }

  PlaybackResumePoint.fromMilliseconds({
    required this.positionMs,
    this.durationMs,
    this.queueIndex,
    required this.updatedAtMillis,
    this.schemaVersion = playbackResumeSchemaVersion,
  }) {
    _validate();
  }

  final int positionMs;
  final int? durationMs;
  final int? queueIndex;
  final int updatedAtMillis;
  final int schemaVersion;

  Duration get position => Duration(milliseconds: positionMs);

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  DateTime get updatedAt =>
      DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'positionMs': positionMs,
      'durationMs': durationMs,
      if (queueIndex != null) 'queueIndex': queueIndex,
      'updatedAtMillis': updatedAtMillis,
    };
  }

  factory PlaybackResumePoint.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    final positionMs = json['positionMs'];
    final durationMs = json['durationMs'];
    final queueIndex = json['queueIndex'];
    final updatedAtMillis = json['updatedAtMillis'];
    if (schemaVersion is! int ||
        positionMs is! int ||
        (durationMs != null && durationMs is! int) ||
        (queueIndex != null && queueIndex is! int) ||
        updatedAtMillis is! int) {
      throw const FormatException('Invalid playback resume point');
    }
    return PlaybackResumePoint.fromMilliseconds(
      positionMs: positionMs,
      durationMs: durationMs as int?,
      queueIndex: queueIndex as int?,
      updatedAtMillis: updatedAtMillis,
      schemaVersion: schemaVersion,
    );
  }

  void _validate() {
    if (schemaVersion != playbackResumeSchemaVersion) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'unsupported playback resume schema',
      );
    }
    if (positionMs < 0 ||
        (durationMs != null && durationMs! < 0) ||
        (queueIndex != null && queueIndex! < 0) ||
        updatedAtMillis < 0) {
      throw ArgumentError('Playback resume values cannot be negative');
    }
    if (durationMs != null && positionMs > durationMs!) {
      throw ArgumentError('positionMs cannot exceed durationMs');
    }
  }
}

/// SharedPreferences-backed persistence for resume points.
class PlaybackResumeStore {
  PlaybackResumeStore(this._preferences);

  static const int currentSchemaVersion = playbackResumeSchemaVersion;
  static const String storagePrefix = 'playback_resume.';
  static const String _recordPrefix = '${storagePrefix}v$currentSchemaVersion.';
  static const int _maximumRecordBytes = 16 * 1024;

  final SharedPreferences _preferences;

  /// Creates a store using the app's normal SharedPreferences instance.
  static Future<PlaybackResumeStore> create() async {
    return PlaybackResumeStore(await SharedPreferences.getInstance());
  }

  /// Reads a point only when the stored identity exactly matches [identity].
  /// Malformed or unsupported records are deleted instead of surfacing errors.
  Future<PlaybackResumePoint?> read(PlaybackMediaIdentity identity) async {
    await _preferences.reload();
    final key = _keyFor(identity);
    final raw = _preferences.getString(key);
    if (raw == null) return null;
    try {
      if (utf8.encode(raw).length > _maximumRecordBytes) {
        throw const FormatException('Playback resume record is too large');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Record is not an object');
      }
      final record = Map<String, dynamic>.from(decoded);
      if (record['schemaVersion'] != currentSchemaVersion) {
        throw const FormatException('Unsupported playback resume schema');
      }
      final identityJson = record['identity'];
      final pointJson = record['point'];
      if (identityJson is! Map || pointJson is! Map) {
        throw const FormatException('Record is missing identity or point');
      }
      final storedIdentity = PlaybackMediaIdentity.fromJson(
        Map<String, dynamic>.from(identityJson),
      );
      if (storedIdentity != identity) {
        await _preferences.remove(key);
        return null;
      }
      final point = PlaybackResumePoint.fromJson(
        Map<String, dynamic>.from(pointJson),
      );
      if (point.schemaVersion != currentSchemaVersion) {
        throw const FormatException('Unsupported playback point schema');
      }
      return point;
    } on FormatException {
      await _preferences.remove(key);
      return null;
    } on ArgumentError {
      await _preferences.remove(key);
      return null;
    } on TypeError {
      await _preferences.remove(key);
      return null;
    }
  }

  /// Persists [point] for [identity]. The complete identity is encoded in the
  /// key and in the record, so a changed file cannot accidentally resume.
  Future<void> write(
    PlaybackMediaIdentity identity,
    PlaybackResumePoint point,
  ) async {
    if (point.schemaVersion != currentSchemaVersion) {
      throw ArgumentError.value(
        point.schemaVersion,
        'point.schemaVersion',
        'unsupported playback resume schema',
      );
    }
    final record = <String, dynamic>{
      'schemaVersion': currentSchemaVersion,
      'identity': identity.toJson(),
      'point': point.toJson(),
    };
    final encoded = jsonEncode(record);
    if (utf8.encode(encoded).length > _maximumRecordBytes) {
      throw ArgumentError('Playback resume record is too large');
    }
    final stored = await _preferences.setString(_keyFor(identity), encoded);
    if (!stored) throw StateError('Could not persist playback resume point');
  }

  /// Removes the point for one media identity.
  Future<void> clear(PlaybackMediaIdentity identity) async {
    await _preferences.remove(_keyFor(identity));
  }

  /// Removes all versions of records owned by this store.
  Future<void> clearAll() async {
    final keys = _preferences
        .getKeys()
        .where((key) => key.startsWith(storagePrefix))
        .toList();
    for (final key in keys) {
      await _preferences.remove(key);
    }
  }

  String _keyFor(PlaybackMediaIdentity identity) {
    final bytes = utf8.encode(jsonEncode(identity.toJson()));
    return '$_recordPrefix${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}
