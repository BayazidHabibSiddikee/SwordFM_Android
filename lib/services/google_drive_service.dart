import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

/// Shared cloud file metadata used by Google Drive, Dropbox, and OpenDrive.
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

/// Google Drive service using [GoogleSignIn] + [drive.DriveApi].
class GoogleDriveService {
  static const _kClientIdKey = 'swordfm_gdrive_client_id';

  GoogleSignIn? _googleSignIn;
  drive.DriveApi? _driveApi;
  String? _clientId;
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  String? get savedClientId => _clientId;

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getString(_kClientIdKey);
  }

  Future<void> saveClientId(String clientId) async {
    _clientId = clientId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClientIdKey, clientId);
  }

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

      GoogleSignInAccount? account;
      try {
        account = await _googleSignIn!.signInSilently();
      } catch (_) {}
      account ??= await _googleSignIn!.signIn();
      if (account == null) return false;

      final auth = await account.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) return false;

      // Build authenticated HTTP client
      final client = _AuthHttpClient(accessToken);
      _driveApi = drive.DriveApi(client);
      _isConnected = true;
      return true;
    } catch (e) {
      debugPrint('Google Drive connect error: $e');
      _isConnected = false;
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _googleSignIn?.signOut();
    } catch (_) {}
    _driveApi = null;
    _isConnected = false;
  }

  Future<List<CloudFile>> listFolder({String? folderId}) async {
    if (_driveApi == null) return [];
    try {
      final q = folderId == null || folderId.isEmpty
          ? "'root' in parents and trashed = false"
          : "'$folderId' in parents and trashed = false";

      final result = await _driveApi!.files.list(
        q: q,
        $fields: 'files(id,name,mimeType,size,modifiedTime,parents)',
        orderBy: 'folder,name',
        pageSize: 200,
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
      debugPrint('GDrive listFolder error: $e');
      return [];
    }
  }

  Future<String?> getFolderIdFromPath(String path) async {
    if (_driveApi == null) return null;
    if (path == '/' || path.isEmpty) return 'root';

    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    String currentId = 'root';

    for (final part in parts) {
      final children = await listFolder(folderId: currentId);
      final match = children.where((f) => f.isDirectory && f.name == part).toList();
      if (match.isEmpty) return null;
      currentId = match.first.id;
    }
    return currentId;
  }

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
      debugPrint('GDrive createFolder error: $e');
      return null;
    }
  }

  Future<bool> delete(String fileId) async {
    if (_driveApi == null) return false;
    try {
      await _driveApi!.files.delete(fileId);
      return true;
    } catch (e) {
      debugPrint('GDrive delete error: $e');
      return false;
    }
  }

  Future<bool> rename(String fileId, String newName) async {
    if (_driveApi == null) return false;
    try {
      final update = drive.File()..name = newName;
      await _driveApi!.files.update(update, fileId);
      return true;
    } catch (e) {
      debugPrint('GDrive rename error: $e');
      return false;
    }
  }

  Future<String?> getDownloadUrl(String fileId) async {
    if (_driveApi == null) return null;
    try {
      final file = await _driveApi!.files.get(fileId) as drive.File;
      return file.webViewLink ?? file.webContentLink;
    } catch (e) {
      debugPrint('GDrive getDownloadUrl error: $e');
      return null;
    }
  }

  Future<CloudFile?> uploadBytes(Uint8List data, String remoteName, {String? parentFolderId}) async {
    if (_driveApi == null) return null;
    try {
      final file = drive.File()
        ..name = remoteName
        ..parents = [parentFolderId ?? 'root'];

      final media = drive.Media(
        Stream.fromIterable([data]),
        data.length,
        contentType: 'application/octet-stream',
      );
      final created = await _driveApi!.files.create(file, uploadMedia: media);
      return CloudFile(
        id: created.id ?? '',
        name: created.name ?? remoteName,
        isDirectory: false,
        size: int.tryParse(created.size ?? '0') ?? 0,
      );
    } catch (e) {
      debugPrint('GDrive uploadBytes error: $e');
      return null;
    }
  }

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
      debugPrint('GDrive storageQuota error: $e');
      return {};
    }
  }
}

/// Simple HTTP client that injects an Authorization header.
class _AuthHttpClient extends http.BaseClient {
  final String _token;
  final http.Client _inner = http.Client();

  _AuthHttpClient(this._token);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
