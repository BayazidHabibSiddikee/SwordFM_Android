import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import '../services/web_share_server.dart';
import '../services/ftp_server_service.dart';
import '../services/bluetooth_share_service.dart';
import '../services/bt_permissions.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import 'qr_scanner_screen.dart';

/// Full LAN sharing screen with QR code, server controls, auth management,
/// share-root picker, and client-access log.
class LANSharingScreen extends StatefulWidget {
  /// Optional pre-configured server (tests inject one on a free port);
  /// defaults to a standard 8080 server.
  final WebShareServer? server;

  /// When set (e.g. "Share via LAN…" from a folder's context menu), the
  /// server starts sharing this folder instead of the default share root.
  final String? initialShareRoot;
  const LANSharingScreen({super.key, this.server, this.initialShareRoot});

  @override
  State<LANSharingScreen> createState() => _LANSharingScreenState();
}

class _LANSharingScreenState extends State<LANSharingScreen> {
  late final WebShareServer _server = widget.server ?? WebShareServer();
  late final FtpServerService _ftpServer = FtpServerService();
  String? _statusMessage;
  String? _ftpStatus;

  // ── Bluetooth state ───────────────────────────────────────────────────
  final BluetoothShareService _btService = BluetoothShareService();
  final List<BluetoothDeviceItem> _btDevices = [];
  final List<StreamSubscription<dynamic>> _btSubs = [];
  String? _btStatusMessage;
  BluetoothTransferProgress? _btLastProgress;
  String? _btLastSha256;
  bool _btLastVerified = false;
  bool _btPermissionsReady = false;
  List<String> _btSendingFiles = [];

  @override
  void initState() {
    super.initState();
    _listenBtStreams();
  }

  @override
  void dispose() {
    for (final sub in _btSubs) sub.cancel();
    super.dispose();
  }

  Future<void> _startServer() async {
    setState(() => _statusMessage = 'Starting server...');
    final ip = await _server.start(shareRootOverride: widget.initialShareRoot);
    if (ip != null) {
      setState(() {
        _statusMessage = 'Server running at http://$ip:${_server.port}';
      });
    } else {
      setState(
        () => _statusMessage =
            'Failed to start server. Check network permissions.',
      );
    }
  }

  void _stopServer() {
    _server.stop();
    setState(() => _statusMessage = 'Server stopped.');
  }

  void _rotatePin() {
    _server.rotatePin();
    setState(() => _statusMessage = 'PIN rotated — re-share QR to clients.');
  }

