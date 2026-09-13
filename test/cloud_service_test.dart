// Tests for the cloud storage clients.
//
// DropboxService is driven through a fake Dio HttpClientAdapter, so the real
// request-building, JSON decoding, pagination and error-mapping code runs.
// OpenDrive / GoogleDrive are exercised through their public API.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/dropbox_service.dart';
import 'package:swordfm/services/google_drive_service.dart';
import 'package:swordfm/services/opendrive_service.dart';

/// Serves canned responses for the Dropbox API and records each request.
class _FakeDropboxAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// Responses keyed by request path (e.g. `/files/list_folder`).
  final Map<String, ResponseBody Function(RequestOptions)> routes = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final handler = routes[options.path];
    if (handler != null) return handler(options);
    return _json(const <String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudFile', () {
    test('constructs with required fields and sensible defaults', () {
      final f = CloudFile(id: '1', name: 'doc.pdf', isDirectory: false);
      expect(f.id, '1');
      expect(f.name, 'doc.pdf');
      expect(f.isDirectory, false);
      expect(f.size, 0);
      expect(f.mimeType, 'application/octet-stream');
      expect(f.parentPath, isNull);
      expect(f.path, '/doc.pdf');
    });

    test('path joins parentPath and name', () {
      final now = DateTime(2024, 1, 1);
      final f = CloudFile(
        id: '2',
        name: 'photo.jpg',
        isDirectory: false,
        size: 1024,
        modifiedTime: now,
        mimeType: 'image/jpeg',
        parentPath: '/Photos',
      );
      expect(f.size, 1024);
      expect(f.modifiedTime, now);
      expect(f.path, '/Photos/photo.jpg');
    });

    test('an empty parentPath still yields a rooted path', () {
      final f = CloudFile(
        id: '3',
        name: 'x.bin',
        isDirectory: false,
        parentPath: '',
      );
      expect(f.path, '/x.bin');
    });
  });

  group('DropboxService', () {
    late DropboxService service;
    late _FakeDropboxAdapter adapter;

    setUp(() {
      service = DropboxService();
      adapter = _FakeDropboxAdapter();
      service.httpClientAdapter = adapter;
    });

    test('starts disconnected with no credentials', () {
      expect(service.isConnected, false);
      expect(service.savedAppKey, isNull);
      expect(service.savedAppSecret, isNull);
      expect(service.accountEmail, isNull);
      expect(service.accountName, isNull);
    });

    test('redirect URI is a well-formed custom scheme', () {
      expect(DropboxService.redirectUri, 'storagesfm://dropbox-callback');
      expect(DropboxService.redirectScheme, 'storagesfm');
      expect(DropboxService.redirectHost, 'dropbox-callback');
    });

    test('connect returns false without an app key and makes no request',
        () async {
      expect(await service.connect(), false);
      expect(adapter.requests, isEmpty);
    });

    test('listFolder returns empty when there is no access token', () async {
      expect(await service.listFolder(), isEmpty);
    });

    test('handleRedirect rejects an OAuth error response', () async {
      final ok = await service.handleRedirect(
        Uri.parse('storagesfm://dropbox-callback?error=access_denied'),
      );
      expect(ok, false);
      expect(adapter.requests, isEmpty);
    });

    test('handleRedirect rejects a missing code', () async {
      final ok = await service.handleRedirect(
        Uri.parse('storagesfm://dropbox-callback'),
      );
      expect(ok, false);
      expect(adapter.requests, isEmpty);
    });

    test('handleRedirect returns false without app credentials', () async {
      // No loadConfig()/saveConfig() has run, so appKey/appSecret are null.
      final ok = await service.handleRedirect(
        Uri.parse('storagesfm://dropbox-callback?code=abc'),
      );
      expect(ok, false);
      expect(adapter.requests, isEmpty);
    });

    test('an API failure maps to an empty list rather than throwing',
        () async {
      expect(await service.listFolder(), isEmpty);
    });

    test('getTemporaryLink returns null when unauthenticated', () async {
      expect(await service.getTemporaryLink('/x'), isNull);
    });

    test('delete and rename report false when unauthenticated', () async {
      expect(await service.delete('/x'), false);
      expect(await service.rename('/a', '/b'), false);
    });

    // ---- authenticated paths (secure storage mocked) ----------------------

    group('with stored credentials', () {
      const storageChannel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      setUp(() {
        // Seed FlutterSecureStorage so that loadConfig() populates the token
        // AND a future expiry, which is what makes _ensureToken() succeed.
        final futureMs = DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch
            .toString();
        messenger.setMockMethodCallHandler(storageChannel, (call) async {
          final key = (call.arguments as Map?)?['key'] as String?;
          switch (call.method) {
            case 'read':
              return switch (key) {
                'swordfm_dropbox_access_token' => 'tok-123',
                'swordfm_dropbox_refresh_token' => 'ref-456',
                'swordfm_dropbox_token_expiry_ms' => futureMs,
                _ => null,
              };
            case 'readAll':
              return <String, String>{
                'swordfm_dropbox_access_token': 'tok-123',
                'swordfm_dropbox_refresh_token': 'ref-456',
                'swordfm_dropbox_token_expiry_ms': futureMs,
              };
            case 'write':
            case 'delete':
            case 'deleteAll':
              return null;
            case 'containsKey':
              return true;
          }
          return null;
        });
      });

      tearDown(() {
        messenger.setMockMethodCallHandler(storageChannel, null);
      });

      test('loadConfig restores a non-expired session', () async {
        await service.loadConfig();
        expect(service.isConnected, isTrue);
      });

      test('listFolder decodes entries from the Dropbox response', () async {
        adapter.routes['/files/list_folder'] = (_) => _json({
              'entries': [
                {
                  '.tag': 'file',
                  'id': 'id:1',
                  'name': 'report.pdf',
                  'size': 2048,
                  'server_modified': '2024-03-01T10:00:00Z',
                  'content_type': 'application/pdf',
                },
                {
                  '.tag': 'folder',
                  'id': 'id:2',
                  'name': 'Archive',
                },
              ],
            });

        await service.loadConfig();
        final files = await service.listFolder();

        // The request must have actually gone out through the fake adapter.
        expect(adapter.requests, isNotEmpty);
        expect(adapter.requests.last.path, '/files/list_folder');

        expect(files, hasLength(2));
        expect(files[0].name, 'report.pdf');
        expect(files[0].isDirectory, isFalse);
        expect(files[0].size, 2048);
        expect(files[0].mimeType, 'application/pdf');
        expect(files[0].modifiedTime, DateTime.parse('2024-03-01T10:00:00Z'));
        expect(files[1].name, 'Archive');
        expect(files[1].isDirectory, isTrue);
        // Folders must be tagged as directories, not binary files.
        expect(files[1].mimeType, 'application/directory');
      });

      test('listFolder normalises a missing content_type', () async {
        adapter.routes['/files/list_folder'] = (_) => _json({
              'entries': [
                {'.tag': 'file', 'id': 'x', 'name': 'nameless'},
              ],
            });
        await service.loadConfig();
        final files = await service.listFolder();
        expect(files.single.mimeType, 'application/octet-stream');
        expect(files.single.size, 0);
        expect(files.single.modifiedTime, isNull);
      });

      test('an HTTP error yields an empty list instead of throwing', () async {
        adapter.routes['/files/list_folder'] =
            (_) => _json({'error_summary': 'not_found'}, 409);
        await service.loadConfig();
        expect(await service.listFolder(), isEmpty);
      });

      test('getTemporaryLink extracts the link field', () async {
        adapter.routes['/files/get_temporary_link'] =
            (_) => _json({'link': 'https://dl.example/x'});
        await service.loadConfig();
        expect(await service.getTemporaryLink('/x'), 'https://dl.example/x');
      });

      test('delete returns true on a 200 response', () async {
        adapter.routes['/files/delete_v2'] = (_) => _json({'metadata': {}});
        await service.loadConfig();
        expect(await service.delete('/x'), isTrue);
      });

      test('rename returns true on a 200 response', () async {
        adapter.routes['/files/move_v2'] = (_) => _json({'metadata': {}});
        await service.loadConfig();
        expect(await service.rename('/a', '/b'), isTrue);
      });

      test('getAccountInfo caches the account payload', () async {
        adapter.routes['/users/get_current_account'] = (_) => _json({
              'email': 'a@b.c',
              'display_name': 'Ada',
            });
        await service.loadConfig();
        final info = await service.getAccountInfo();
        expect(info?['email'], 'a@b.c');
        expect(service.accountEmail, 'a@b.c');
        expect(service.accountName, 'Ada');

        // Second call must be served from cache — no extra HTTP request.
        final before = adapter.requests.length;
        await service.getAccountInfo();
        expect(adapter.requests.length, before);
      });
    });
  });

  group('OpenDriveService', () {
    late OpenDriveService service;

    setUp(() {
      service = OpenDriveService();
    });

    test('starts disconnected with no API key', () {
      expect(service.isConnected, false);
      expect(service.savedApiKey, isNull);
    });

    test('connect returns false when no API key is available', () async {
      expect(await service.connect(), false);
    });

    test('exchangeCode returns false without stored credentials', () async {
      expect(await service.exchangeCode('abc'), false);
    });

    test('listFolder returns empty without a token', () async {
      expect(await service.listFolder(), isEmpty);
    });

    test('getDownloadUrl returns null without a token', () async {
      expect(await service.getDownloadUrl('1'), isNull);
    });

    test('delete returns false without a token', () async {
      expect(await service.delete('1'), false);
    });
  });

  group('GoogleDriveService', () {
    late GoogleDriveService service;

    setUp(() {
      service = GoogleDriveService();
    });

    test('starts disconnected with no client id', () {
      expect(service.isConnected, false);
      expect(service.savedClientId, isNull);
    });

    test('connect returns false when no client id is available', () async {
      expect(await service.connect(), false);
    });

    test('listFolder returns empty when not connected', () async {
      expect(await service.listFolder(), isEmpty);
    });
  });
}
