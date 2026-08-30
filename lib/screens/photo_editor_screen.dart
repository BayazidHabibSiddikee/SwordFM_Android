import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
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
  bool _loading = true;
  bool _saving = false;
  double _brightness = 0;
  double _contrast = 1;
  int _rotation = 0; // 0, 90, 180, 270
  bool _flipH = false;
  bool _flipV = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      _original = img.decodeImage(bytes);
      _edited = img.Image.from(_original!);
      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load image: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  void _applyEdits() {
    if (_original == null) return;
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
      result = img.adjustColor(result, brightness: _brightness / 100, contrast: _contrast);
    }

    _edited = result;
    setState(() {});
  }

  Future<void> _saveImage() async {
    if (_edited == null) return;
    setState(() => _saving = true);

    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final baseName = p.basenameWithoutExtension(widget.filePath);
      final outPath = p.join(dir.path, '${baseName}_edited.png');
      final encoded = img.encodePng(_edited!);
      await File(outPath).writeAsBytes(encoded);

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

  void _resetEdits() {
    setState(() {
      _brightness = 0;
      _contrast = 1;
      _rotation = 0;
      _flipH = false;
      _flipV = false;
      _edited = _original != null ? img.Image.from(_original!) : null;
    });
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
                    child: _edited != null
                        ? InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4,
                            child: Image.memory(
                              img.encodePng(_edited!),
                              fit: BoxFit.contain,
                            ),
                          )
                        : const Text('No image'),
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
                            (v) { setState(() => _brightness = v); _applyEdits(); },
                          )),
                          _toolButton(Icons.contrast, 'Contrast', () => _showSlider(
                            'Contrast', _contrast, 0.2, 3,
                            (v) { setState(() => _contrast = v); _applyEdits(); },
                          )),
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