  Future<void> _pickShareRoot() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const ShareRootPickerScreen(initialPath: ''),
      ),
    );
    if (result != null && mounted) {
      _server.setShareRoot(result);
      setState(() => _statusMessage = 'Share root changed to $result');
    }
  }

  void _openAccessLog() {
    showDialog(
      context: context,
      builder: (_) => _AccessLogDialog(entries: _server.accessLog),
    );
  }

  // ── FTP Server helpers ──────────────────────────────────────────────

  Future<void> _startFtp() async {
    setState(() => _ftpStatus = 'Starting FTP server…');
    try {
      await _ftpServer.start();
      if (mounted) {
        setState(() {
          _ftpStatus =
              'Running at ftp://${_ftpServer.currentIp ?? '?'}:${_ftpServer.boundPort}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _ftpStatus = 'FTP failed: $e');
    }
  }

  void _stopFtp() {
    _ftpServer.stop();
    setState(() => _ftpStatus = 'FTP server stopped.');
  }

  // ── Bluetooth helpers ─────────────────────────────────────────────────

  void _listenBtStreams() {
    _btSubs.add(_btService.stateStream.listen((state) {
      if (mounted) setState(() {});
    }));
    _btSubs.add(_btService.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _btLastProgress = progress;
          _btStatusMessage =
              '${progress.filename}: ${(progress.percentage * 100).toStringAsFixed(0)}%';
        });
      }
    }));
    _btSubs.add(_btService.messageStream.listen((msg) {
      if (mounted) {
        setState(() {
          _btStatusMessage = msg;
          final match = RegExp(r'\b[0-9a-f]{64}\b').firstMatch(msg);
          _btLastSha256 = match?.group(0);
          _btLastVerified = _btService.lastTransferVerified;
        });
      }
    }));
    _btSubs.add(_btService.filePickedStream.listen((paths) {
      if (mounted) {
        setState(() {
          _btSendingFiles = paths.map((path) => p.basename(path)).toList();
        });
      }
    }));
  }

  Future<void> _requestBtPermissions() async {
    final supported = await _btService.isSupported();
    if (!supported) {
      if (mounted) setState(() => _btStatusMessage = 'Bluetooth not supported.');
      return;
    }
    final granted = await BtPermissions.ensurePermissions();
    if (granted) {
      final enabled = await _btService.isEnabled();
      if (!enabled) await _btService.requestEnable();
      await _refreshBtDevices();
    }
    if (mounted) {
      setState(() {
        _btPermissionsReady = granted;
        _btStatusMessage = granted ? null : 'Bluetooth permissions denied.';
      });
    }
  }

  Future<void> _refreshBtDevices() async {
    final devices = await _btService.getPairedDevices();
    if (mounted) {
      _btDevices.clear();
      setState(() => _btDevices.addAll(devices));
    }
  }

  Future<void> _startBtListening() async {
    try {
      await _btService.startServer();
    } catch (e) {
      if (mounted) setState(() => _btStatusMessage = 'Failed to start: $e');
    }
  }

  Future<void> _stopBtListening() async {
    try {
      await _btService.stopServer();
    } catch (e) {
      if (mounted) setState(() => _btStatusMessage = 'Stop failed: $e');
    }
    if (mounted) setState(() => _btStatusMessage = null);
  }

  Future<void> _connectToDevice(BluetoothDeviceItem device) async {
    if (!mounted || device.name.isEmpty || device.address.isEmpty) return;
    setState(() => _btStatusMessage = 'Connecting to ${device.name}...');
    try {
      await _btService.connectToDevice(device.address);
      if (mounted) setState(() => _btStatusMessage = 'Connected to ${device.name}');
    } catch (e) {
      if (mounted) setState(() => _btStatusMessage = 'Connection failed: $e');
    }
  }

  Future<void> _pickAndSendFiles() async {
    if (_btService.state != BluetoothState.connected) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to a device first.')),
      );
      return;
    }
    if (_btService.isSending) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transfer in progress — please wait or cancel.')),
      );
      return;
    }
    try {
      await _btService.pickFile();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file picker: $e')),
      );
    }
  }

  void _cancelBtTransfer() {
    _btService.cancelTransfer();
  }

  Color _btStateColor(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected: return OneDarkColors.dim;
      case BluetoothState.listening: return OneDarkColors.green;
      case BluetoothState.connecting: return OneDarkColors.amber;
      case BluetoothState.connected: return OneDarkColors.cyan;
      case BluetoothState.sending: return OneDarkColors.purple;
      case BluetoothState.receiving: return OneDarkColors.cyan;
    }
  }

  IconData _btStateIcon(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected: return Icons.bluetooth_disabled;
      case BluetoothState.listening: return Icons.bluetooth_searching;
      case BluetoothState.connecting: return Icons.sync;
      case BluetoothState.connected: return Icons.bluetooth_connected;
      case BluetoothState.sending: return Icons.upload_file;
      case BluetoothState.receiving: return Icons.file_download;
    }
  }

  String _btStateLabel(BluetoothState s) {
    switch (s) {
      case BluetoothState.disconnected: return 'Disconnected';
      case BluetoothState.listening: return 'Listening for connections…';
      case BluetoothState.connecting: return 'Connecting…';
      case BluetoothState.connected: return 'Connected';
      case BluetoothState.sending: return 'Sending file…';
      case BluetoothState.receiving: return 'Receiving file…';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status card
            Card(
              color: OneDarkColors.bgDark,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          _server.isRunning ? Icons.wifi : Icons.wifi_off,
                          color: _server.isRunning
                              ? OneDarkColors.green
                              : OneDarkColors.red,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _server.isRunning
                                    ? 'Server Running'
                                    : 'Server Stopped',
                                style: TextStyle(
                                  color: OneDarkColors.fg,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_server.currentIp != null)
                                Text(
                                  'http://${_server.currentIp}:${_server.port}',
                                  style: TextStyle(
                                    color: OneDarkColors.cyan,
                                    fontSize: 13,
                                  ),
                                ),
                              if (_server.isRunning)
                                Text(
                                  'PIN: ${_server.pin}  ·  Root: ${_server.shareRoot}',
                                  style: TextStyle(
                                    color: OneDarkColors.amber,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_server.isRunning && _server.currentIp != null)
                      Center(
                        child: QrImageView(
                          data: 'http://${_server.currentIp}:${_server.port}',
                          version: QrVersions.auto,
                          size: 180.0,
                          gapless: false,
                          eyeStyle: QrEyeStyle(color: OneDarkColors.cyan),
                          dataModuleStyle: QrDataModuleStyle(
                            color: OneDarkColors.cyan,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!_server.isRunning)
                          FilledButton(
                            onPressed: _startServer,
                            child: const Text('Start Server'),
                          )
                        else
                          FilledButton(
                            onPressed: _stopServer,
                            style: FilledButton.styleFrom(
                              backgroundColor: OneDarkColors.red,
                            ),
                            child: const Text('Stop Server'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _server.isRunning ? _rotatePin : null,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Rotate PIN'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _server.isRunning ? _pickShareRoot : null,
                          icon: const Icon(Icons.folder, size: 16),
                          label: const Text('Change Root'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _server.isRunning ? _openAccessLog : null,
                          icon: const Icon(Icons.history, size: 16),
                          label: Text('Clients (${_server.accessLog.length})'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final result = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const QRScannerScreen(),
                              ),
                            );
                            if (result != null && mounted) {
                              setState(
                                () => _statusMessage = 'Connected to $result',
                              );
                            }
                          },
                          icon: const Icon(Icons.qr_code_scanner, size: 16),
                          label: const Text('Scan QR'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── FTP Server Section ────────────────────────────────────────
            Card(
              color: OneDarkColors.bgDark,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.dns,
                          size: 20,
                          color: _ftpServer.isRunning
                              ? OneDarkColors.green
                              : OneDarkColors.fgDim,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'FTP Server',
                          style: TextStyle(
                            color: OneDarkColors.fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (_ftpServer.isRunning)
                          Text(
                            'ftp://${_ftpServer.currentIp ?? '?'}:${_ftpServer.boundPort}',
                            style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _ftpServer.isRunning ? null : () => _startFtp(),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('Start FTP'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: !_ftpServer.isRunning ? null : () => _stopFtp(),
                            icon: const Icon(Icons.stop, size: 18),
                            label: const Text('Stop FTP'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: OneDarkColors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_ftpStatus != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: OneDarkColors.dim,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _ftpStatus!,
                          style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Bluetooth Section ─────────────────────────────────────────
            Card(
              color: OneDarkColors.bgDark,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _btStateIcon(_btService.state),
                          size: 20,
                          color: _btStateColor(_btService.state),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Bluetooth',
                          style: TextStyle(
                            color: OneDarkColors.fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (_btStatusMessage != null &&
                            _btService.state != BluetoothState.disconnected)
                          Flexible(
                            child: Text(
                              _btStatusMessage!,
                              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_btLastSha256 != null &&
                        _btService.state != BluetoothState.disconnected)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'SHA-256: ${_btLastSha256!}${_btLastVerified ? ' ✓ verified' : ' (not verified)'}',
                          style: TextStyle(
                            color: _btLastVerified ? OneDarkColors.green : OneDarkColors.amber,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    if (_btSendingFiles.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Queue: ${_btSendingFiles.join(", ")}',
                          style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
                        ),
                      ),
                    if (_btLastProgress != null) ...[
                      LinearProgressIndicator(
                        value: _btLastProgress!.percentage,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(4),
                        backgroundColor: OneDarkColors.dim,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _btService.state == BluetoothState.sending
                              ? OneDarkColors.purple
                              : OneDarkColors.cyan,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _requestBtPermissions,
                            icon: const Icon(Icons.privacy_tip, size: 18),
                            label: const Text('Request Permissions'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: OneDarkColors.cyan,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _btPermissionsReady &&
                                    _btService.state == BluetoothState.disconnected
                                ? _startBtListening
                                : null,
                            icon: const Icon(Icons.bluetooth_connected, size: 18),
                            label: const Text('Start Listening'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: OneDarkColors.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_btService.state == BluetoothState.connected &&
                        !_btService.isSending)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _pickAndSendFiles,
                          icon: const Icon(Icons.upload_file, size: 18),
                          label: const Text('Send Files'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: OneDarkColors.amber,
                          ),
                        ),
                      ),
                    if (_btService.state == BluetoothState.sending)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _cancelBtTransfer,
                          icon: const Icon(Icons.close, size: 18),
                          label: const Text('Cancel Transfer'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: OneDarkColors.red,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (_btDevices.isNotEmpty) ...[
                      Text(
                        'Paired Devices',
                        style: TextStyle(
                          color: OneDarkColors.cyan,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _btDevices.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final device = _btDevices[index];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.bluetooth,
                                size: 18,
                                color: OneDarkColors.cyan,
                              ),
                              title: Text(
                                device.name,
                                style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                              ),
                              subtitle: Text(
                                device.address,
                                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
                              ),
                              trailing: _btService.state == BluetoothState.listening
                                  ? ElevatedButton(
                                      onPressed: () => _connectToDevice(device),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: OneDarkColors.green,
                                        minimumSize: const Size(56, 28),
                                      ),
                                      child: const Text('Connect', style: TextStyle(fontSize: 10)),
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Instructions
            Card(
              color: OneDarkColors.bgDark,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How to Use',
                      style: TextStyle(
                        color: OneDarkColors.cyan,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _instructionStep('1. Start the server above'),
                    _instructionStep(
                      '2. Scan the QR code with another device on the same WiFi network',
                    ),
                    _instructionStep(
                      '3. Enter the PIN shown here to authenticate in the browser',
                    ),
                    _instructionStep(
                      '4. Browse, download, and upload files through the web interface',
                    ),
                    _instructionStep('5. Stop the server when done sharing'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Security notes
            Card(
              color: OneDarkColors.bgDark,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Security',
                      style: TextStyle(
                        color: OneDarkColors.green,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _securityNote(
                      'PIN-gated sessions — all file endpoints require a valid cookie',
                    ),
                    _securityNote(
                      'Upload filenames are sanitized: directory traversal rejected',
                    ),
                    _securityNote(
                      'Downloads stream from disk — no full-file memory buffering',
                    ),
                    _securityNote(
                      'Client IP access log available (tap "Clients" button)',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            if (_statusMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: OneDarkColors.dim,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: OneDarkColors.cyan,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _instructionStep(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, size: 16, color: OneDarkColors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _securityNote(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield, size: 14, color: OneDarkColors.cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Share-root picker — lets user navigate the filesystem and pick a dir.
// ---------------------------------------------------------------------------

class ShareRootPickerScreen extends StatefulWidget {
  final String initialPath;
  const ShareRootPickerScreen({super.key, required this.initialPath});

  @override
  State<ShareRootPickerScreen> createState() => _ShareRootPickerScreenState();
}

class _ShareRootPickerScreenState extends State<ShareRootPickerScreen> {
  late String _currentPath;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath.isNotEmpty ? widget.initialPath : '/';
  }

  Future<void> _navigate(String path) async {
    setState(() => _currentPath = path);
  }

  void _confirm() {
    Navigator.pop(context, _currentPath);
  }

  Widget _buildItem(String name, String path, {required bool isDir}) {
    final icon = isDir ? Icons.folder : Icons.insert_drive_file;
    return ListTile(
      leading: Icon(
        icon,
        color: isDir ? OneDarkColors.amber : OneDarkColors.fg,
      ),
      title: Text(name, style: TextStyle(color: OneDarkColors.fg)),
      subtitle: Text(
        path,
        style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
      ),
      onTap: () {
        if (isDir) _navigate(path);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick Share Root'),
        actions: [TextButton(onPressed: _confirm, child: const Text('Select'))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _currentPath,
                    style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                  ),
                ),
                if (_currentPath != '/')
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: () =>
                        _navigate(Directory(_currentPath).parent.path),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<Directory>(
              future: Future.value(Directory(_currentPath)),
              builder: (context, snapshot) {
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final dir = snapshot.data!;
                return FutureBuilder<List<DirEntry>>(
                  future: _listEntries(dir),
                  builder: (context, snap) {
                    if (!snap.hasData)
                      return const Center(child: CircularProgressIndicator());
                    final entries = snap.data!;
                    // Sort: dirs first, then files alphabetically.
                    entries.sort(
                      (a, b) => a.isDir == b.isDir
                          ? a.name.compareTo(b.name)
                          : a.isDir
                          ? -1
                          : 1,
                    );
                    return ListView.separated(
                      itemCount: entries.length + 1,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return ListTile(
                            leading: Icon(
                              Icons.home,
                              color: OneDarkColors.cyan,
                            ),
                            title: Text(
                              'Home',
                              style: TextStyle(color: OneDarkColors.fg),
                            ),
                            subtitle: Text(
                              AppPaths.home,
                              style: TextStyle(
                                color: OneDarkColors.fgDim,
                                fontSize: 11,
                              ),
                            ),
                            onTap: () => _navigate(AppPaths.home),
                          );
                        }
                        final e = entries[index - 1];
                        return _buildItem(e.name, e.path, isDir: e.isDir);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<List<DirEntry>> _listEntries(Directory dir) async {
    try {
      final entities = await dir.list().toList();
      return entities
          .map(
            (e) => DirEntry(
              name: e.path.split('/').last,
              path: e.path,
              isDir: e is Directory,
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class DirEntry {
  final String name;
  final String path;
  final bool isDir;
  const DirEntry({required this.name, required this.path, required this.isDir});
}

// ---------------------------------------------------------------------------
// Access-log dialog
// ---------------------------------------------------------------------------

class _AccessLogDialog extends StatelessWidget {
  final List<dynamic> entries;
  const _AccessLogDialog({required this.entries});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Client Access Log'),
      content: SizedBox(
        width: double.maxFinite,
        child: entries.isEmpty
            ? Text(
                'No requests yet.',
                style: TextStyle(color: OneDarkColors.fgDim),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final Map<String, dynamic> e =
                      entries[i] as Map<String, dynamic>;
                  final ip = (e['ip'] as String?) ?? 'unknown';
                  final path = (e['path'] as String?) ?? '';
                  final query = (e['query'] as String?) ?? '';
                  final rawTs = e['ts'];
                  final ts = rawTs is DateTime
                      ? rawTs.toString().substring(11, 19)
                      : '?';
                  return ListTile(
                    dense: true,
                    title: Text(
                      '$ip  →  $path',
                      style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
                    ),
                    subtitle: Text(
                      query.isNotEmpty ? '$query  $ts' : ts,
                      style: TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 11,
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
