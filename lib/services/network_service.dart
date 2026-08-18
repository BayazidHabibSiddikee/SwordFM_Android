import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// Connection profile for remote servers (WebDAV or SFTP).
class NetworkProfile {
  final String id;
  final String name;
  final String type; // 'webdav' or 'sftp'
  final String host;
  final int port;
  final String username;
  final String password;
  final String? remotePath;

  NetworkProfile({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.remotePath = '/',
  });

  bool get isConnected => _connected;
  bool _connected = false;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'host': host,
        'port': port,
        'username': username,
        'remotePath': remotePath,
      };

  factory NetworkProfile.fromJson(Map<String, dynamic> json) => NetworkProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        username: json['username'] as String,
        password: json['password'] as String,
        remotePath: json['remotePath'] as String?,
      );
}

/// Service managing WebDAV and SFTP connections.
/// Provides listing, uploading, and downloading over remote protocols.
class NetworkService {
  final Map<String, NetworkProfile> _profiles = {};
  final List<ConnLog> _logs = [];

  Stream<List<ConnLog>> get logStream => _logController.stream;
  final StreamController<List<ConnLog>> _logController =
      StreamController.broadcast();

  List<ConnLog> get logs => List.unmodifiable(_logs);
  Map<String, NetworkProfile> get profiles => Map.unmodifiable(_profiles);

  /// Add or update a connection profile.
  void addProfile(NetworkProfile profile) {
    _profiles[profile.id] = profile;
  }

  /// Remove a connection profile.
  void removeProfile(String id) {
    _profiles.remove(id);
  }

  /// Check if a profile exists.
  bool hasProfile(String id) => _profiles.containsKey(id);

  /// Connect to a profile via WebDAV or SFTP and list remote directory.
  Future<List<RemoteEntry>> listDirectory(String profileId,
      {String path = '/'}) async {
    final profile = _profiles[profileId];
    if (profile == null) throw Exception('Profile not found: $profileId');

    addLog(profileId, 'Connecting...');
    try {
      if (profile.type == 'webdav') {
        return await _listWebdav(profile, path);
      } else {
        return await _listSftp(profile, path);
      }
    } catch (e) {
      addLog(profileId, 'Error: $e');
      rethrow;
    }
  }

  /// Upload a local file to a remote server.
  Future<void> uploadFile(String profileId, String localPath,
      {String remotePath = '/'}) async {
    final profile = _profiles[profileId];
    if (profile == null) throw Exception('Profile not found: $profileId');

    addLog(profileId, 'Uploading ${p.basename(localPath)}...');
    try {
      if (profile.type == 'webdav') {
        await _uploadWebdav(profile, localPath, remotePath);
      } else {
        await _uploadSftp(profile, localPath, remotePath);
      }
      addLog(profileId, 'Upload complete');
    } catch (e) {
      addLog(profileId, 'Upload failed: $e');
      rethrow;
    }
  }

  /// Download a remote file.
  Future<void> downloadFile(String profileId, String remotePath,
      String localDir) async {
    final profile = _profiles[profileId];
    if (profile == null) throw Exception('Profile not found: $profileId');

    addLog(profileId, 'Downloading ${p.basename(remotePath)}...');
    try {
      if (profile.type == 'webdav') {
        await _downloadWebdav(profile, remotePath, localDir);
      } else {
        await _downloadSftp(profile, remotePath, localDir);
      }
      addLog(profileId, 'Download complete');
    } catch (e) {
      addLog(profileId, 'Download failed: $e');
      rethrow;
    }
  }

  // ─── WebDAV helpers ────────────────────────────────────────────────────────

