import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/ftp_server_service.dart';

/// Builds a server on an ephemeral port over a temp share root.
Future<(FtpServerService, Directory)> _bootServer({String pin = 'correct-pin'}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/network_info');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'wifiIPAddress') return '127.0.0.1';
    return null;
  });

  final root = Directory.systemTemp.createTempSync('ftp_secure_');
  File(p.join(root.path, 'secret.txt')).writeAsStringSync('classified\n');

  final srv = FtpServerService(port: 0);
  srv.sharePin = pin;
  await srv.start(shareRootOverride: root.path);
  return (srv, root);
}

/// Opens a control connection and returns a command/response helper.
Future<(Socket, Future<String> Function(String))> _connect(FtpServerService srv) async {
  final socket = await Socket.connect('127.0.0.1', srv.boundPort);
  final buf = StringBuffer();
  socket.listen((d) => buf.write(String.fromCharCodes(d)));

  Future<String> cmd(String c) async {
    socket.add('$c\r\n'.codeUnits);
    await Future.delayed(const Duration(milliseconds: 150));
    final s = buf.toString();
    buf.clear();
    return s.trim();
  }

  await Future.delayed(const Duration(milliseconds: 200));
  buf.clear(); // discard the 220 greeting
  return (socket, cmd);
}

void main() {
  group('FTP session isolation', () {
    test('a second client authenticating must NOT unlock a first client',
        () async {
      final (srv, root) = await _bootServer();
      addTearDown(() async {
        await srv.stop();
        root.deleteSync(recursive: true);
      });

      // Client A connects but never authenticates.
      final (sockA, cmdA) = await _connect(srv);
      addTearDown(() => sockA.destroy());

      expect(await cmdA('PWD'), contains('530'),
          reason: 'client A is unauthenticated and must be gated');

      // Client B connects and authenticates successfully.
      final (sockB, cmdB) = await _connect(srv);
      addTearDown(() => sockB.destroy());
      expect(await cmdB('PASS correct-pin'), contains('230'));

      // The critical assertion: B's success must not authenticate A.
      expect(await cmdA('PWD'), contains('530'),
          reason: 'auth must be per-session, not service-wide');

      // And B is genuinely authenticated.
      expect(await cmdB('PWD'), contains('257'));
    });

    test('an empty PIN is rejected at start()', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('dev.fluttercommunity.plus/network_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'wifiIPAddress') return '127.0.0.1';
        return null;
      });

      final root = Directory.systemTemp.createTempSync('ftp_nopin_');
      addTearDown(() => root.deleteSync(recursive: true));

      final srv = FtpServerService(port: 0);
      await expectLater(
        srv.start(shareRootOverride: root.path),
        throwsA(isA<StateError>()),
      );
      expect(srv.isRunning, isFalse,
          reason: 'server must not bind without a PIN');
    });

    test('wrong PIN is rejected and repeated failures trigger lockout',
        () async {
      final (srv, root) = await _bootServer();
      addTearDown(() async {
        await srv.stop();
        root.deleteSync(recursive: true);
      });

      final (sock, cmd) = await _connect(srv);
      addTearDown(() => sock.destroy());

      for (var i = 1; i < FtpServerService.maxFailedAttempts; i++) {
        final reply = await cmd('PASS wrong-$i');
        expect(reply, contains('530'),
            reason: 'attempt $i should be a plain rejection');
      }

      // The attempt that crosses the threshold returns the lockout code.
      final locked = await cmd('PASS wrong-final');
      expect(locked, contains('421'),
          reason: 'exceeding the failure budget must lock the address out');

      // Even the CORRECT PIN is refused while locked out.
      expect(await cmd('PASS correct-pin'), contains('421'));
    });
  });
}
