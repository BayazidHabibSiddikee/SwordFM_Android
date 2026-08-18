// Bluetooth file transfer shared protocol frame format (MUST MATCH MainActivity.kt & /home/sword/SwordFM/tools/swordblue):
//
//   [4-byte uint32 metadataLength]  (big-endian)
//   [metadataLength bytes of JSON]
//   [raw file bytes = "size" from JSON]
//
// JSON metadata: {"filename": "example.pdf", "size": 12345}
//
// Sender writes: 4B length + JSON + raw bytes
// Receiver reads: 4B length → parse JSON → read "size" bytes
// Keep these three implementations in sync — any change here must be mirrored there.
import 'dart:async';
import 'package:flutter/services.dart';

enum BluetoothState {
  disconnected,
  listening,
  connecting,
  connected,
  sending,
  receiving,
}

class BluetoothDeviceItem {
  final String name;
  final String address;

  BluetoothDeviceItem(this.name, this.address);

  factory BluetoothDeviceItem.fromMap(Map<dynamic, dynamic> map) {
    return BluetoothDeviceItem(
      map['name'] as String? ?? 'Unknown',
      map['address'] as String? ?? '',
    );
  }
}

class BluetoothTransferProgress {
  final String filename;
  final int bytesTransferred;
  final int totalBytes;
  final bool isSending;

  BluetoothTransferProgress({
    required this.filename,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.isSending,
  });

  double get percentage => totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;
}

class BluetoothShareService {
  static const MethodChannel _channel = MethodChannel('com.swordfm/bluetooth');

  // Singleton
  static final BluetoothShareService _instance =
      BluetoothShareService._internal();
  factory BluetoothShareService() => _instance;
  BluetoothShareService._internal() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final _stateController = StreamController<BluetoothState>.broadcast();
  final _progressController =
      StreamController<BluetoothTransferProgress>.broadcast();
  final _deviceConnectedController = StreamController<String>.broadcast();
  final _messageController = StreamController<String>.broadcast();

  Stream<BluetoothState> get stateStream => _stateController.stream;
  Stream<BluetoothTransferProgress> get progressStream =>
      _progressController.stream;
  Stream<String> get deviceConnectedStream => _deviceConnectedController.stream;
  Stream<String> get messageStream => _messageController.stream;

  BluetoothState _state = BluetoothState.disconnected;
  BluetoothState get state => _state;

  String? _connectedDeviceName;
  String? get connectedDeviceName => _connectedDeviceName;

  void _updateState(BluetoothState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isBluetoothSupported') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isBluetoothEnabled') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  Future<void> requestEnable() async {
    try {
      await _channel.invokeMethod('requestEnableBluetooth');
    } on PlatformException catch (e) {
      _messageController.add('Error enabling Bluetooth: ${e.message}');
    }
  }

  Future<List<BluetoothDeviceItem>> getPairedDevices() async {
    try {
      final List<dynamic>? devices = await _channel.invokeMethod<List<dynamic>>(
        'getPairedDevices',
      );
      if (devices == null) return [];
      return devices.map((d) => BluetoothDeviceItem.fromMap(d as Map)).toList();
    } on PlatformException catch (e) {
      _messageController.add('Error fetching paired devices: ${e.message}');
      return [];
    }
  }

  Future<void> startServer() async {
    try {
      _updateState(BluetoothState.listening);
      await _channel.invokeMethod('startServer');
    } on PlatformException catch (e) {
      _updateState(BluetoothState.disconnected);
      _messageController.add('Error starting BT server: ${e.message}');
    }
  }

  Future<void> stopServer() async {
    try {
      await _channel.invokeMethod('stopServer');
      _updateState(BluetoothState.disconnected);
    } on PlatformException catch (e) {
      _messageController.add('Error stopping BT server: ${e.message}');
    }
  }

  Future<void> connectToDevice(String address) async {
    try {
      _updateState(BluetoothState.connecting);
      final success =
          await _channel.invokeMethod<bool>('connectToDevice', {
            'address': address,
          }) ??
          false;
      if (!success) {
        _updateState(BluetoothState.disconnected);
      }
    } on PlatformException catch (e) {
      _updateState(BluetoothState.disconnected);
      _messageController.add('Connection failed: ${e.message}');
    }
  }

  /// Initiates file send by path. The native side handles the swordblue frame:
  /// [4B len][JSON {filename,size}][raw bytes].
  Future<void> sendFile(String filePath) async {
    try {
      _updateState(BluetoothState.sending);
      await _channel.invokeMethod('sendFile', {'path': filePath});
    } on PlatformException catch (e) {
      _updateState(BluetoothState.connected);
      _messageController.add('Failed to send file: ${e.message}');
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      _updateState(BluetoothState.disconnected);
    } on PlatformException catch (e) {
      _messageController.add('Disconnect failed: ${e.message}');
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onServerStarted':
        _updateState(BluetoothState.listening);
        break;
      case 'onConnected':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final name = args['name'] as String? ?? 'Device';
        _connectedDeviceName = name;
        _deviceConnectedController.add(name);
        _updateState(BluetoothState.connected);
        break;
      case 'onDisconnected':
        _connectedDeviceName = null;
        _updateState(BluetoothState.disconnected);
        break;
      case 'onTransferStarted':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final isSending = args['isSending'] as bool? ?? false;
        _updateState(
          isSending ? BluetoothState.sending : BluetoothState.receiving,
        );
        break;
      case 'onTransferProgress':
        final args = call.arguments as Map<dynamic, dynamic>? ?? {};
        final filename = args['filename'] as String? ?? '';
        final bytes = args['bytesTransferred'] as int? ?? 0;
        final total = args['totalBytes'] as int? ?? 0;
        final isSending = args['isSending'] as bool? ?? false;
        _progressController.add(
          BluetoothTransferProgress(
            filename: filename,
            bytesTransferred: bytes,
            totalBytes: total,
            isSending: isSending,
          ),
        );
        break;
      case 'onTransferComplete':
        final savedPath = call.arguments['savedPath'] as String? ?? '';
        _messageController.add('Transfer Complete! Saved to $savedPath');
        _updateState(BluetoothState.connected);
        break;
      case 'onTransferError':
        final msg = call.arguments['message'] as String? ?? '';
        _messageController.add('Transfer Error: $msg');
        _updateState(BluetoothState.connected);
        break;
    }
  }
}