  static Future<List<RemoteEntry>> _listWebdav(
      NetworkProfile profile, String path) async {
    final dio = Dio(BaseOptions(
      baseUrl: '${profile.host}:${profile.port}',
      connectTimeout: const Duration(seconds: 10),
    ));
    dio.interceptors.add(
      LogInterceptor(requestBody: false, responseBody: false),
    );
    final auth =
        'Basic ${base64Encode('${profile.username}:${profile.password}'.codeUnits)}';
    dio.options.headers['Authorization'] = auth;

    final url = _buildUrl(path, profile.remotePath!);
    final resp = await dio.get(url);

    // Parse WebDAV multistatus response
    final entries = <RemoteEntry>[];
    // Simple parsing: look for href elements
    final html = resp.data as String;
    final hrefRegex = RegExp(r'<href>([^<]+)</href>');
    for (final match in hrefRegex.allMatches(html)) {
      final href = match.group(1)!;
      final name = p.basename(href.replaceAll(profile.remotePath!, ''));
      if (name.isNotEmpty && name != '.' && name != '..') {
        entries.add(RemoteEntry(name: name, isDir: href.endsWith('/')));
      }
    }
    return entries;
  }

  static Future<void> _uploadWebdav(
      NetworkProfile profile, String localPath, String remotePath) async {
    final dio = Dio(BaseOptions(
      baseUrl: '${profile.host}:${profile.port}$remotePath',
      connectTimeout: const Duration(seconds: 30),
    ));
    final auth =
        'Basic ${base64Encode('${profile.username}:${profile.password}'.codeUnits)}';
    dio.options.headers['Authorization'] = auth;
    dio.options.headers['Overwrite'] = 'T';

    final fileBytes = await _readFileBytes(localPath);
    final fileName = p.basename(localPath);
    await dio.put('$_buildUrl(remotePath, profile.remotePath!)/$fileName',
        data: fileBytes);
  }

  static Future<void> _downloadWebdav(
      NetworkProfile profile, String remotePath, String localDir) async {
    final dio = Dio(BaseOptions(
      baseUrl: '${profile.host}:${profile.port}',
      connectTimeout: const Duration(seconds: 30),
    ));
    final auth =
        'Basic ${base64Encode('${profile.username}:${profile.password}'.codeUnits)}';
    dio.options.headers['Authorization'] = auth;

    final bytes = await dio.get(
      _buildUrl(remotePath, profile.remotePath!),
      options: Options(responseType: ResponseType.bytes),
    );
    final filePath = '${localDir}/${p.basename(remotePath)}';
    await File(filePath).writeAsBytes(bytes.data as List<int>);
  }

  // ─── SFTP helpers (placeholder — dartssh2 integration) ─────────────────────

  static Future<List<RemoteEntry>> _listSftp(
      NetworkProfile profile, String path) async {
    // TODO: integrate dartssh2 SFTP client
    throw UnimplementedError('SFTP not yet implemented');
  }

  static Future<void> _uploadSftp(
      NetworkProfile profile, String localPath, String remotePath) async {
    throw UnimplementedError('SFTP not yet implemented');
  }

  static Future<void> _downloadSftp(
      NetworkProfile profile, String remotePath, String localDir) async {
    throw UnimplementedError('SFTP not yet implemented');
  }

  // ─── Utilities ─────────────────────────────────────────────────────────────

  static String _buildUrl(String relative, String root) {
    final base = root.replaceAll(RegExp(r'/$'), '');
    final rel = relative.replaceAll(RegExp(r'^/'), '');
    return '$base/$rel';
  }

  static Future<List<int>> _readFileBytes(String path) async {
    final f = File(path);
    return f.readAsBytes();
  }

  void addLog(String profileId, String message) {
    _logs.add(ConnLog(profileId: profileId, message: message, ts: DateTime.now()));
    if (_logs.length > 100) _logs.removeAt(0);
    _logController.add(List.from(_logs));
  }
}

class RemoteEntry {
  const RemoteEntry({required this.name, required this.isDir});
  final String name;
  final bool isDir;
}

class ConnLog {
  const ConnLog({required this.profileId, required this.message, required this.ts});
  final String profileId;
  final String message;
  final DateTime ts;

}
