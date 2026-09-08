import 'dart:io';
import 'package:flutter/material.dart';
import '../services/open_with_service.dart';

/// Formats that Flutter's codec can decode natively on Android.
/// SVG, HEIC, AVIF, TIFF, JXL, RAW etc. are NOT in this list — those need
/// native system apps or a codec plugin.
const _kNativeDecodable = {
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.wbmp',
};

/// Full-screen pinch-zoom image viewer.
///
/// - Natively decodable formats (JPEG, PNG, WebP, BMP, GIF): full pinch-zoom
///   with double-tap to toggle 3×, rotate button, zoom indicator.
/// - Non-decodable formats (SVG, HEIC, AVIF, TIFF, etc.): shows the file info
///   and an "Open with…" button to hand off to a system app.
/// - Black background so photos read clearly in dark rooms.
class ImageViewerScreen extends StatefulWidget {
  final String filePath;
  const ImageViewerScreen({super.key, required this.filePath});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _doubleTapDetails;
  double _rotationTurns = 0.0;
  bool _loadError = false;

  String get _fileName => widget.filePath.split('/').last;
  String get _ext =>
      _fileName.contains('.') ? '.${_fileName.split('.').last.toLowerCase()}' : '';

  bool get _isNativeDecodable => _kNativeDecodable.contains(_ext);

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  double get _currentScale => _transform.value.getMaxScaleOnAxis();

  void _handleDoubleTap() {
    final position = _doubleTapDetails?.localPosition;
    if (_currentScale > 1.5) {
      _transform.value = Matrix4.identity();
      return;
    }
    final scale = 3.0 / _currentScale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(position?.dx ?? 0.0, position?.dy ?? 0.0, 0.0, 1.0)
      ..scaleByDouble(scale, scale, 1.0, 1.0)
      ..translateByDouble(
          -(position?.dx ?? 0.0), -(position?.dy ?? 0.0), 0.0, 1.0);
  }

  void _reset() {
    setState(() => _rotationTurns = 0.0);
    _transform.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zoomed = _currentScale > 1.05 || _rotationTurns != 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          _fileName,
          style: const TextStyle(fontSize: 13, color: Colors.white),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_isNativeDecodable && !_loadError) ...[
            if (zoomed)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${(_currentScale * 100).toStringAsFixed(0)}%'
                    '${_rotationTurns == 0.0 ? '' : ' · ${(_rotationTurns.abs() * 90).toStringAsFixed(0)}°'}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.rotate_90_degrees_ccw, size: 20),
              tooltip: 'Rotate',
              onPressed: () => setState(() {
                _rotationTurns = ((_rotationTurns + 0.25) % 1.0 + 1.0) % 1.0;
              }),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Reset',
              onPressed: zoomed ? _reset : null,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 20),
            tooltip: 'Open with…',
            onPressed: () {
              try {
                OpenWithService.openDefault(widget.filePath);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: _isNativeDecodable && !_loadError
          ? _buildZoomableImage(cs)
          : _buildUnsupportedFallback(cs),
    );
  }

  Widget _buildZoomableImage(ColorScheme cs) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 0.5,
        maxScale: 8.0,
        panEnabled: true,
        child: Center(
          child: RotatedBox(
            quarterTurns: (_rotationTurns * 4).round() % 4,
            child: Image.file(
              File(widget.filePath),
              fit: BoxFit.contain,
              // No cacheWidth cap — full resolution for sharp pinch-zoom at 8×.
              errorBuilder: (context2, err, stack) {
                // Rendering failed for a format that Flutter claimed to support;
                // switch to the unsupported fallback.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _loadError = true);
                });
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnsupportedFallback(ColorScheme cs) {
    final file = File(widget.filePath);
    final size = file.existsSync()
        ? _formatSize(file.lengthSync())
        : 'unknown size';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported,
                size: 72, color: Colors.white.withValues(alpha: 0.4)),
            const SizedBox(height: 20),
            Text(
              _fileName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '${_ext.toUpperCase().replaceAll('.', '')} · $size',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              _ext == '.svg'
                  ? 'SVG files require a dedicated viewer app.'
                  : _ext == '.heic' || _ext == '.heif'
                      ? 'HEIC/HEIF files require a system gallery app.'
                      : _ext == '.avif'
                          ? 'AVIF files require a dedicated viewer app.'
                          : 'This image format cannot be rendered in-app.',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                try {
                  OpenWithService.openDefault(widget.filePath);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('No app found to open $_ext files'),
                    backgroundColor: cs.error,
                  ));
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open with…'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
