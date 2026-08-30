import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cloud file metadata for the unified browser.
class CloudFile {
  final String id;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedTime;
  final String mimeType;
  final String? parentPath;

  const CloudFile({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.modifiedTime,
    this.mimeType = 'application/octet-stream',
    this.parentPath,
  });

  String get path => parentPath != null ? '$parentPath/$name' : '/$name';
}

/// Service for interacting with Google Drive.
class GoogleDriveService {
  static const _kClientIdKey = 'google_drive_client_id';
  static const _kTokenKey = 'google_drive_token';

  GoogleSignIn? _googleSignIn;
  drive.DriveApi? _driveApi;
  String? _clientId;
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  drive.DriveApi? get api => _driveApi;

  /// Load saved client ID from preferences.
  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getString(_kClientIdKey);
  }

  /// Save client ID to preferences.
  Future<void> saveClientId(String clientId) async {
    _clientId = clientId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClientIdKey, clientId);
  }

  String? get savedClientId => _clientId;

  /// Initialize Google Sign-In and attempt to connect.
  Future<bool> connect({String? clientId}) async {
    final id = clientId ?? _clientId;
    if (id == null || id.isEmpty) return false;

    try {
      _googleSignIn = GoogleSignIn(
        clientId: id,
        scopes: [
          drive.DriveApi.driveFileScope,
          drive.DriveApi.driveAppdataScope,
        ],
      );

      // Try silent sign-in first
      var account = await _googleSignIn!.signInSilently();
      account ??= await _googleSignIn!.signIn();

      if (account == null) return false;

      final auth = await account.authentication;
      final accessToken = auth.accessToken;

      if (accessToken == null) return false;

      // Save token for reconnection
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTokenKey, accessToken);

      final httpClient = await _googleSignIn!.authenticatedClient();
      _driveApi = drive.DriveApi(httpClient!);
      _isConnected = true;
      return true;
    } catch (e) {
      debugPrint('Google Drive connect error: $e');
      _isConnected = false;
      return false;
    }
  }

  /// Try to reconnect using saved token.
  Future<bool> reconnect() async {
    return connect();
  }

  /// Disconnect from Google Drive.
  Future<void> disconnect() async {
    await _googleSignIn?.signOut();
    _driveApi = null;
    _isConnected = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTokenKey);
  }

  /// List files in a folder. Pass null or empty for root.
  Future<List<CloudFile>> listFolder({String? folderId}) async {
    if (_driveApi == null) return [];

    try {
      String q;
      if (folderId == null || folderId.isEmpty) {
        q = "'root' in parents and trashed = false";
      } else {
        q = "'$folderId' in parents and trashed = false";
      }

      final result = await _driveApi!.files.list(
        q: q,
        $fields: 'files(id,name,mimeType,size,modifiedTime,parents)',
        orderBy: 'folder,name',
        pageSize: 100,
      );

      return (result.files ?? []).map((f) {
        final isDir = f.mimeType == 'application/vnd.google-apps.folder';
        return CloudFile(
          id: f.id ?? '',
          name: f.name ?? 'Unknown',
          isDirectory: isDir,
          size: int.tryParse(f.size ?? '0') ?? 0,
          modifiedTime: f.modifiedTime,
          mimeType: f.mimeType ?? 'application/octet-stream',
        );
      }).toList();
    } catch (e) {
      debugPrint('Google Drive listFolder error: $e');
      return [];
    }
  }

  /// Get folder ID from a path like "/Documents/Projects".
  Future<String?> getFolderIdFromPath(String path) async {
    if (_driveApi == null) return null;
    if (path == '/' || path.isEmpty) return 'root';

    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    String currentId = 'root';

    for (final part in parts) {
      final children = await listFolder(folderId: currentId);
      final match = children.where((f) => f.isDirectory && f.name == part);
      if (match.isEmpty) return null;
      currentId = match.first.id;
    }

    return currentId;
  }

  /// Create a folder.
  Future<String?> createFolder(String name, {String? parentFolderId}) async {
    if (_driveApi == null) return null;

    try {
      final folder = drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parentFolderId ?? 'root'];

      final created = await _driveApi!.files.create(folder);
      return created.id;
    } catch (e) {
      debugPrint('Google Drive createFolder error: $e');
      return null;
    }
  }

  /// Delete a file/folder.
  Future<bool> delete(String fileId) async {
    if (_driveApi == null) return false;

    try {
      await _driveApi!.files.delete(fileId);
      return true;
    } catch (e) {
      debugPrint('Google Drive delete error: $e');
      return false;
    }
  }

  /// Rename a file/folder.
  Future<bool> rename(String fileId, String newName) async {
    if (_driveApi == null) return false;

    try {
      final update = drive.File()..name = newName;
      await _driveApi!.files.update(update, fileId);
      return true;
    } catch (e) {
      debugPrint('Google Drive rename error: $e');
      return false;
    }
  }

  /// Get a web view link for a file.
  Future<String?> getDownloadUrl(String fileId) async {
    if (_driveApi == null) return null;

    try {
      final file = await _driveApi!.files.get(
        fileId,
      );
      if (file is drive.File) {
        return file.webViewLink ?? file.webContentLink;
      }
      return null;
    } catch (e) {
      debugPrint('Google Drive getDownloadUrl error: $e');
      return null;
    }
  }

  /// Get direct download content link.
  Future<String?> getContentLink(String fileId) async {
    if (_driveApi == null) return null;

    try {
      final result = await _driveApi!.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      );
      if (result is drive.Media) {
        return 'google_drive://$fileId';
      }
      return null;
    } catch (e) {
      debugPrint('Google Drive getContentLink error: $e');
      return null;
    }
  }

  /// Get storage quota info.
  Future<Map<String, int>> getStorageQuota() async {
    if (_driveApi == null) return {};

    try {
      final about = await _driveApi!.about.get($fields: 'user,storageQuota');
      final quota = about.storageQuota;
      return {
        'limit': int.tryParse(quota?.limit ?? '0') ?? 0,
        'usage': int.tryParse(quota?.usage ?? '0') ?? 0,
        'usageInDrive': int.tryParse(quota?.usageInDrive ?? '0') ?? 0,
      };
    } catch (e) {
      debugPrint('Google Drive storageQuota error: $e');
      return {};
    }
  }
}
