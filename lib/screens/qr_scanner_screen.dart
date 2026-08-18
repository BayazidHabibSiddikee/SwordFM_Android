import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../theme/theme.dart';

/// QR Scanner screen for receiving files from LAN sharing.
/// Scans the QR code shown by a running SwordFM LAN share session
/// and opens the web UI URL with auto-fill PIN.
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  String? _lastResult;

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final String code = barcodes.first.rawValue ?? '';
    setState(() => _lastResult = code);

    // Parse QR content — expected format: http://IP:8080
    Uri? url;
    try {
      url = Uri.parse(code);
    } catch (_) {}

    if (url != null && url.scheme.isNotEmpty) {
      Navigator.pop(context, code);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid QR code format'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildCameraView() {
    return SizedBox(
      width: double.infinity,
      height: 300,
      child: MobileScanner(
        onDetect: _handleBarcode,
        controller: MobileScannerController(
          detectionSpeed: DetectionSpeed.noDuplicates,
          facing: CameraFacing.back,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: OneDarkColors.fg),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      backgroundColor: OneDarkColors.bg,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: OneDarkColors.cyan, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _buildCameraView(),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Point camera at a SwordFM QR code',
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
                ),
                if (_lastResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: OneDarkColors.dim,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: OneDarkColors.green, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _lastResult!,
                            style: const TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
