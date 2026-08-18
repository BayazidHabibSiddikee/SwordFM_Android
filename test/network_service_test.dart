import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/network_service.dart';

void main() {
  group('NetworkProfile', () {
    test('creates with defaults', () {
      final p = NetworkProfile(
        id: '1',
        name: 'Test',
        type: 'webdav',
        host: 'example.com',
        port: 80,
        username: 'user',
        password: 'pass',
      );
      expect(p.id, '1');
      expect(p.name, 'Test');
      expect(p.type, 'webdav');
      expect(p.host, 'example.com');
      expect(p.port, 80);
      expect(p.username, 'user');
      expect(p.password, 'pass');
      expect(p.remotePath, '/');
      expect(p.isConnected, false);
    });

    test('fromJson round-trip', () {
      final json = {
        'id': '2',
        'name': 'MyServer',
        'type': 'sftp',
        'host': 'ssh.example.com',
        'port': 22,
        'username': 'admin',
        'password': 'secret',
        'remotePath': '/home/user',
      };
      final p = NetworkProfile.fromJson(json);
      expect(p.id, '2');
      expect(p.type, 'sftp');
      expect(p.port, 22);
      expect(p.remotePath, '/home/user');
      expect(p.toJson()['id'], '2');
    });
  });

  group('NetworkService', () {
    late NetworkService service;

    setUp(() {
      service = NetworkService();
    });

    test('add and retrieve profile', () {
      final p = NetworkProfile(
        id: 'a', name: 'A', type: 'webdav',
        host: 'h.com', port: 80, username: 'u', password: 'p',
      );
      service.addProfile(p);
      expect(service.hasProfile('a'), isTrue);
      expect(service.profiles['a'], p);
    });

    test('remove profile', () {
      final p = NetworkProfile(
        id: 'b', name: 'B', type: 'webdav',
        host: 'h.com', port: 80, username: 'u', password: 'p',
      );
      service.addProfile(p);
      service.removeProfile('b');
      expect(service.hasProfile('b'), isFalse);
    });

    test('logs connection events via getter', () {
      final before = service.logs.length;
      service.addLog('pid', 'Connecting...');
      expect(service.logs.length, before + 1);
      expect(service.logs.last.profileId, 'pid');
      expect(service.logs.last.message, 'Connecting...');
    });

    test('listDirectory throws for unknown profile', () async {
      expect(() => service.listDirectory('nonexistent'), throwsException);
    });

    test('uploadFile throws for unknown profile', () async {
      expect(() => service.uploadFile('nonexistent', '/tmp/x'), throwsException);
    });

    test('downloadFile throws for unknown profile', () async {
      expect(() => service.downloadFile('nonexistent', '/remote.txt', '/tmp'), throwsException);
    });
  });

  group('NetworkService TransferQueue', () {
    late NetworkService service;

    setUp(() {
      service = NetworkService();
    });

    test('enqueue adds job to queue', () {
      final id = service.enqueueTransfer(
        profileId: 'p1',
        localPath: '/tmp/a.txt',
        remotePath: '/remote/a.txt',
        isUpload: true,
      );
      expect(id.isNotEmpty, isTrue);
      expect(service.transferQueue.length, 1);
      expect(service.transferQueue.first.isUpload, isTrue);
    });

    test('isTransferring starts false', () {
      expect(service.isTransferring, isFalse);
    });

    test('cancel updates job status', () async {
      final id = service.enqueueTransfer(
        profileId: 'p1',
        localPath: '/tmp/x',
        remotePath: '/x',
        isUpload: true,
      );
      await service.cancelTransfer(id);
      final job = service.transferQueue.firstWhere(
        (j) => j.id == id,
        orElse: () => throw Exception('not found'),
      );
      expect(job.status, TransferStatus.failed);
      expect(job.error, 'Cancelled');
    });
  });
}
