import 'dart:io';
import 'package:flutter/material.dart';

/// Full-screen pinch-zoom image viewer.
///
/// - Pinch to zoom (1×-6×), drag to pan when zoomed.
/// - Double-tap toggles between 1× and 3× anchored at the tap point.
/// - Zoom % indicator while zoomed; double-tap zooms back out.
/// - Rotate button (90° steps) for photos shot sideways.
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

  String get _fileName => widget.filePath.split('/').last;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  double get _currentScale {
    final m = _transform.value;
    return m.getMaxScaleOnAxis();
  }

  void _handleDoubleTap() {
    final position = _doubleTapDetails?.localPosition;
    final current = _currentScale;
    Matrix4 target;
    if (current > 1.5) {
      // Zoomed in → reset to fit.
      _transform.value = Matrix4.identity();
      return;
    }
    // Zoom in to 3× anchored at the tapped point.
    final scale = 3.0 / current;
    target = Matrix4.identity()
      ..translateByDouble(
          position?.dx ?? 0.0, position?.dy ?? 0.0, 0.0, 1.0)
      ..scaleByDouble(scale, scale, 1.0, 1.0)
      ..translateByDouble(
          -(position?.dx ?? 0.0), -(position?.dy ?? 0.0), 0.0, 1.0);
    _transform.value = target;
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
          if (zoomed)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${(_currentScale * 100).toStringAsFixed(0)}%'
                  '${_rotationTurns == 0.0 ? '' : ' · ${(_rotationTurns.abs() * 90).toStringAsFixed(0)}°'}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.rotate_90_degrees_ccw, size: 20),
            tooltip: 'Rotate',
            onPressed: () => setState(() {
              _rotationTurns =
                  ((_rotationTurns + 0.25) % 1.0 + 1.0) % 1.0;
            }),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Reset',
            onPressed: zoomed ? _reset : null,
          ),
        ],
      ),
      body: GestureDetector(
        onDoubleTapDown: (d) => _doubleTapDetails = d,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1.0,
          maxScale: 6.0,
          panEnabled: true,
          child: Center(
            child: RotatedBox(
              quarterTurns: (_rotationTurns * 4).round() % 4,
              child: Image.file(
                File(widget.filePath),
                fit: BoxFit.contain,
                // No cacheWidth cap here — full resolution so pinch-zoom
                // stays sharp even at 6×.
                errorBuilder: (_, _, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image,
                        size: 48, color: cs.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(
                      'Cannot display image',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}