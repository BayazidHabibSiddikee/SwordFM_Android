import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import '../theme/theme.dart';

/// In-app CBZ/CBR comic reader.
///
/// CBZ is a ZIP of images — opens with the archive package.
/// CBR is RAR — not extractable without native libs, shows a clear message.
/// Pages are displayed full-screen with pinch-to-zoom via InteractiveViewer.
class CbzReaderScreen extends StatefulWidget {
  final String filePath;
  const CbzReaderScreen({super.key, required this.filePath});

  @override
  State<CbzReaderScreen> createState() => _CbzReaderState();
}

class _CbzReaderState extends State<CbzReaderScreen> {
  bool _loading = true;
  String? _error;
  List<Uint8List> _pages = [];
  int _pageIndex = 0;
  bool _showOverlay = true;
  final PageController _pc = PageController();
  final TransformationController _transform = TransformationController();

  static const Set<String> _imageExts = {
    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pc.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ext = widget.filePath.toLowerCase();
    if (ext.endsWith('.cbr')) {
      setState(() {
        _loading = false;
        _error = 'CBR (RAR) archives require native RAR support.\n\n'
            'Rename the file to .cbz if it is actually a ZIP, or extract '
            'it with a file manager first.';
      });
      return;
    }
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final zip = ZipDecoder().decodeBytes(bytes);
      // Collect image entries sorted by filename (natural order). Skip
      // directories, macOS metadata, and non-image entries.
      final entries = zip.files
          .where((f) =>
              f.isFile &&
              !f.name.startsWith('__MACOSX/') &&
              _imageExts.contains(
                  '.${f.name.split('.').last.toLowerCase()}'))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      if (entries.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No images found in this archive.';
        });
        return;
      }

      final pages = <Uint8List>[];
      for (final e in entries) {
        final data = e.readBytes();
        if (data != null) pages.add(Uint8List.fromList(data));
      }
      setState(() {
        _pages = pages;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to open archive:\n$e';
      });
    }
  }

  void _toggleOverlay() => setState(() => _showOverlay = !_showOverlay);

  void _goTo(int index) {
    final target = index.clamp(0, _pages.length - 1);
    setState(() => _pageIndex = target);
    _pc.animateToPage(target,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    _transform.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.filePath.split('/').last;

    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: OneDarkColors.cyan)),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: OneDarkColors.bg,
        appBar: AppBar(
          backgroundColor: OneDarkColors.bgDark,
          title: Text(name,
              style: TextStyle(color: OneDarkColors.fg, fontSize: 14)),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!,
                style: TextStyle(color: OneDarkColors.red, fontSize: 13),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleOverlay,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Page viewer ──────────────────────────────────────────────
            PageView.builder(
              controller: _pc,
              itemCount: _pages.length,
              onPageChanged: (i) {
                setState(() => _pageIndex = i);
                _transform.value = Matrix4.identity();
              },
              itemBuilder: (_, i) => InteractiveViewer(
                transformationController:
                    i == _pageIndex ? _transform : null,
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: Image.memory(
                    _pages[i],
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.broken_image,
                      size: 64,
                      color: OneDarkColors.fgDim,
                    ),
                  ),
                ),
              ),
            ),

            // ── Overlay ──────────────────────────────────────────────────
            if (_showOverlay) ...[
              // Top bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(4, 36, 16, 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(name,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom bar
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Page counter
                      Text(
                        'Page ${_pageIndex + 1} / ${_pages.length}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      // Seek slider
                      Slider(
                        value: _pageIndex.toDouble(),
                        min: 0,
                        max: (_pages.length - 1).toDouble(),
                        divisions: _pages.length > 1
                            ? _pages.length - 1
                            : null,
                        activeColor: OneDarkColors.cyan,
                        inactiveColor: Colors.white24,
                        onChanged: (v) => _goTo(v.round()),
                      ),
                      // Prev / Next buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            onPressed: _pageIndex > 0
                                ? () => _goTo(_pageIndex - 1)
                                : null,
                            icon: const Icon(Icons.chevron_left,
                                color: Colors.white70),
                            label: const Text('Prev',
                                style: TextStyle(color: Colors.white70)),
                          ),
                          TextButton.icon(
                            onPressed: _pageIndex < _pages.length - 1
                                ? () => _goTo(_pageIndex + 1)
                                : null,
                            icon: const Icon(Icons.chevron_right,
                                color: Colors.white70),
                            label: const Text('Next',
                                style: TextStyle(color: Colors.white70)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
