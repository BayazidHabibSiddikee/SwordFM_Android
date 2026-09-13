import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/tls_cert_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tls_cert_');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('generates and persists a cert + key pair', () async {
    final context = await TlsCertService.contextForIp('192.168.1.5');
    expect(context, isA<SecurityContext>());
    expect(File('${tmp.path}/swordfm_share_cert.pem').existsSync(), isTrue);
    expect(File('${tmp.path}/swordfm_share_key.pem').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('second call reuses the persisted cert', () async {
    await TlsCertService.contextForIp('192.168.1.5');
    final certFile = File('${tmp.path}/swordfm_share_cert.pem');
    final first = certFile.readAsStringSync();
    await TlsCertService.contextForIp('192.168.1.6');
    expect(certFile.readAsStringSync(), first);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('fingerprint is a hex SHA-256 string', () async {
    expect(await TlsCertService.fingerprint(), isNull);
    await TlsCertService.contextForIp('192.168.1.5');
    final fp = await TlsCertService.fingerprint();
    expect(fp, isNotNull);
    final bare = fp!.replaceAll(':', '');
    expect(
      RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(bare),
      isTrue,
      reason: 'fingerprint should be hex SHA-256, got $fp',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('rotate deletes the identity', () async {
    await TlsCertService.contextForIp('192.168.1.5');
    await TlsCertService.rotate();
    expect(File('${tmp.path}/swordfm_share_cert.pem').existsSync(), isFalse);
    expect(await TlsCertService.fingerprint(), isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
