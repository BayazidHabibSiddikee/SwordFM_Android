import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/web_share_server.dart';

/// TLS tests for WebShareServer in their own file: enabling the
/// TestWidgetsFlutterBinding (needed to mock path_provider) installs a fake
/// HttpClient that answers every request with 400 — which would break the
/// live-HTTP group in web_share_server_test.dart if these lived together.
/// Here we undo the override so real loopback TLS handshakes happen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory certDir;

  setUp(() async {
    certDir = await Directory.systemTemp.createTemp('share_tls_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return certDir.path;
        }
        return null;
      },
    );
    // Real HTTP/TLS, not the test binding's 400-always stub client.
    HttpOverrides.global = null;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (certDir.existsSync()) certDir.deleteSync(recursive: true);
  });

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<WebShareServer> bootTls(String shareRoot, int port) async {
    final server = WebShareServer(
      port: port,
      wifiIpResolver: () async => '127.0.0.1',
    );
    final ip = await server.start(
      shareRootOverride: shareRoot,
      useTls: true,
    );
    if (ip == null) fail('TLS start() returned null.');
    addTearDown(server.stop);
    return server;
  }

  test('TLS start advertises https scheme and serves PIN auth', () async {
    final dir = await Directory.systemTemp.createTemp('share_tls_root_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final server = await bootTls(dir.path, await freePort());
    expect(server.useTls, isTrue);
    expect(server.scheme, 'https');
    expect(server.shareUrl, startsWith('https://127.0.0.1:'));

    final http = HttpClient()
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      // Unauthenticated listing is still 401 over TLS.
      final unauth = await http.getUrl(
        Uri.parse('${server.shareUrl}/api/list'),
      );
      final unauthRes = await unauth.close();
      expect(unauthRes.statusCode, 401);
      await unauthRes.drain();

      // PIN auth works over the encrypted channel.
      final authReq = await http.postUrl(
        Uri.parse('${server.shareUrl}/api/auth'),
      );
      authReq.headers.contentType = ContentType.json;
      authReq.write(jsonEncode({'pin': server.pin}));
      final authRes = await authReq.close();
      expect(authRes.statusCode, 200);
      await authRes.drain();
    } finally {
      http.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('TLS setup failure falls back to plain HTTP, never refuses to start',
      () async {
    // Make cert storage fail: point the support dir at a plain file.
    final blocker = File('${certDir.path}/blocker')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return blocker.path;
        }
        return null;
      },
    );
    final dir = await Directory.systemTemp.createTemp('share_tls_fb_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final server = WebShareServer(
      port: await freePort(),
      wifiIpResolver: () async => '127.0.0.1',
    );
    final ip = await server.start(
      shareRootOverride: dir.path,
      useTls: true,
    );
    addTearDown(server.stop);
    expect(ip, isNotNull);
    expect(server.isRunning, isTrue);
    expect(server.useTls, isFalse);
    expect(server.scheme, 'http');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
