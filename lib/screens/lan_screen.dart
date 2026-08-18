import 'dart:io';
import 'package:flutter/material.dart';
import '../services/web_share_server.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import 'qr_scanner_screen.dart';

/// Full LAN sharing screen with QR code, server controls, auth management,
/// share-root picker, and client-access log.
class LANSharingScreen extends StatefulWidget {
  const LANSharingScreen({super.key});

  @override
  State<LANSharingScreen> createState() => _LANSharingScreenState();
}

class _LANSharingScreenState extends State<LANSharingScreen> {
  final _server = WebShareServer();
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _startServer() async {
    setState(() => _statusMessage = 'Starting server...');
    final ip = await _server.start();
    if (ip != null) {
      setState(() {
        _statusMessage = 'Server running at http://$ip:8080';
      });
    } else {
      setState(() => _statusMessage = 'Failed to start server. Check network permissions.');
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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
                        color: _server.isRunning ? OneDarkColors.green : OneDarkColors.red,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _server.isRunning ? 'Server Running' : 'Server Stopped',
                              style: const TextStyle(color: OneDarkColors.fg, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            if (_server.currentIp != null)
                              Text(
                                'http://${_server.currentIp}:8080',
                                style: const TextStyle(color: OneDarkColors.cyan, fontSize: 13),
                              ),
                            if (_server.isRunning)
                              Text(
                                'PIN: ${_server.pin}  ·  Root: ${_server.shareRoot}',
                                style: const TextStyle(color: OneDarkColors.amber, fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_server.isRunning)
                    SizedBox(
                      width: 200,
                      height: 200,
                      child: _server.buildQrCode(),
                    ),
                  const SizedBox(height: 16),
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
                          style: FilledButton.styleFrom(backgroundColor: OneDarkColors.red),
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
                            MaterialPageRoute(builder: (_) => const QRScannerScreen()),
                          );
                          if (result != null && mounted) {
                            setState(() => _statusMessage = 'Connected to $result');
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

          // Instructions
          Card(
            color: OneDarkColors.bgDark,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How to Use',
                    style: TextStyle(color: OneDarkColors.cyan, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  _instructionStep('1. Start the server above'),
                  _instructionStep('2. Scan the QR code with another device on the same WiFi network'),
                  _instructionStep('3. Enter the PIN shown here to authenticate in the browser'),
                  _instructionStep('4. Browse, download, and upload files through the web interface'),
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
                  const Text(
                    'Security',
                    style: TextStyle(color: OneDarkColors.green, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  _securityNote('PIN-gated sessions — all file endpoints require a valid cookie'),
                  _securityNote('Upload filenames are sanitized: directory traversal rejected'),
                  _securityNote('Downloads stream from disk — no full-file memory buffering'),
                  _securityNote('Client IP access log available (tap "Clients" button)'),
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
                  Icon(Icons.info_outline, color: OneDarkColors.cyan, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_statusMessage!, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12))),
                ],
              ),
            ),
        ],
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
          Expanded(child: Text(text, style: const TextStyle(color: OneDarkColors.fg, fontSize: 13))),
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
          Expanded(child: Text(text, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 12))),
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
      leading: Icon(icon, color: isDir ? OneDarkColors.amber : OneDarkColors.fg),
      title: Text(name, style: const TextStyle(color: OneDarkColors.fg)),
      subtitle: Text(path, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
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
        actions: [
          TextButton(onPressed: _confirm, child: const Text('Select')),
        ],
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
                    style: const TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                  ),
                ),
                if (_currentPath != '/')
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: () => _navigate(Directory(_currentPath).parent.path),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<Directory>(
              future: Future.value(Directory(_currentPath)),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final dir = snapshot.data!;
                return FutureBuilder<List<DirEntry>>(
                  future: _listEntries(dir),
                  builder: (context, snap) {
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final entries = snap.data!;
                    // Sort: dirs first, then files alphabetically.
                    entries.sort((a, b) => a.isDir == b.isDir
                        ? a.name.compareTo(b.name)
                        : a.isDir ? -1 : 1);
                    return ListView.separated(
                      itemCount: entries.length + 1,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return ListTile(
                            leading: const Icon(Icons.home, color: OneDarkColors.cyan),
                            title: const Text('Home', style: TextStyle(color: OneDarkColors.fg)),
                            subtitle: Text(AppPaths.home, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
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
      return entities.map((e) => DirEntry(
        name: e.path.split('/').last,
        path: e.path,
        isDir: e is Directory,
      )).toList();
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
            ? const Text('No requests yet.', style: TextStyle(color: OneDarkColors.fgDim))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final e = entries[i];
                  final ts = e.ts is DateTime ? (e.ts as DateTime).toString().substring(11, 19) : '?';
                  return ListTile(
                    dense: true,
                    title: Text('${e.ip}  →  ${e.path}', style: const TextStyle(color: OneDarkColors.fg, fontSize: 12)),
                    subtitle: Text(e.query.isNotEmpty ? '${e.query}  $ts' : ts, style: const TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
