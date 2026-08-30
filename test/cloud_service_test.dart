import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/google_drive_service.dart';
import 'package:swordfm/services/dropbox_service.dart';
import 'package:swordfm/services/opendrive_service.dart';

void main() {
  group('CloudFile', () {
    test('constructs with required fields', () {
      final f = CloudFile(id: '1', name: 'doc.pdf', isDirectory: false);
      expect(f.id, '1');
      expect(f.name, 'doc.pdf');
      expect(f.isDirectory, false);
      expect(f.size, 0);
      expect(f.mimeType, 'application/octet-stream');
      expect(f.parentPath, isNull);
    });

    test('constructs with all optional fields', () {
      final now = DateTime.now();
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
      expect(f.mimeType, 'image/jpeg');
      expect(f.path, '/Photos/photo.jpg');
    });

    test('directory defaults to /name path', () {
      final f = CloudFile(id: '3', name: 'Docs', isDirectory: true);
      expect(f.path, '/Docs');
    });

    test('isDirectory flag works', () {
      final dir = CloudFile(id: '4', name: 'folder', isDirectory: true);
      final file = CloudFile(id: '5', name: 'file.txt', isDirectory: false);
      expect(dir.isDirectory, isTrue);
      expect(file.isDirectory, isFalse);
    });
  });

  group('DropboxService', () {
    late DropboxService service;

    setUp(() {
      service = DropboxService();
    });

    test('starts disconnected', () {
      expect(service.isConnected, false);
    });

    test('redirect URI is well-formed', () {
      expect(DropboxService.redirectUri, contains('://'));
      expect(DropboxService.redirectUri, contains('storagesfm'));
      expect(DropboxService.redirectUri, contains('dropbox'));
    });

    test('redirect scheme matches custom scheme', () {
      expect(DropboxService.redirectScheme, 'storagesfm');
    });

    test('connect returns false when no app key', () async {
      final ok = await service.connect();
      expect(ok, false);
    });
  });

  group('OpenDriveService', () {
    late OpenDriveService service;

    setUp(() {
      service = OpenDriveService();
    });

    test('starts disconnected', () {
      expect(service.isConnected, false);
    });

    test('savedApiKey is null initially', () {
      expect(service.savedApiKey, isNull);
    });

    test('connect returns false when no API key', () async {
      final ok = await service.connect();
      expect(ok, false);
    });
  });

  group('GoogleDriveService', () {
    late GoogleDriveService service;

    setUp(() {
      service = GoogleDriveService();
    });

    test('starts disconnected', () {
      expect(service.isConnected, false);
    });

    test('savedClientId is null initially', () {
      expect(service.savedClientId, isNull);
    });
  });
}
