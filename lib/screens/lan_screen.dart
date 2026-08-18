import 'package:flutter/material.dart';
import '../services/web_share_server.dart';
import '../theme/theme.dart';
import 'qr_scanner_screen.dart';

/// Full LAN sharing screen with QR code, server controls, and status.
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
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
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
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
                  const Text('How to Use', style: TextStyle(color: OneDarkColors.cyan, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _instructionStep('1. Start the server above'),
                  _instructionStep('2. Scan the QR code with another device on the same WiFi network'),
                  _instructionStep('3. Browse, download, and upload files through the web interface'),
                  _instructionStep('4. Stop the server when done sharing'),
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
}
