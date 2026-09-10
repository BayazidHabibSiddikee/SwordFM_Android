import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/ftp_server_service.dart';

void main() {
  test('FTP server: unauthenticated mutating commands rejected', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dev.fluttercommunity.plus/network_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'wifiIPAddress') return '127.0.0.1';
      return null;
    });

    final root = Directory.systemTemp.createTempSync('ftp_auth_');
    File(p.join(root.path, 'hello.txt')).writeAsStringSync('hello\n');

    final srv = FtpServerService(port: 0);
    srv.sharePin = '123456';
    await srv.start(shareRootOverride: root.path);
    final socket = await Socket.connect('127.0.0.1', srv.boundPort);
    final buf = StringBuffer();
    socket.listen((d) => buf.write(String.fromCharCodes(d)));

    Future<String> readAll() async {
      await Future.delayed(const Duration(milliseconds: 200));
      final s = buf.toString();
      buf.clear();
      return s.trim();
    }

    Future<String> cmd(String c) async {
      socket.add('$c\r\n'.codeUnits);
      return readAll();
    }

    await Future.delayed(const Duration(milliseconds: 250));
    buf.clear();

    // No auth yet: filesystem commands must be refused.
    expect(await cmd('PWD'), contains('530'));
    expect(await cmd('SIZE hello.txt'), contains('530'));
    // Wrong PIN stays refused.
    expect(await cmd('PASS 000000'), contains('530'));
    expect(await cmd('PWD'), contains('530'));
    // Correct PIN unlocks.
    expect(await cmd('PASS 123456'), contains('230'));
    expect(await cmd('PWD'), contains('257'));
    expect(await cmd('SIZE hello.txt'), contains('213'));

    await cmd('QUIT');
    socket.close();
    await srv.stop();
    root.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
