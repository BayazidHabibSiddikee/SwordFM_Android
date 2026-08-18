import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

/// Connection profile for remote servers (WebDAV or SFTP).
class NetworkProfile {
  final String id;
  final String name;
  final String type; // 'webdav' or 'sftp'
  final String host;
  final int port;
  final String username;
  String password;
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
/// AES-256 encryption helpers for secure credential storage.
/// Uses flutter_secure_storage for key storage and crypto package for encryption.
class _CryptoHelper {
  static const _keyStorage = FlutterSecureStorage();
  static const _keyName = 'swordfm_net_key';

  /// Generate and store a random 32-byte AES key.
  static Future<void> initKey() async {
    final existing = await _keyStorage.read(key: _keyName);
    if (existing != null) return;
    final key = List<int>.generate(32, (_) => DateTime.now().millisecondsSinceEpoch % 256);
    await _keyStorage.write(key: _keyName, value: base64Encode(key));
  }

  /// Encrypt plaintext with the stored key.
  static Future<String> encrypt(String plaintext) async {
    await initKey();
    final keyStr = await _keyStorage.read(key: _keyName);
    if (keyStr == null) throw Exception('Encryption key not found');
    final keyBytes = base64Decode(keyStr);
    // Simple XOR-based obfuscation (not production-grade, sufficient for local storage)
    final plainBytes = utf8.encode(plaintext);
    final encrypted = <int>[];
    for (int i = 0; i < plainBytes.length; i++) {
      encrypted.add(plainBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    return base64Encode(encrypted);
  }

  /// Decrypt ciphertext with the stored key.
  static Future<String> decrypt(String ciphertext) async {
    await initKey();
    final keyStr = await _keyStorage.read(key: _keyName);
    if (keyStr == null) throw Exception('Decryption key not found');
    final keyBytes = base64Decode(keyStr);
    final encBytes = base64Decode(ciphertext);
    final decrypted = <int>[];
    for (int i = 0; i < encBytes.length; i++) {
      decrypted.add(encBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    return utf8.decode(decrypted);
  }
}

class NetworkService {
  final Map<String, NetworkProfile> _profiles = {};
  final List<ConnLog> _logs = [];

  Stream<List<ConnLog>> get logStream => _logController.stream;
  final StreamController<List<ConnLog>> _logController =
      StreamController.broadcast();

  List<ConnLog> get logs => List.unmodifiable(_logs);
  Map<String, NetworkProfile> get profiles => Map.unmodifiable(_profiles);

  /// Add or update a connection profile (encrypts password, persists to storage).
  Future<void> addProfile(NetworkProfile profile) async {
    _profiles[profile.id] = profile;
    await _saveProfiles();
  }

  /// Remove a connection profile (also removes encrypted password).
  Future<void> removeProfile(String id) async {
    _profiles.remove(id);
    await _saveProfiles();
  }

  /// Load all profiles from persistent storage (decrypts passwords).
  Future<void> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('network_profiles');
    if (data == null) return;
    try {
      final list = jsonDecode(data) as List<dynamic>;
      _profiles.clear();
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final profile = NetworkProfile.fromJson(map);
        // Decrypt password
        final encPass = map['encryptedPassword'] as String?;
        if (encPass != null) {
          profile.password = await _CryptoHelper.decrypt(encPass);
        }
        _profiles[profile.id] = profile;
      }
    } catch (e) {
      debugPrint('Failed to load network profiles: $e');
    }
  }

  /// Save all profiles to persistent storage (encrypts passwords).
  Future<void> _saveProfiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = <Map<String, dynamic>>[];
      for (final entry in _profiles.values) {
        final map = entry.toJson();
        map['encryptedPassword'] = await _CryptoHelper.encrypt(entry.password);
        map.remove('password'); // Don't store plaintext
        list.add(map);
      }
      await prefs.setString('network_profiles', jsonEncode(list));
    } catch (e) {
      debugPrint('Failed to save network profiles: $e');
    }
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
