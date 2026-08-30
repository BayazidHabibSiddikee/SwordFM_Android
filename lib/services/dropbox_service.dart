import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'google_drive_service.dart' show CloudFile;

/// Dropbox service — direct REST API via Dio, no SDK dependency.
/// Uses OAuth2 flow initiated via external browser with a custom-scheme redirect.
class DropboxService {
  static const _kAppKeyKey = 'swordfm_dropbox_app_key';
  static const _kAppSecretKey = 'swordfm_dropbox_app_secret';
  static const _kAccessTokenKey = 'swordfm_dropbox_access_token';
  static const _kRefreshTokenKey = 'swordfm_dropbox_refresh_token';
  static const _kExpiryMsKey = 'swordfm_dropbox_token_expiry_ms';
  static const _kAccountInfoKey = 'swordfm_dropbox_account_info';

  /// Custom scheme for OAuth callback — must match AndroidManifest.xml intent-filter.
  static const String redirectScheme = 'storagesfm';
  static const String redirectHost = 'dropbox-callback';
  static String get redirectUri => '$redirectScheme://$redirectHost';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'https://api.dropboxapi.com/2',
    contentType: 'application/json',
  ));

  String? _appKey;
  String? _appSecret;
  String? _accessToken;
  String? _refreshToken;
  int? _tokenExpiryMs;
  Map<String, dynamic>? _accountInfo;
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  String? get savedAppKey => _appKey;
  String? get savedAppSecret => _appSecret;
  String? get accountEmail => _accountInfo?['email'] as String?;
  String? get accountName => _accountInfo?['display_name'] as String?;

  // ── Config persistence ───────────────────────────────────────────────

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _appKey = prefs.getString(_kAppKeyKey);
    _appSecret = prefs.getString(_kAppSecretKey);
    _accessToken = await _secureStorage.read(key: _kAccessTokenKey) ?? prefs.getString(_kAccessTokenKey);
    _refreshToken = await _secureStorage.read(key: _kRefreshTokenKey) ?? prefs.getString(_kRefreshTokenKey);
    final expiry = prefs.getInt(_kExpiryMsKey);
    if (expiry != null) _tokenExpiryMs = expiry;
    final acctJson = prefs.getString(_kAccountInfoKey);
    if (acctJson != null) {
      try {
        _accountInfo = json.decode(acctJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    if (_accessToken != null && _tokenExpiryMs != null) {
      if (DateTime.now().millisecondsSinceEpoch < _tokenExpiryMs!) {
        _isConnected = true;
      } else if (_refreshToken != null) {
        await _refreshAccessToken();
      }
    }
  }

  Future<void> saveConfig({required String appKey, required String appSecret}) async {
    _appKey = appKey;
    _appSecret = appSecret;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppKeyKey, appKey);
    await prefs.setString(_kAppSecretKey, appSecret);
  }

  Future<void> clearConfig() async {
    _appKey = null;
    _appSecret = null;
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiryMs = null;
    _isConnected = false;
    _accountInfo = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAppKeyKey);
    await prefs.remove(_kAppSecretKey);
    await prefs.remove(_kAccessTokenKey);
    await prefs.remove(_kRefreshTokenKey);
    await prefs.remove(_kExpiryMsKey);
    await prefs.remove(_kAccountInfoKey);
    await _secureStorage.delete(key: _kAccessTokenKey);
    await _secureStorage.delete(key: _kRefreshTokenKey);
  }

  // ── OAuth flow ───────────────────────────────────────────────────────

  /// Open Dropbox OAuth authorize page in an external browser.
  /// After approval the user is redirected to [redirectUri].
  Future<bool> connect() async {
    if (_appKey == null || _appKey!.isEmpty) return false;

    final state = _randomHex(16);
    try {
      final authUrl = Uri.parse(
        'https://www.dropbox.com/oauth2/authorize'
        '?client_id=$_appKey'
        '&response_type=code'
        '&token_access_type=offline'
        '&state=$state'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}',
      );

      if (await canLaunchUrl(authUrl)) {
        await launchUrl(authUrl, mode: LaunchMode.externalApplication);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Dropbox connect error: $e');
      return false;
    }
  }

  /// Called when the app receives the OAuth redirect URI.
  /// Parses the authorization code and exchanges it for tokens.
  Future<bool> handleRedirect(Uri uri) async {
    if (_appKey == null || _appSecret == null) return false;

    final error = uri.queryParameters['error'];
    if (error != null) {
      debugPrint('Dropbox OAuth error: $error — ${uri.queryParameters['error_description']}');
      return false;
    }

    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) return false;

    return _exchangeCode(code);
  }

  Future<bool> _exchangeCode(String code) async {
    try {
      final resp = await _dio.post(
        'https://api.dropbox.com/oauth2/token',
        data: FormData.fromMap({
          'code': code,
          'grant_type': 'authorization_code',
          'client_id': _appKey!,
          'client_secret': _appSecret!,
          'redirect_uri': redirectUri,
        }),
      );

      if (resp.statusCode != 200) {
        debugPrint('Dropbox token exchange failed: ${resp.data}');
        return false;
      }

      final data = resp.data as Map<String, dynamic>;
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String?;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 14400;
      _tokenExpiryMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
      _isConnected = true;

      await _persistTokens();
      return true;
    } catch (e) {
      debugPrint('Dropbox _exchangeCode error: $e');
      return false;
    }
  }

  Future<bool> _refreshAccessToken() async {
    if (_refreshToken == null || _appKey == null || _appSecret == null) return false;
    try {
      final resp = await _dio.post(
        'https://api.dropbox.com/oauth2/token',
        data: FormData.fromMap({
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
          'client_id': _appKey!,
          'client_secret': _appSecret!,
        }),
      );
      if (resp.statusCode != 200) return false;

      final data = resp.data as Map<String, dynamic>;
      _accessToken = data['access_token'] as String?;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 14400;
      _tokenExpiryMs = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
      _isConnected = true;
      await _persistTokens();
      return true;
    } catch (e) {
      debugPrint('Dropbox _refreshAccessToken error: $e');
      _isConnected = false;
      return false;
    }
  }

  Future<void> _persistTokens() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await _secureStorage.write(key: _kAccessTokenKey, value: _accessToken!);
      await prefs.setString(_kAccessTokenKey, _accessToken!);
    }
    if (_refreshToken != null) {
      await _secureStorage.write(key: _kRefreshTokenKey, value: _refreshToken!);
      await prefs.setString(_kRefreshTokenKey, _refreshToken!);
    }
    if (_tokenExpiryMs != null) {
      await prefs.setInt(_kExpiryMsKey, _tokenExpiryMs!);
    }
  }

  Future<bool> _ensureToken() async {
    if (_accessToken == null) return false;
    if (_tokenExpiryMs != null &&
        DateTime.now().millisecondsSinceEpoch >= _tokenExpiryMs!) {
      return await _refreshAccessToken();
    }
    return true;
  }

  // ── API helpers ──────────────────────────────────────────────────────

  Future<T?> _apiPost<T>(String endpoint, {Map<String, dynamic>? body}) async {
    if (!await _ensureToken()) return null;
    try {
      final resp = await _dio.post(
        '/$endpoint',
        data: body != null ? json.encode(body) : null,
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}),
      );
      if (resp.statusCode == 200) {
        return resp.data as T?;
      } else if (resp.statusCode == 401) {
        if (await _refreshAccessToken()) {
          return _apiPost<T>(endpoint, body: body);
        }
      }
      debugPrint('Dropbox API error ($endpoint): ${resp.statusCode} ${resp.data}');
      return null;
    } catch (e) {
      debugPrint('Dropbox _apiPost error: $e');
      return null;
    }
  }

  // ── Public file operations ───────────────────────────────────────────

  Future<List<CloudFile>> listFolder({String? path}) async {
    final folderPath = path ?? '';
    final result = await _apiPost<Map<String, dynamic>>(
      'files/list_folder',
      body: {
        'path': folderPath,
        'recursive': false,
        'include_media_info': true,
        'include_deleted': false,
        'include_hidden': false,
      },
    );
    if (result == null) return [];

    final entries = result['entries'] as List? ?? [];
    return entries.map((e) {
      final tag = e['.tag'] as String? ?? 'file';
      return CloudFile(
        id: e['id'] ?? '',
        name: e['name'] ?? 'Unknown',
        isDirectory: tag == 'folder',
        size: (e['size'] as num?)?.toInt() ?? 0,
        modifiedTime: e['server_modified'] != null
            ? DateTime.tryParse(e['server_modified'])
            : null,
        mimeType: tag == 'folder'
            ? 'application/directory'
            : (e['content_type'] as String? ?? 'application/octet-stream'),
        parentPath: folderPath.isEmpty ? '/' : folderPath,
      );
    }).toList();
  }

  Future<String?> createFolder(String name, {String parentPath = ''}) async {
    final fullPath = parentPath.isEmpty ? '/$name' : '$parentPath/$name';
    final result = await _apiPost<Map<String, dynamic>>(
      'files/create_folder_v2',
      body: {'path': fullPath},
    );
    if (result != null) {
      final metadata = result['metadata'] as Map<String, dynamic>?;
      return metadata?['path_display'] as String? ?? fullPath;
    }
    return null;
  }

  Future<bool> delete(String path) async {
    final result = await _apiPost('files/delete_v2', body: {'path': path});
    return result != null;
  }

  Future<bool> rename(String fromPath, String toPath) async {
    final result = await _apiPost(
      'files/move_v2',
      body: {
        'from_path': fromPath,
        'to_path': toPath,
        'allow_shared_folder': true,
        'autorename': false,
      },
    );
    return result != null;
  }

  Future<String?> getTemporaryLink(String path) async {
    final result = await _apiPost<Map<String, dynamic>>(
      'files/get_temporary_link',
      body: {'path': path},
    );
    return result?['link'] as String?;
  }

  Future<Map<String, dynamic>?> getAccountInfo() async {
    if (_accountInfo != null) return _accountInfo;
    final result = await _apiPost<Map<String, dynamic>>('users/get_current_account');
    if (result != null) {
      _accountInfo = result;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAccountInfoKey, json.encode(result));
    }
    return result;
  }

  Future<Map<String, dynamic>?> getSpaceUsage() async {
    return _apiPost<Map<String, dynamic>>('users/get_space_usage');
  }

  /// Upload local bytes to Dropbox at [remotePath] (must start with /).
  Future<CloudFile?> uploadFile(
    Uint8List data,
    String remotePath, {
    String mimeType = 'application/octet-stream',
  }) async {
    if (!await _ensureToken()) return null;
    try {
      final resp = await _dio.put(
        '/files/upload',
        data: data,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Dropbox-API-Arg': json.encode({'path': remotePath, 'mode': 'add'}),
          },
        ),
      );
      if (resp.statusCode == 200) {
        final metadata = resp.data as Map<String, dynamic>;
        final name = metadata['name'] as String? ?? remotePath.split('/').last;
        final parent = remotePath.contains('/')
            ? remotePath.substring(0, remotePath.lastIndexOf('/'))
            : '/';
        return CloudFile(
          id: metadata['id'] ?? '',
          name: name,
          isDirectory: false,
          size: (metadata['size'] as num?)?.toInt() ?? 0,
          modifiedTime: metadata['server_modified'] != null
              ? DateTime.tryParse(metadata['server_modified'])
              : null,
          mimeType: mimeType,
          parentPath: parent,
        );
      }
      return null;
    } catch (e) {
      debugPrint('Dropbox uploadFile error: $e');
      return null;
    }
  }

  /// Download file bytes from Dropbox at [path]. Returns null on failure.
  Future<Uint8List?> downloadBytes(String path) async {
    if (!await _ensureToken()) return null;
    try {
      final resp = await _dio.get(
        '/files/download',
        options: Options(
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Dropbox-API-Arg': json.encode({'path': path}),
          },
          responseType: ResponseType.bytes,
        ),
      );
      if (resp.statusCode == 200) return resp.data as Uint8List;
      return null;
    } catch (e) {
      debugPrint('Dropbox downloadBytes error: $e');
      return null;
    }
  }

  // ── Disconnect ───────────────────────────────────────────────────────

  Future<void> disconnect() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiryMs = null;
    _isConnected = false;
    _accountInfo = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccessTokenKey);
    await prefs.remove(_kRefreshTokenKey);
    await prefs.remove(_kExpiryMsKey);
    await prefs.remove(_kAccountInfoKey);
    await _secureStorage.delete(key: _kAccessTokenKey);
    await _secureStorage.delete(key: _kRefreshTokenKey);
  }

  static String _randomHex(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => DateTime.now().millisecond % 256);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
