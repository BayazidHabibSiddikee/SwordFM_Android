import 'package:flutter/material.dart';
import '../services/ftp_server_service.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart';
import '../utils/constants.dart' show AppPaths;
import 'lan_screen.dart' show ShareRootPickerScreen;

/// FTP server mode — lets a PC on the same network browse the phone's
/// storage with any FTP client (Windows Explorer, FileZilla, curl, …).
class FtpServerScreen extends StatefulWidget {
  const FtpServerScreen({super.key});

  @override
  State<FtpServerScreen> createState() => _FtpServerScreenState();
}

class _FtpServerScreenState extends State<FtpServerScreen> {
  late final FtpServerService _server = FtpServerService();
  bool _starting = false;
  String? _status;
  String _shareRoot = AppPaths.home;

  Future<void> _toggle() async {
    if (_server.isRunning) {
      await _server.stop();
      setState(() => _status = 'Server stopped.');
      return;
    }
    setState(() => _starting = true);
    await _server.start(shareRootOverride: _shareRoot);
    if (mounted) {
      setState(() {
        _starting = false;
        _status = _server.isRunning
            ? 'Running at ftp://${_server.currentIp ?? '—'}:${_server.port}'
            : 'Failed to start — check network permissions.';
      });
    }
  }

  Future<void> _pickRoot() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const ShareRootPickerScreen(initialPath: ''),
      ),
    );
    if (result != null && mounted) {
      setState(() => _shareRoot = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('FTP Server', style: TextStyle(fontSize: 16)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                          color: _server.isRunning
                              ? OneDarkColors.green
                              : OneDarkColors.fgDim,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _server.isRunning ? 'FTP Server Active' : 'FTP Server',
                          style: TextStyle(
                            color: _server.isRunning
                                ? OneDarkColors.green
                                : OneDarkColors.fg,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_status != null) ...[
                      Text(
                        _status!,
                        style: TextStyle(
                          color: _server.isRunning
                              ? OneDarkColors.cyan
                              : OneDarkColors.fgDim,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Icon(Icons.folder, size: 16, color: OneDarkColors.fgDim),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Root: $_shareRoot',
                            style: TextStyle(
                              color: OneDarkColors.fgDim,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: _pickRoot,
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _starting ? null : _toggle,
                        icon: Icon(
                          _server.isRunning
                              ? Icons.stop
                              : Icons.play_arrow,
                          size: 18,
                        ),
                        label: Text(_server.isRunning ? 'Stop Server' : 'Start Server'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'How to connect',
              style: TextStyle(
                color: OneDarkColors.cyan,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'On a PC on the same Wi-Fi, open any FTP client and connect to\n'
              'ftp://<phone IP>:2121\n\n'
              'Any username and password are accepted. Files are served from '
              'the share root above; navigation outside it is blocked.\n\n'
              'Windows Explorer: type the ftp:// address in the address bar.\n'
              'FileZilla: use Host=<IP>, Port=2121, Quickconnect.',
              style: TextStyle(
                color: OneDarkColors.fgDim,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
