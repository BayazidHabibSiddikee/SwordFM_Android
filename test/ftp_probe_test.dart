import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/ftp_server_service.dart';

void main() {
  test('FTP server: chroot, CWD /, LIST, traversal blocked', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dev.fluttercommunity.plus/network_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'wifiIPAddress') return '127.0.0.1';
      return null;
    });

    final root = Directory.systemTemp.createTempSync('ftp_root_');
    File(p.join(root.path, 'hello.txt')).writeAsStringSync('hello world\n');

    final srv = FtpServerService(port: 0);
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

    expect(await cmd('USER x'), contains('331'));
    expect(await cmd('PASS x'), contains('230'));
    expect(await cmd('PWD'), contains('257'));
    expect(await cmd('CWD /'), contains('250'), reason: 'CWD / must resolve to the share root');
    expect(await cmd('PWD'), contains('257 "/"'));

    // Passive LIST of the share root (bare LIST uses cwd = /)
    final pasv = await cmd('PASV');
    final m = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)').firstMatch(pasv);
    expect(m, isNotNull, reason: 'PASV reply must contain a data port');
    final dataPort = int.parse(m![5]!) * 256 + int.parse(m[6]!);
    final dataSocket = await Socket.connect('127.0.0.1', dataPort);
    final dataLines = StringBuffer();
    final dataDone = Completer<void>();
    dataSocket.listen(
      (d) => dataLines.write(String.fromCharCodes(d)),
      onDone: () => dataDone.complete(),
    );
    socket.add('LIST\r\n'.codeUnits);
    await dataDone.future.timeout(const Duration(seconds: 3));
    final listResp = await readAll();
    expect(listResp, contains('226'), reason: 'LIST must complete');
    expect(dataLines.toString(), contains('hello.txt'),
        reason: 'bare LIST must list the share root');

    // Traversal attempts must stay chrooted
    expect(await cmd('SIZE /etc/passwd'), contains('550'));
    expect(await cmd('DELE /etc/passwd'), contains('550'));
    expect(await cmd('CWD ../../..'), contains('250'));
    expect(await cmd('PWD'), contains('257 "/"'));

    // At chroot root, files resolve; RETR without a data connection is refused
    expect(await cmd('SIZE hello.txt'), contains('213'));
    final retr = await cmd('RETR hello.txt');
    expect(retr, contains('425'), reason: 'RETR without a data connection is refused');

    await cmd('QUIT');
    socket.close();
    dataSocket.close();
    await srv.stop();
    root.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
