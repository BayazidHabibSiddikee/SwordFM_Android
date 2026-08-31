import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import '../theme/theme.dart';

/// Basic photo editor with rotate, flip, brightness, contrast, and crop tools.
class PhotoEditorScreen extends StatefulWidget {
  final String filePath;
  const PhotoEditorScreen({super.key, required this.filePath});
  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorState();
}

class _PhotoEditorState extends State<PhotoEditorScreen> {
  img.Image? _original;
  img.Image? _edited;

  // Pre-encoded preview bytes for the InteractiveViewer. Encoding the full
  // image on every edit is far too slow for large photos (blocks the UI for
  // seconds). We keep a *downscaled* JPEG preview that refreshes quickly, and
  // only re-encode it when the edits (params) actually change.
  Uint8List? _previewBytes;
  bool _loading = true;
  bool _saving = false;

  // Keep the last-applied params so we can avoid redundant re-encodes.
  int _lastAppliedRotation = 0;
  bool _lastAppliedFlipH = false;
  bool _lastAppliedFlipV = false;
  double _lastAppliedBrightness = 0;
  double _lastAppliedContrast = 1;
  bool _lastAppliedCrop = false;
  int _lastAppliedCropX = 0;
  int _lastAppliedCropY = 0;
  int _lastAppliedCropW = 0;
  int _lastAppliedCropH = 0;

  // Active (pending) edit params — slider drags update these live.
  double _brightness = 0;
  double _contrast = 1;
  int _rotation = 0; // 0, 90, 180, 270
  bool _flipH = false;
  bool _flipV = false;
  int _cropX = 0;
  int _cropY = 0;
  int _cropW = 0;
  int _cropH = 0;
  bool _hasCrop = false;

