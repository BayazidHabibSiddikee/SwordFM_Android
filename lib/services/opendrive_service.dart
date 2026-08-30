import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'google_drive_service.dart' show CloudFile;

/// OpenDrive cloud storage service using REST API.
class OpenDriveService {
  static const _kAccessTokenKey = 'opendrive_access_token';
  static const _kRefreshTokenKey = 'opendrive_refresh_token';
  static const _kApiKeyKey = 'opendrive_api_key';
  static const _kExpiryKey = 'opendrive_token_expiry';
  static const _kBaseUrl = 'https://dev.openrazer.com/api';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  String? _apiKey;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  String? get savedApiKey => _apiKey;

  /// Load saved config.
  Future<void> loadConfig() async {
    _apiKey = await _secureStorage.read(key: _kApiKeyKey);
    _accessToken = await _secureStorage.read(key: _kAccessTokenKey);
    _refreshToken = await _secureStorage.read(key: _kRefreshTokenKey);
    final expiryMs = await _secureStorage.read(key: _kExpiryKey);
    if (expiryMs != null) {
      _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(int.parse(expiryMs));
    }

    if (_accessToken != null && _tokenExpiry != null) {
      if (DateTime.now().isBefore(_tokenExpiry!)) {
        _isConnected = true;
      } else if (_refreshToken != null) {
        await _refreshAccessToken();
      }
    }
  }

  /// Save API key.
  Future<void> saveApiKey(String apiKey) async {
    _apiKey = apiKey;
    await _secureStorage.write(key: _kApiKeyKey, value: apiKey);
  }

