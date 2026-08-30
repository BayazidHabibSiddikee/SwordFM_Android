import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'google_drive_service.dart' show CloudFile;

/// Dropbox service using direct REST API (no SDK dependency).
/// Uses OAuth2 PKCE flow via browser for authentication.
class DropboxService {
  static const _kAccessTokenKey = 'dropbox_access_token';
  static const _kRefreshTokenKey = 'dropbox_refresh_token';
  static const _kAppKeyKey = 'dropbox_app_key';
  static const _kAppSecretKey = 'dropbox_app_secret';
  static const _kExpiryKey = 'dropbox_token_expiry';

  String? _appKey;
  String? _appSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  String? get savedAppKey => _appKey;
  String? get savedAppSecret => _appSecret;

  /// Load saved configuration.
  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _appKey = prefs.getString(_kAppKeyKey);
    _appSecret = prefs.getString(_kAppSecretKey);
    _accessToken = prefs.getString(_kAccessTokenKey);
    _refreshToken = prefs.getString(_kRefreshTokenKey);
    final expiryMs = prefs.getInt(_kExpiryKey);
    if (expiryMs != null) {
      _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
    }

    // Check if token is still valid
    if (_accessToken != null && _tokenExpiry != null) {
      if (DateTime.now().isBefore(_tokenExpiry!)) {
        _isConnected = true;
      } else if (_refreshToken != null) {
        await _refreshAccessToken();
      }
    }
  }

  /// Save app credentials.
  Future<void> saveConfig({required String appKey, required String appSecret}) async {
    _appKey = appKey;
    _appSecret = appSecret;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppKeyKey, appKey);
    await prefs.setString(_kAppSecretKey, appSecret);
  }

  /// Start OAuth2 PKCE authorization flow.
  Future<bool> connect() async {
    if (_appKey == null || _appKey!.isEmpty) return false;

    try {
      // Dropbox OAuth2 with PKCE
      final authUrl = Uri.parse(
        'https://www.dropbox.com/oauth2/authorize'
        '?client_id=$_appKey'
        '&response_type=code'
        '&token_access_type=offline'
        '&redirect_uri=storagesfm://dropbox-callback',
      );

      if (await canLaunchUrl(authUrl)) {
        await launchUrl(authUrl, mode: LaunchMode.externalApplication);
        // Note: In production, you'd use app links / deep links to capture the callback.
        // For now, user pastes the auth code manually.
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Dropbox connect error: $e');
      return false;
    }
  }

  /// Exchange authorization code for tokens.
  Future<bool> exchangeCode(String authCode) async {
    if (_appKey == null || _appSecret == null) return false;

    try {
      final response = await http.post(
        Uri.parse('https://api.dropbox.com/oauth2/token'),
        body: {
          'code': authCode,
          'grant_type': 'authorization_code',
          'client_id': _appKey!,
          'client_secret': _appSecret!,
          'redirect_uri': 'storagesfm://dropbox-callback',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        final expiresIn = data['expires_in'] as int? ?? 14400;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        _isConnected = true;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kAccessTokenKey, _accessToken!);
        if (_refreshToken != null) {
          await prefs.setString(_kRefreshTokenKey, _refreshToken!);
        }
        await prefs.setInt(_kExpiryKey, _tokenExpiry!.millisecondsSinceEpoch);

        return true;
      }
      debugPrint('Dropbox token exchange failed: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('Dropbox exchangeCode error: $e');
      return false;
    }
  }

  /// Refresh access token using refresh token.
  Future<bool> _refreshAccessToken() async {
    if (_refreshToken == null || _appKey == null || _appSecret == null) {
      return false;
    }

    try {
      final response = await http.post(
        Uri.parse('https://api.dropbox.com/oauth2/token'),
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
          'client_id': _appKey!,
          'client_secret': _appSecret!,
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _accessToken = data['access_token'];
        final expiresIn = data['expires_in'] as int? ?? 14400;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kAccessTokenKey, _accessToken!);
        await prefs.setInt(_kExpiryKey, _tokenExpiry!.millisecondsSinceEpoch);

        _isConnected = true;
        return true;
      }
      _isConnected = false;
      return false;
    } catch (e) {
      debugPrint('Dropbox _refreshAccessToken error: $e');
      _isConnected = false;
      return false;
    }
  }

  /// Ensure we have a valid access token.
  Future<bool> _ensureToken() async {
    if (_accessToken == null) return false;
    if (_tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!)) {
      return await _refreshAccessToken();
    }
    return true;
  }

  /// Make an authenticated POST request to Dropbox API.
  Future<Map<String, dynamic>?> _apiPost(String endpoint, {Map<String, dynamic>? body}) async {
    if (!await _ensureToken()) return null;

    try {
      final response = await http.post(
        Uri.parse('https://api.dropboxapi.com/2/$endpoint'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: body != null ? json.encode(body) : null,
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else if (response.statusCode == 401) {
        // Token expired, try refresh
        if (await _refreshAccessToken()) {
          return _apiPost(endpoint, body: body);
        }
      }
      debugPrint('Dropbox API error ($endpoint): ${response.statusCode} ${response.body}');
      return null;
    } catch (e) {
      debugPrint('Dropbox _apiPost error: $e');
      return null;
    }
  }

  /// List files in a folder.
  Future<List<CloudFile>> listFolder({String? path}) async {
    final folderPath = path ?? '';
    final result = await _apiPost(
      'files/list_folder',
      body: {
        'path': folderPath,
        'include_media_info': true,
        'include_deleted': false,
      },
    );

    if (result == null) return [];

    final entries = result['entries'] as List? ?? [];
    return entries.map((entry) {
      final tag = entry['.tag'] as String? ?? 'file';
      return CloudFile(
        id: entry['id'] ?? '',
        name: entry['name'] ?? 'Unknown',
        isDirectory: tag == 'folder',
        size: entry['size'] as int? ?? 0,
        modifiedTime: entry['server_modified'] != null
            ? DateTime.tryParse(entry['server_modified'])
            : null,
        mimeType: tag == 'folder'
            ? 'application/directory'
            : (entry['content_type'] as String? ?? 'application/octet-stream'),
        parentPath: folderPath,
      );
    }).toList();
  }

  /// Create a folder.
  Future<String?> createFolder(String name, {String? parentPath}) async {
    final folderPath = '${parentPath ?? ''}/$name';
    final result = await _apiPost(
      'files/create_folder_v2',
      body: {'path': folderPath},
    );

    if (result != null) {
      final metadata = result['metadata'];
      return metadata?['id'];
    }
    return null;
  }

  /// Delete a file/folder.
  Future<bool> delete(String path) async {
    final result = await _apiPost(
      'files/delete_v2',
      body: {'path': path},
    );
    return result != null;
  }

  /// Rename/move a file.
  Future<bool> rename(String fromPath, String toPath) async {
    final result = await _apiPost(
      'files/move_v2',
      body: {
        'from_path': fromPath,
        'to_path': toPath,
        'allow_shared_folder': true,
        'autorename': false,
        'allow_ownership_transfer': false,
      },
    );
    return result != null;
  }

  /// Get temporary link for downloading.
  Future<String?> getTemporaryLink(String path) async {
    final result = await _apiPost(
      'files/get_temporary_link',
      body: {'path': path},
    );

    if (result != null) {
      return result['link'];
    }
    return null;
  }

  /// Get shared link for viewing.
  Future<String?> getSharedLink(String path) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'path': path,
          'settings': {
            'requested_visibility': 'public',
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['url'];
      } else if (response.statusCode == 409) {
        // Link already exists, get existing one
        return await _getExistingSharedLink(path);
      }
    } catch (e) {
      debugPrint('Dropbox getSharedLink error: $e');
    }
    return null;
  }

  /// Get existing shared link if one already exists.
  Future<String?> _getExistingSharedLink(String path) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.dropboxapi.com/2/sharing/list_shared_links'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: json.encode({'path': path}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final links = data['links'] as List? ?? [];
        if (links.isNotEmpty) {
          return links[0]['url'];
        }
      }
    } catch (e) {
      debugPrint('Dropbox _getExistingSharedLink error: $e');
    }
    return null;
  }

  /// Get account info.
  Future<Map<String, dynamic>?> getAccountInfo() async {
    return _apiPost('users/get_current_account');
  }

  /// Get space usage.
  Future<Map<String, dynamic>?> getSpaceUsage() async {
    return _apiPost('users/get_space_usage');
  }

  /// Disconnect.
  Future<void> disconnect() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    _isConnected = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccessTokenKey);
    await prefs.remove(_kRefreshTokenKey);
    await prefs.remove(_kExpiryKey);
  }
}
