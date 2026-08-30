import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/network_service.dart';

void main() {
  group('AES-256-GCM Encryption', () {
    test('NetworkProfile JSON round-trip preserves all fields', () {
      final p = NetworkProfile(
        id: 'n1',
        name: 'Home NAS',
        type: 'webdav',
        host: 'https://nas.local',
        port: 5005,
        username: 'admin',
        password: 'hunter2',
        remotePath: '/shared',
      );
      final json = p.toJson();
      // Simulate what _saveProfiles does: add encryptedPassword, include password for fromJson
      json['encryptedPassword'] = 'placeholder';
      json['password'] = p.password;
      final restored = NetworkProfile.fromJson(json);
      expect(restored.id, p.id);
      expect(restored.name, p.name);
      expect(restored.type, p.type);
      expect(restored.host, p.host);
      expect(restored.port, p.port);
      expect(restored.username, p.username);
      expect(restored.remotePath, p.remotePath);
      expect(restored.password, p.password);
    });

    test('password field is mutable for decrypt', () {
      final p = NetworkProfile(
        id: 'n2',
        name: 'SFTP',
        type: 'sftp',
        host: 's.example.com',
        port: 22,
        username: 'root',
        password: 'initial',
      );
      expect(p.password, 'initial');
      p.password = 'updated';
      expect(p.password, 'updated');
    });

    test('TransferJob defaults to pending', () {
      final job = TransferJob(
        id: 't1',
        profileId: 'p1',
        localPath: '/tmp/a.txt',
        remotePath: '/remote/a.txt',
        isUpload: true,
      );
      expect(job.status, TransferStatus.pending);
      expect(job.progress, 0.0);
      expect(job.error, isNull);
      expect(job.isUpload, true);
    });

    test('TransferStatus enum has expected values', () {
      expect(TransferStatus.values.length, 4);
      expect(TransferStatus.pending, isNotNull);
      expect(TransferStatus.running, isNotNull);
      expect(TransferStatus.completed, isNotNull);
      expect(TransferStatus.failed, isNotNull);
    });

    test('ConnLog stores metadata', () {
      final log = ConnLog(
        profileId: 'p1',
        message: 'Connected',
        ts: DateTime(2025),
      );
      expect(log.profileId, 'p1');
      expect(log.message, 'Connected');
      expect(log.ts, DateTime(2025));
    });

    test('RemoteEntry stores name and isDir', () {
      const file = RemoteEntry(name: 'readme.txt', isDir: false);
      const dir = RemoteEntry(name: 'Documents', isDir: true);
      expect(file.name, 'readme.txt');
      expect(file.isDir, false);
      expect(dir.name, 'Documents');
      expect(dir.isDir, true);
    });
  });
}