  /// Connect using OAuth2 with API key.
  Future<bool> connect({String? apiKey}) async {
    final key = apiKey ?? _apiKey;
    if (key == null || key.isEmpty) return false;

    try {
      // OpenDrive uses OAuth2 with client credentials or authorization code
      final authUrl = Uri.parse(
        'https://dev.openrazer.com/oauth2/authorize'
        '?client_id=$key'
        '&response_type=code'
        '&redirect_uri=storagesfm://opendrive-callback',
      );

      if (await canLaunchUrl(authUrl)) {
        await launchUrl(authUrl, mode: LaunchMode.externalApplication);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('OpenDrive connect error: $e');
      return false;
    }
  }

  /// Exchange auth code for tokens.
  Future<bool> exchangeCode(String authCode) async {
    if (_apiKey == null) return false;

    try {
      final response = await http.post(
        Uri.parse('https://dev.openrazer.com/oauth2/token'),
        body: {
          'code': authCode,
          'grant_type': 'authorization_code',
          'client_id': _apiKey!,
          'redirect_uri': 'storagesfm://opendrive-callback',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        final expiresIn = data['expires_in'] as int? ?? 3600;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        _isConnected = true;

        await _secureStorage.write(key: _kAccessTokenKey, value: _accessToken!);
        if (_refreshToken != null) {
          await _secureStorage.write(key: _kRefreshTokenKey, value: _refreshToken!);
        }
        await _secureStorage.write(key: _kExpiryKey, value: _tokenExpiry!.millisecondsSinceEpoch.toString());
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('OpenDrive exchangeCode error: $e');
      return false;
    }
  }

  /// Refresh access token.
  Future<bool> _refreshAccessToken() async {
    if (_refreshToken == null || _apiKey == null) return false;

    try {
      final response = await http.post(
        Uri.parse('https://dev.openrazer.com/oauth2/token'),
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
          'client_id': _apiKey!,
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _accessToken = data['access_token'];
        final expiresIn = data['expires_in'] as int? ?? 3600;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

        await _secureStorage.write(key: _kAccessTokenKey, value: _accessToken!);
        await _secureStorage.write(key: _kExpiryKey, value: _tokenExpiry!.millisecondsSinceEpoch.toString());
        _isConnected = true;
        return true;
      }
      _isConnected = false;
      return false;
    } catch (e) {
      _isConnected = false;
      return false;
    }
  }

  /// Ensure valid token.
  Future<bool> _ensureToken() async {
    if (_accessToken == null) return false;
    if (_tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!)) {
      return await _refreshAccessToken();
    }
    return true;
  }

  /// List files in a folder.
  Future<List<CloudFile>> listFolder({String? folderId}) async {
    if (!await _ensureToken()) return [];

    try {
      final uri = folderId != null
          ? Uri.parse('https://dev.openrazer.com/api/2/files?folder_id=$folderId')
          : Uri.parse('https://dev.openrazer.com/api/2/files');

      final response = await http.get(uri, headers: {
        'Authorization': 'Bearer $_accessToken',
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final files = data['files'] as List? ?? [];
        return files.map((f) => CloudFile(
          id: f['id'] ?? '',
          name: f['name'] ?? 'Unknown',
          isDirectory: f['is_folder'] == true,
          size: f['size'] as int? ?? 0,
          modifiedTime: f['modified_at'] != null ? DateTime.tryParse(f['modified_at']) : null,
          mimeType: f['content_type'] ?? 'application/octet-stream',
        )).toList();
      }
      return [];
    } catch (e) {
      debugPrint('OpenDrive listFolder error: $e');
      return [];
    }
  }

  /// Create a folder.
  Future<String?> createFolder(String name, {String? parentFolderId}) async {
    if (!await _ensureToken()) return null;

    try {
      final response = await http.post(
        Uri.parse('https://dev.openrazer.com/api/2/files/folder'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'name': name,
          if (parentFolderId != null) 'parent_id': parentFolderId,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        return data['id'];
      }
      return null;
    } catch (e) {
      debugPrint('OpenDrive createFolder error: $e');
      return null;
    }
  }

  /// Delete a file/folder.
  Future<bool> delete(String fileId) async {
    if (!await _ensureToken()) return false;

    try {
      final response = await http.delete(
        Uri.parse('https://dev.openrazer.com/api/2/files/$fileId'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      debugPrint('OpenDrive delete error: $e');
      return false;
    }
  }

  /// Rename a file.
  Future<bool> rename(String fileId, String newName) async {
    if (!await _ensureToken()) return false;

    try {
      final response = await http.put(
        Uri.parse('https://dev.openrazer.com/api/2/files/$fileId'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: json.encode({'name': newName}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('OpenDrive rename error: $e');
      return false;
    }
  }

  /// Get download URL.
  Future<String?> getDownloadUrl(String fileId) async {
    if (!await _ensureToken()) return null;

    try {
      final response = await http.get(
        Uri.parse('https://dev.openrazer.com/api/2/files/$fileId/download'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['url'];
      }
      return null;
    } catch (e) {
      debugPrint('OpenDrive getDownloadUrl error: $e');
      return null;
    }
  }

  /// Upload a local file to OpenDrive.
  Future<CloudFile?> uploadFile(String localPath, String remoteName) async {
    if (!await _ensureToken()) return null;

    try {
      final file = File(localPath);
      final bytes = await file.readAsBytes();
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://dev.openrazer.com/api/2/files/upload'),
      );
      request.headers['Authorization'] = 'Bearer $_accessToken';
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: remoteName));

      final response = await request.send();
      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = await response.stream.bytesToString();
        final data = json.decode(body);
        return CloudFile(
          id: data['id'] ?? '',
          name: data['name'] ?? remoteName,
          isDirectory: false,
          size: data['size'] as int? ?? bytes.length,
        );
      }
      return null;
    } catch (e) {
      debugPrint('OpenDrive uploadFile error: $e');
      return null;
    }
  }

  /// Disconnect.
  Future<void> disconnect() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    _isConnected = false;
    await _secureStorage.delete(key: _kAccessTokenKey);
    await _secureStorage.delete(key: _kRefreshTokenKey);
    await _secureStorage.delete(key: _kExpiryKey);
  }
}
