import 'package:flutter/material.dart';
import '../services/bluetooth_share_service.dart';
import '../services/bt_permissions.dart';
import '../theme/theme.dart';

/// Full Bluetooth sharing screen with device list, connection state, send/receive
/// progress bar, and file transfer controls.
class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({super.key});

  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  final _service = BluetoothShareService();
  final List<BluetoothDeviceItem> _devices = [];
  String? _statusMessage;
  // ignore: prefer_final_fields — mutated via setState
  bool _permissionsReady = false;
  // Tracks filenames currently queued for sending so we can show a queue indicator.
  final List<String> _sendingFiles = [];

  @override
  void initState() {
    super.initState();
    _listenStreams();
  }

  void _listenStreams() {
    _service.stateStream.listen((state) {
      setState(() {});
    });
    _service.progressStream.listen((progress) {
      setState(() {
        _statusMessage =
            '${progress.filename}: ${(progress.percentage * 100).toStringAsFixed(0)}%';
      });
    });
    _service.messageStream.listen((msg) {
      setState(() => _statusMessage = msg);
    });
  }

  Future<void> _requestPermissions() async {
    final supported = await _service.isSupported();
    if (!supported) {
      setState(
        () => _statusMessage = 'Bluetooth not supported on this device.',
      );
      return;
    }
    final granted = await BtPermissions.ensurePermissions();
    if (granted) {
      final enabled = await _service.isEnabled();
      if (!enabled) {
        await _service.requestEnable();
      }
      await _refreshDevices();
    }
    setState(() {
      _permissionsReady = granted;
      if (!granted) {
        _statusMessage = 'Bluetooth permissions were denied.';
      } else {
        _statusMessage = null;
      }
    });
  }

  Future<void> _refreshDevices() async {
    final devices = await _service.getPairedDevices();
    setState(() {
      _devices.clear();
      _devices.addAll(devices);
    });
  }

  Future<void> _startServer() async {
    setState(() => _statusMessage = 'Waiting for connections...');
    await _service.startServer();
  }

  Future<void> _stopServer() async {
    await _service.stopServer();
    setState(() => _statusMessage = null);
  }

  Future<void> _connectToDevice(BluetoothDeviceItem device) async {
    setState(() => _statusMessage = 'Connecting to ${device.name}...');
    await _service.connectToDevice(device.address);
    setState(() => _statusMessage = 'Connected to ${device.name}');
  }

  /// Open the native Android file picker and send selected files.
  /// Bridges to MainActivity.kt's "pickFile" handler which launches
  /// ACTION_OPEN_DOCUMENT and returns results via onActivityResult.
  Future<void> _pickAndSendFiles() async {
    if (_service.state != BluetoothState.connected) {
      _showSnackBar('Connect to a device first.');
      return;
    }
    if (_service.isSending) {
      _showSnackBar('Transfer in progress — please wait or cancel.');
      return;
    }

    // Invoke native file picker; results arrive via onFilePicked stream.
    try {
      await _service.pickFile();
    } catch (e) {
      _showSnackBar('Could not open file picker: $e');
    }
  }

  void _cancelTransfer() {
    _service.cancelTransfer();
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // Progress bar value (0.0–1.0), driven by progressStream updates via setState.
  BluetoothTransferProgress? _lastProgress;

  @override
  Widget build(BuildContext context) {
    final state = _service.state;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status header
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _stateColor(state),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(_stateIcon(state), color: Colors.white, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _stateLabel(state),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_statusMessage != null &&
                          state != BluetoothState.disconnected)
                        Text(
                          _statusMessage!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      if (_sendingFiles.isNotEmpty)
                        Text(
                          'Queue: ${_sendingFiles.join(", ")}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
                if (state == BluetoothState.listening ||
                    state == BluetoothState.connected)
                  FilledButton(
                    onPressed: _stopServer,
                    style: FilledButton.styleFrom(
                      backgroundColor: OneDarkColors.red,
                    ),
                    child: const Text('Stop'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Progress bar during transfer
          if (state == BluetoothState.sending || state == BluetoothState.receiving)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: _lastProgress?.percentage ?? 0.0,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: OneDarkColors.dim,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    state == BluetoothState.sending ? OneDarkColors.purple : OneDarkColors.cyan,
                  ),
                ),
                const SizedBox(height: 4),
                if (_lastProgress != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _lastProgress!.filename,
                        style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${(_lastProgress!.percentage * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: OneDarkColors.fg, fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (state == BluetoothState.sending)
                  FilledButton.icon(
                    onPressed: _cancelTransfer,
                    style: FilledButton.styleFrom(
                      backgroundColor: OneDarkColors.red,
                      minimumSize: const Size.fromHeight(40),
                    ),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  ),
              ],
            ),
          const SizedBox(height: 12),

          // Action buttons — responsive layout for all screen sizes
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 400;
              return Column(
                children: [
                  if (isNarrow) ...[
                    // Stack vertically on narrow screens
                    FilledButton.icon(
                      onPressed: _requestPermissions,
                      icon: const Icon(Icons.privacy_tip),
                      label: const Text('Request Permissions'),
                      style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _permissionsReady && state == BluetoothState.disconnected ? _startServer : null,
                      icon: const Icon(Icons.bluetooth_connected),
                      label: const Text('Start Listening'),
                      style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: state == BluetoothState.connected && !_service.isSending ? _pickAndSendFiles : null,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Send Files'),
                      style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                    ),
                  ] else ...[
                    // Side-by-side on wider screens
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _requestPermissions,
                            icon: const Icon(Icons.privacy_tip),
                            label: const Text('Request Permissions'),
                            style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _permissionsReady && state == BluetoothState.disconnected ? _startServer : null,
                            icon: const Icon(Icons.bluetooth_connected),
                            label: const Text('Start Listening'),
                            style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: state == BluetoothState.connected && !_service.isSending ? _pickAndSendFiles : null,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Send Files'),
                      style: FilledButton.styleFrom(minimumSize: Size.fromHeight(44)),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // Device list
          const Text(
            'Paired Devices',
            style: TextStyle(
              color: OneDarkColors.cyan,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Text(
                      'No paired devices',
                      style: TextStyle(color: OneDarkColors.fgDim),
                    ),
                  )
                : ListView.separated(
                    itemCount: _devices.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: OneDarkColors.dim,
                          child: const Icon(
                            Icons.bluetooth,
                            color: OneDarkColors.cyan,
                          ),
                        ),
                        title: Text(
                          device.name,
                          style: const TextStyle(color: OneDarkColors.fg),
                        ),
                        subtitle: Text(
                          device.address,
                          style: const TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                        ),
                        trailing: state == BluetoothState.listening
                            ? ElevatedButton(
                                onPressed: () => _connectToDevice(device),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: OneDarkColors.green,
                                ),
                                child: const Text('Connect'),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _stateColor(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected:
        return OneDarkColors.dim;
      case BluetoothState.listening:
        return OneDarkColors.green;
      case BluetoothState.connecting:
        return OneDarkColors.amber;
      case BluetoothState.connected:
        return OneDarkColors.cyan;
      case BluetoothState.sending:
        return OneDarkColors.purple;
      case BluetoothState.receiving:
        return OneDarkColors.cyan;
    }
  }

  IconData _stateIcon(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected:
        return Icons.bluetooth_disabled;
      case BluetoothState.listening:
        return Icons.bluetooth_searching;
      case BluetoothState.connecting:
        return Icons.sync;
      case BluetoothState.connected:
        return Icons.bluetooth_connected;
      case BluetoothState.sending:
        return Icons.upload_file;
      case BluetoothState.receiving:
        return Icons.file_download;
    }
  }

  String _stateLabel(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected:
        return 'Disconnected';
      case BluetoothState.listening:
        return 'Listening for connections...';
      case BluetoothState.connecting:
        return 'Connecting...';
      case BluetoothState.connected:
        return 'Connected';
      case BluetoothState.sending:
        return 'Sending file...';
      case BluetoothState.receiving:
        return 'Receiving file...';
    }
  }
}