  // Debounce timer for slider-driven preview refreshes so we don't re-encode
  // on every pixel of slider movement.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Loads the full-res original once, then prepares a small preview.
  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      // Decode the original in the background so a big photo doesn't block
      // the UI thread while loading.
      final decoded = await compute(_decodeImage, bytes);
      if (decoded == null) {
        throw Exception('Unsupported image format');
      }
      _original = decoded;
      _edited = img.Image.from(_original!);
      _rebuildPreview();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load image: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  /// Decode helper for [compute] (top-level so it can be spawned in an isolate).
  static img.Image? _decodeImage(Uint8List bytes) {
    try {
      return img.decodeImage(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Applies the pending transforms to a copy of the original (runs off the
  /// UI thread when possible) and returns the edited image.
  Future<img.Image> _applyEditsToImage() async {
    var result = img.Image.from(_original!);

    // Rotate
    if (_rotation == 90) result = img.copyRotate(result, angle: 90);
    else if (_rotation == 180) result = img.copyRotate(result, angle: 180);
    else if (_rotation == 270) result = img.copyRotate(result, angle: 270);

    // Flip
    if (_flipH) result = img.flipHorizontal(result);
    if (_flipV) result = img.flipVertical(result);

    // Brightness & Contrast
    if (_brightness != 0 || _contrast != 1) {
      result = img.adjustColor(
        result,
        brightness: _brightness / 100,
        contrast: _contrast,
      );
    }

    // Crop
    if (_hasCrop && _cropW > 0 && _cropH > 0) {
      result = img.copyCrop(
        result,
        x: _cropX,
        y: _cropY,
        width: _cropW,
        height: _cropH,
      );
    }

    return result;
  }

  bool _paramsChanged() {
    return _rotation != _lastAppliedRotation ||
        _flipH != _lastAppliedFlipH ||
        _flipV != _lastAppliedFlipV ||
        _brightness != _lastAppliedBrightness ||
        _contrast != _lastAppliedContrast ||
        _hasCrop != _lastAppliedCrop ||
        _cropX != _lastAppliedCropX ||
        _cropY != _lastAppliedCropY ||
        _cropW != _lastAppliedCropW ||
        _cropH != _lastAppliedCropH;
  }

  /// Recomputes the full-res edited image and a downscaled JPEG preview,
  /// off the UI thread. Called debounced during slider drags, and
  /// immediately after discrete edits (rotate/flip/crop).
  void _rebuildPreview() {
    if (_original == null) return;
    if (!_paramsChanged()) return;
    _edited = null; // free memory while working
    setState(() {});

    Future(() async {
      final edited = await _applyEditsToImage();
      if (!mounted) { edited.clear(); return; }
      final bytes = await compute(_encodePreview, edited);
      if (!mounted) return;
      setState(() {
        _edited = edited;
        _previewBytes = bytes;
        _lastAppliedRotation = _rotation;
        _lastAppliedFlipH = _flipH;
        _lastAppliedFlipV = _flipV;
        _lastAppliedBrightness = _brightness;
        _lastAppliedContrast = _contrast;
        _lastAppliedCrop = _hasCrop;
        _lastAppliedCropX = _cropX;
        _lastAppliedCropY = _cropY;
        _lastAppliedCropW = _cropW;
        _lastAppliedCropH = _cropH;
      });
    });
  }

  /// Top-level encode helper for [compute].
  static Uint8List _encodePreview(img.Image image) {
    // Downscale aggressively for the on-screen preview — the actual save
    // later re-encodes the full-res image. This makes the editor feel
    // instant even for 10MP+ photos.
    var preview = image;
    const maxDim = 900;
    if (max(preview.width, preview.height) > maxDim) {
      final scale = maxDim / max(preview.width, preview.height);
      preview = img.copyResize(
        preview,
        width: (preview.width * scale).round(),
        height: (preview.height * scale).round(),
      );
    }
    final bytes = img.encodeJpg(preview, quality: 80);
    if (preview != image) preview.clear();
    return bytes;
  }

  /// Callback used by discrete tool buttons — recompute immediately.
  void _applyEdits() {
    _debounce?.cancel();
    _rebuildPreview();
  }

  /// Callback used by continuous sliders — recompute after a short pause.
  void _applyEditsDebounced() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _rebuildPreview);
  }

  Future<void> _saveImage() async {
    if (_edited == null) return;
    setState(() => _saving = true);

    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final baseName = p.basenameWithoutExtension(widget.filePath);
      final outPath = p.join(dir.path, '${baseName}_edited.png');
      // Encode the full-res edited image in the background so a large photo
      // doesn't freeze the UI while saving.
      final full = await compute(_encodeFullImage, _edited!);
      if (full == null) throw Exception('encode failed');
      await File(outPath).writeAsBytes(full);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${p.basename(outPath)}'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () => OpenFile.open(outPath),
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: OneDarkColors.red),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  /// Encodes the full-res edited image as PNG (isolate-friendly top-level fn).
  static Uint8List? _encodeFullImage(img.Image image) {
    try {
      return img.encodePng(image);
    } catch (_) {
      return null;
    }
  }

  void _resetEdits() {
    setState(() {
      _brightness = 0;
      _contrast = 1;
      _rotation = 0;
      _flipH = false;
      _flipV = false;
      _hasCrop = false;
      _edited = null;
      _previewBytes = null;
      _lastAppliedRotation = 0;
      _lastAppliedFlipH = false;
      _lastAppliedFlipV = false;
      _lastAppliedBrightness = 0;
      _lastAppliedContrast = 1;
      _lastAppliedCrop = false;
      _lastAppliedCropX = 0;
      _lastAppliedCropY = 0;
      _lastAppliedCropW = 0;
      _lastAppliedCropH = 0;
    });
    _applyEdits();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        leading: IconButton(
          icon: Icon(Icons.close, color: OneDarkColors.fg),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          p.basename(widget.filePath),
          style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: OneDarkColors.fgDim),
            onPressed: _resetEdits,
            tooltip: 'Reset',
          ),
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: Icon(Icons.save, color: OneDarkColors.green),
                  onPressed: _saveImage,
                  tooltip: 'Save',
                ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: OneDarkColors.cyan))
          : Column(
              children: [
                // Image preview
                Expanded(
                  child: Center(
                    child: _previewBytes != null
                        ? InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4,
                            child: Image.memory(
                              _previewBytes!,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          )
                        : _loading
                            ? Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: OneDarkColors.cyan,
                                ),
                              )
                            : const SizedBox.shrink(),
                  ),
                ),
                // Tool bar
                Container(
                  color: OneDarkColors.bgDark,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Row 1: Transform tools
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _toolButton(Icons.rotate_right, 'Rotate', () {
                            setState(() => _rotation = (_rotation + 90) % 360);
                            _applyEdits();
                          }),
                          _toolButton(Icons.flip, 'Flip H', () {
                            setState(() => _flipH = !_flipH);
                            _applyEdits();
                          }),
                          _toolButton(Icons.flip_camera_android, 'Flip V', () {
                            setState(() => _flipV = !_flipV);
                            _applyEdits();
                          }),
                          _toolButton(Icons.brightness_6, 'Bright', () => _showSlider(
                            'Brightness', _brightness, -100, 100,
                            (v) { setState(() => _brightness = v); _applyEditsDebounced(); },
                          )),
                          _toolButton(Icons.contrast, 'Contrast', () => _showSlider(
                            'Contrast', _contrast, 0.2, 3,
                            (v) { setState(() => _contrast = v); _applyEditsDebounced(); },
                          )),
                          _toolButton(Icons.crop, 'Crop', _showCropDialog),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: OneDarkColors.cyan, size: 22),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10)),
        ],
      ),
    );
  }

  void _showCropDialog() {
    if (_original == null) return;
    final w = _hasCrop ? _cropW : _original!.width;
    final h = _hasCrop ? _cropH : _original!.height;
    final x = _hasCrop ? _cropX : 0;
    final y = _hasCrop ? _cropY : 0;

    showDialog(
      context: context,
      builder: (ctx) {
        double xFrac = x / w;
        double yFrac = y / h;
        double wFrac = 1 - xFrac;
        double hFrac = 1 - yFrac;
        return AlertDialog(
          backgroundColor: OneDarkColors.bgDark,
          title: Text('Crop', style: TextStyle(color: OneDarkColors.fg)),
          content: StatefulBuilder(
            builder: (ctx, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Area: ${(wFrac * 100).round()}% × ${(hFrac * 100).round()}%',
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  _cropSlider('Left edge', xFrac, 0, 1, (v) {
                    setDialogState(() => xFrac = v);
                  }),
                  _cropSlider('Top edge', yFrac, 0, 1, (v) {
                    setDialogState(() => yFrac = v);
                  }),
                  _cropSlider('Width', wFrac, 0.1, 1, (v) {
                    setDialogState(() => wFrac = v);
                  }),
                  _cropSlider('Height', hFrac, 0.1, 1, (v) {
                    setDialogState(() => hFrac = v);
                  }),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: OneDarkColors.fgDim)),
            ),
            FilledButton(
              onPressed: () {
                final ox = _original!.width;
                final oy = _original!.height;
                setState(() {
                  _cropX = (xFrac * ox).round().clamp(0, ox - 1);
                  _cropY = (yFrac * oy).round().clamp(0, oy - 1);
                  _cropW = (wFrac * ox).round().clamp(1, ox - _cropX);
                  _cropH = (hFrac * oy).round().clamp(1, oy - _cropY);
                  _hasCrop = true;
                });
                _applyEdits();
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }

  Widget _cropSlider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(label, style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            activeColor: OneDarkColors.cyan,
            inactiveColor: OneDarkColors.dim,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '${(value * 100).round()}%',
            style: TextStyle(color: OneDarkColors.fgDim, fontSize: 10),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  void _showSlider(String title, double value, double min, double max, ValueChanged<double> onChanged) {
    showModalBottomSheet(
      context: context,
      backgroundColor: OneDarkColors.bgDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: TextStyle(color: OneDarkColors.fg, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            StatefulBuilder(
              builder: (ctx, setModalState) {
                return Slider(
                  value: value,
                  min: min,
                  max: max,
                  activeColor: OneDarkColors.cyan,
                  onChanged: (v) {
                    setModalState(() => value = v);
                    onChanged(v);
                  },
                );
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Done', style: TextStyle(color: OneDarkColors.cyan)),
            ),
          ],
        ),
      ),
    );
  }
}
