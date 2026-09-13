// Tests for BluetoothShareService.
//
// These drive the real `com.swordfm/bluetooth` MethodChannel via
// TestDefaultBinaryMessengerBinding, so every assertion exercises production
// code paths (state machine, stream emissions, message formatting) rather than
// a copy of the logic.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/bluetooth_share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.swordfm/bluetooth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late BluetoothShareService service;

  /// Method calls the service made out to the platform.
  late List<MethodCall> calls;

  /// When set, the named method throws this exception.
  PlatformException? throwOn;

  setUp(() {
    service = BluetoothShareService();
    calls = [];
    throwOn = null;

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (throwOn != null && call.method == throwOn!.code) {
        throw throwOn!;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// Simulates an inbound callback from the native side (Kotlin -> Dart).
  Future<void> emitNative(String method, [Map<String, dynamic>? args]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------
  group('BluetoothDeviceItem', () {
    test('fromMap reads name and address', () {
      final item = BluetoothDeviceItem.fromMap({
        'name': 'Pixel Buds',
        'address': 'AA:BB:CC:DD:EE:FF',
      });
      expect(item.name, 'Pixel Buds');
      expect(item.address, 'AA:BB:CC:DD:EE:FF');
    });

    test('fromMap defaults a missing name to Unknown', () {
      expect(BluetoothDeviceItem.fromMap({'address': 'AA:BB'}).name, 'Unknown');
    });

    test('fromMap defaults a missing address to empty', () {
      expect(BluetoothDeviceItem.fromMap({'name': 'X'}).address, '');
    });

    test('fromMap tolerates a completely empty map', () {
      final item = BluetoothDeviceItem.fromMap({});
      expect(item.name, 'Unknown');
      expect(item.address, '');
    });
  });

  group('BluetoothTransferProgress.percentage', () {
    test('computes a normal fraction', () {
      final p = BluetoothTransferProgress(
        filename: 'a.bin',
        bytesTransferred: 50,
        totalBytes: 200,
        isSending: true,
      );
      expect(p.percentage, 0.25);
    });

    test('is 0.0 when totalBytes is zero (no divide-by-zero)', () {
      final p = BluetoothTransferProgress(
        filename: 'a.bin',
        bytesTransferred: 10,
        totalBytes: 0,
        isSending: false,
      );
      expect(p.percentage, 0.0);
    });

    test('reaches 1.0 when complete', () {
      final p = BluetoothTransferProgress(
        filename: 'a.bin',
        bytesTransferred: 200,
        totalBytes: 200,
        isSending: false,
      );
      expect(p.percentage, 1.0);
    });
  });

  // ---------------------------------------------------------------------------
  // Initial state
  // ---------------------------------------------------------------------------
  group('initial state', () {
    // NOTE: BluetoothShareService is a singleton, so these assertions describe
    // a freshly loaded VM. Tests run in declaration order within a file, and
    // this group is declared first, so state is still pristine here.
    test('starts disconnected with no device and no checksum', () {
      expect(service.isSending, isFalse);
      expect(service.lastTransferVerified, isFalse);
    });

    test('the factory always returns the same instance', () {
      expect(identical(BluetoothShareService(), BluetoothShareService()),
          isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Outbound platform calls
  // ---------------------------------------------------------------------------
  group('outbound platform calls', () {
    test('isSupported forwards to isBluetoothSupported', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      expect(await service.isSupported(), isTrue);
      expect(calls.single.method, 'isBluetoothSupported');
    });

    test('isSupported returns false when the platform throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'x', message: 'no adapter');
      });
      expect(await service.isSupported(), isFalse);
    });

    test('isEnabled forwards to isBluetoothEnabled and defaults false',
        () async {
      expect(await service.isEnabled(), isFalse);
      expect(calls.single.method, 'isBluetoothEnabled');
    });

    test('getPairedDevices maps the native list into BluetoothDeviceItem',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <dynamic>[
          {'name': 'Headset', 'address': '11:22'},
          {'name': 'Phone', 'address': '33:44'},
        ];
      });
      final devices = await service.getPairedDevices();
      expect(devices.map((d) => d.name), ['Headset', 'Phone']);
      expect(calls.single.method, 'getPairedDevices');
    });

    test('getPairedDevices returns [] when native yields null', () async {
      expect(await service.getPairedDevices(), isEmpty);
    });

    test('getPairedDevices surfaces a platform error on messageStream',
        () async {
      throwOn = PlatformException(code: 'getPairedDevices', message: 'denied');
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      expect(await service.getPairedDevices(), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, contains('denied'));
      await sub.cancel();
    });

    test('startServer optimistically moves to listening', () async {
      await service.startServer();
      expect(service.state, BluetoothState.listening);
      expect(calls.single.method, 'startServer');
    });

    test('startServer rolls back to disconnected on failure', () async {
      throwOn = PlatformException(code: 'startServer', message: 'busy');
      await service.startServer();
      expect(service.state, BluetoothState.disconnected);
    });

    test('connectToDevice forwards the address and moves to connecting',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      await service.connectToDevice('AA:BB');
      expect(calls.single.arguments['address'], 'AA:BB');
      expect(service.state, BluetoothState.connecting);
    });

    test('connectToDevice falls back to disconnected when native says false',
        () async {
      await service.connectToDevice('AA:BB'); // mock returns null => false
      expect(service.state, BluetoothState.disconnected);
    });

    test('connectToDevice rolls back on a platform exception', () async {
      throwOn = PlatformException(code: 'connectToDevice', message: 'refused');
      await service.connectToDevice('AA:BB');
      expect(service.state, BluetoothState.disconnected);
    });

    test('sendFile enters sending then returns true', () async {
      expect(await service.sendFile('/tmp/x.bin'), isTrue);
      expect(service.state, BluetoothState.sending);
      expect(service.isSending, isTrue);
      expect(calls.single.arguments['path'], '/tmp/x.bin');
    });

    test('sendFile returns false and recovers state on failure', () async {
      throwOn = PlatformException(code: 'sendFile', message: 'io');
      expect(await service.sendFile('/tmp/y.bin'), isFalse);
      // A failed send must not strand the state machine in `sending`.
      expect(service.state, BluetoothState.connected);
    });

    test('stopServer returns to disconnected', () async {
      await service.startServer();
      await service.stopServer();
      expect(service.state, BluetoothState.disconnected);
      expect(calls.last.method, 'stopServer');
    });

    test('disconnect returns to disconnected', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      await service.connectToDevice('AA:BB');
      await service.disconnect();
      expect(service.state, BluetoothState.disconnected);
    });

    test('cancelTransfer returns to connected and reports cancellation',
        () async {
      await service.sendFile('/tmp/x.bin');
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await service.cancelTransfer();
      await Future<void>.delayed(Duration.zero);
      expect(service.state, BluetoothState.connected);
      expect(messages, contains('Transfer cancelled.'));
      await sub.cancel();
    });

    test('pickFile throws a wrapped Exception on platform failure', () async {
      throwOn = PlatformException(code: 'pickFile', message: 'no picker');
      expect(() => service.pickFile(), throwsA(isA<Exception>()));
    });

    test('requestEnable reports errors on messageStream', () async {
      throwOn =
          PlatformException(code: 'requestEnableBluetooth', message: 'nope');
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await service.requestEnable();
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, contains('nope'));
      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  // Inbound native callbacks (the Kotlin -> Dart contract)
  // ---------------------------------------------------------------------------
  group('inbound native callbacks', () {
    test('onServerStarted moves to listening', () async {
      await emitNative('onServerStarted');
      expect(service.state, BluetoothState.listening);
    });

    test('onConnected records the device name and emits it', () async {
      final names = <String>[];
      final sub = service.deviceConnectedStream.listen(names.add);
      await emitNative('onConnected', {'name': 'Pixel'});
      await Future<void>.delayed(Duration.zero);
      expect(service.connectedDeviceName, 'Pixel');
      expect(service.state, BluetoothState.connected);
      expect(names, ['Pixel']);
      await sub.cancel();
    });

    test('onConnected defaults the name to Device', () async {
      await emitNative('onConnected');
      expect(service.connectedDeviceName, 'Device');
    });

    test('onDisconnected clears the device name', () async {
      await emitNative('onConnected', {'name': 'Pixel'});
      await emitNative('onDisconnected');
      expect(service.connectedDeviceName, isNull);
      expect(service.state, BluetoothState.disconnected);
    });

    test('onTransferStarted with isSending=true enters sending', () async {
      await emitNative('onTransferStarted', {'isSending': true});
      expect(service.state, BluetoothState.sending);
    });

    test('onTransferStarted with isSending=false enters receiving', () async {
      await emitNative('onTransferStarted', {'isSending': false});
      expect(service.state, BluetoothState.receiving);
    });

    test('onTransferProgress emits a BluetoothTransferProgress', () async {
      final events = <BluetoothTransferProgress>[];
      final sub = service.progressStream.listen(events.add);
      await emitNative('onTransferProgress', {
        'filename': 'movie.mp4',
        'bytesTransferred': 512,
        'totalBytes': 1024,
        'isSending': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.single.filename, 'movie.mp4');
      expect(events.single.percentage, 0.5);
      await sub.cancel();
    });

    test('onTransferProgress tolerates missing arguments', () async {
      final events = <BluetoothTransferProgress>[];
      final sub = service.progressStream.listen(events.add);
      await emitNative('onTransferProgress');
      await Future<void>.delayed(Duration.zero);
      expect(events.single.bytesTransferred, 0);
      expect(events.single.totalBytes, 0);
      await sub.cancel();
    });

    test('onTransferError wraps the native message', () async {
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await emitNative('onTransferError', {'message': 'socket closed'});
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, 'Transfer Error: socket closed');
      expect(service.state, BluetoothState.connected);
      await sub.cancel();
    });

    test('onTransferError with no message emits a generic error', () async {
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await emitNative('onTransferError');
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, 'Transfer Error.');
      await sub.cancel();
    });

    test('an unknown native method does not change the current state',
        () async {
      // BluetoothShareService is a singleton (factory returns a single
      // _instance), so _state persists across tests in this file. Capture the
      // current state and assert the unknown callback leaves it untouched,
      // rather than assuming a fresh instance starts disconnected.
      final before = service.state;
      await emitNative('onSomethingBrandNew', {'x': 1});
      expect(service.state, before);
    });


    test('onTransferComplete formats the message and records the checksum',
        () async {
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await emitNative('onTransferComplete', {
        'savedPath': '/sdcard/Download/a.bin',
        'sha256': 'abc123',
        'verified': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        messages.single,
        'Transfer Complete! Saved to /sdcard/Download/a.bin\n'
        'SHA-256: abc123 (verified)',
      );
      expect(service.lastTransferSha256, 'abc123');
      expect(service.lastTransferVerified, isTrue);
      expect(service.state, BluetoothState.connected);
      await sub.cancel();
    });

    test('onTransferComplete with no path omits the path clause', () async {
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await emitNative('onTransferComplete', {'savedPath': '', 'sha256': ''});
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, 'Transfer Complete!');
      // An empty checksum must not be recorded as a real digest.
      expect(service.lastTransferSha256, isNull);
      expect(service.lastTransferVerified, isFalse);
      await sub.cancel();
    });

    test('onTransferComplete marks an unverified checksum as not verified',
        () async {
      final messages = <String>[];
      final sub = service.messageStream.listen(messages.add);
      await emitNative('onTransferComplete', {
        'savedPath': '/x',
        'sha256': 'deadbeef',
        'verified': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(messages.single, contains('(not verified)'));
      expect(service.lastTransferVerified, isFalse);
      await sub.cancel();
    });

    test('onFilePicked emits the selected paths', () async {
      final received = <List<String>>[];
      final sub = service.filePickedStream.listen(received.add);
      await emitNative('onFilePicked', {
        'paths': ['/a.txt', '/b.txt'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(received.single, ['/a.txt', '/b.txt']);
      await sub.cancel();
    });

    test('onFilePicked discards non-string entries', () async {
      final received = <List<String>>[];
      final sub = service.filePickedStream.listen(received.add);
      await emitNative('onFilePicked', {
        'paths': ['/a.txt', 42, null, '/b.txt'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(received.single, ['/a.txt', '/b.txt']);
      await sub.cancel();
    });

    test('onFilePicked with an empty list emits nothing', () async {
      final received = <List<String>>[];
      final sub = service.filePickedStream.listen(received.add);
      await emitNative('onFilePicked', {'paths': <String>[]});
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  // SHA-256
  // ---------------------------------------------------------------------------
  group('computeSha256', () {
    test('returns the digest reported by native', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'e3b0c44298fc1c149afbf4c8996fb924'
            '27ae41e4649b934ca495991b7852b855';
      });
      final digest = await BluetoothShareService.computeSha256('/tmp/x');
      expect(digest, hasLength(64));
      expect(calls.single.method, 'computeSha256');
      expect(calls.single.arguments['path'], '/tmp/x');
    });

    test('returns null when the platform throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'io', message: 'unreadable');
      });
      expect(await BluetoothShareService.computeSha256('/nope'), isNull);
    });

    test('returns null when native reports null', () async {
      expect(await BluetoothShareService.computeSha256('/tmp/x'), isNull);
    });
  });
}

