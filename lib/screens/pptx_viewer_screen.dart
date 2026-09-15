import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/pptx_reader.dart';
import '../theme/theme.dart';

/// In-app presentation viewer for `.pptx` files.
///
/// Shows the recovered slide outline fullscreen — one card per slide with
/// its title and body lines — instead of the old dead-drop (tap → external
/// app, which silently did nothing when no viewer was installed).
///
/// Scope is honest: this is a text outline, not a slide render. Shapes,
/// images, charts, and themes are not recovered by the pure-Dart parser;
/// the header says "outline" so nobody mistakes it for full rendering.
class PptxViewerScreen extends StatefulWidget {
  final String filePath;
  const PptxViewerScreen({super.key, required this.filePath});

  @override
  State<PptxViewerScreen> createState() => _PptxViewerScreenState();
}

class _PptxViewerScreenState extends State<PptxViewerScreen> {
  PptxOutline? _outline;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // ZIP decode + XML regex off the UI isolate (same pattern as the
      // preview panel's pptxOutlineFromPath).
      final outline = await compute(_parseOutline, widget.filePath);
      if (!mounted) return;
      setState(() {
        _outline = outline;
        _loading = false;
        if (outline.slides.isEmpty) {
          _error = 'No slides found — is this a real .pptx file?';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e'.replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.basename(widget.filePath),
              style: const TextStyle(color: Colors.black87, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
            if (_outline != null && _outline!.slides.isNotEmpty)
              Text(
                '${_outline!.slideCount} slides · outline',
                style: const TextStyle(color: Colors.black54, fontSize: 11),
              ),
          ],
        ),
        backgroundColor: Colors.grey[200],
        foregroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildSlides(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.slideshow,
              size: 48,
              color: Colors.black54,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.black54),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlides() {
    final slides = _outline!.slides;
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: slides.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final slide = slides[i];
        return Card(
          color: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.grey[300]!),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Slide ${slide.number > 0 ? slide.number : i + 1}',
                        style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (slide.title.isNotEmpty)
                  Text(
                    slide.title,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                if (slide.title.isNotEmpty && slide.lines.isNotEmpty)
                  const SizedBox(height: 6),
                for (final line in slide.lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '• ',
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: 13,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            line,
                            style: const TextStyle(
                              color: Colors.black87,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (slide.isEmpty)
                  const Text(
                    '(empty slide)',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Isolate entry point — top-level so no widget tree crosses the boundary.
PptxOutline _parseOutline(String path) => PptxReader.parse(path);
