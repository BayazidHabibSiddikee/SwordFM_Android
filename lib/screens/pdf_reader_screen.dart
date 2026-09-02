import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Full-screen PDF reader with page navigation, pinch-to-zoom, and go-to-page.
///
/// Implementation note: previous versions of this screen used
/// `PdfViewPinch` directly, but that widget renders blank on some
/// Flutter/Pdfium combinations on Android 14+. We now pre-render each
/// page to a PNG using the same `page.render()` path the preview panel
/// uses, and display them in a `PageView` with `InteractiveViewer`
/// for pinch-zoom. This is more reliable and gives a real scrollable
/// reader.
///
/// Uses the active Material [ColorScheme] instead of hard-coded colors
/// so the reader matches the rest of the app in dark or cream/light
/// theme.
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});
  @override
  State<PdfReaderScreen> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReaderScreen> {
  int _currentPage = 1;
  int _totalPages = 0;
  bool _loaded = false;
  String? _error;
  /// File-system paths to per-page PNG renders. Each entry corresponds
  /// to a page number (1-based: _pageRenders[0] is page 1).
  final List<String> _pageRenders = [];
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadPdf() async {
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      _totalPages = doc.pagesCount;
      // Render every page once at a generous size. 1080px wide gives
      // crisp text even on tablets; phone panels won't use the full
      // resolution but the file size is still modest (~200-500 KB per
      // page for typical PDFs).
      final tmp = await Directory.systemTemp.createTemp('swordfm_pdf_read_');
      for (var i = 1; i <= _totalPages; i++) {
        final page = await doc.getPage(i);
        final png = await page.render(
          width: 1080,
          height: (page.height * 1080 / page.width),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        await page.close();
        if (png == null || png.bytes.isEmpty) continue;
        final out = File('${tmp.path}/page$i.png');
        await out.writeAsBytes(png.bytes);
        _pageRenders.add(out.path);
      }
      await doc.close();
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _jumpToPage(int page) {
    if (page < 1 || page > _totalPages) return;
    if (page == _currentPage) return;
    setState(() => _currentPage = page);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        page - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(
          '${widget.filePath.split('/').last} (${_currentPage}/${_totalPages > 0 ? _totalPages : "?"})',
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: cs.surfaceContainerHighest,
        foregroundColor: cs.onSurface,
        iconTheme: IconThemeData(color: cs.onSurface),
        actions: [
          if (_totalPages > 0)
            IconButton(
              icon: Icon(Icons.text_fields, size: 20, color: cs.onSurfaceVariant),
              tooltip: 'Go to page',
              onPressed: _showGoToPageDialog,
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: cs.error),
                    const SizedBox(height: 12),
                    Text(
                      'Cannot open PDF',
                      style: TextStyle(color: cs.onSurface),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : !_loaded
              ? Center(child: CircularProgressIndicator(color: cs.primary))
              : _pageRenders.isEmpty
                  ? Center(
                      child: Text(
                        'This PDF has no renderable pages.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : _buildReader(cs),
      bottomNavigationBar: _loaded && _pageRenders.isNotEmpty
          ? Container(
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.first_page,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: () => _jumpToPage(1),
                  ),
                  IconButton(
                    icon: Icon(Icons.navigate_before,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: _currentPage > 1
                        ? () => _jumpToPage(_currentPage - 1)
                        : null,
                  ),
                  Expanded(
                    child: Slider(
                      value: _currentPage.toDouble(),
                      min: 1,
                      max: _totalPages.toDouble(),
                      divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                      activeColor: cs.primary,
                      inactiveColor: cs.outlineVariant,
                      onChanged: (v) => _jumpToPage(v.round()),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.navigate_next,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: _currentPage < _totalPages
                        ? () => _jumpToPage(_currentPage + 1)
                        : null,
                  ),
                  IconButton(
                    icon: Icon(Icons.last_page,
                        size: 20, color: cs.onSurfaceVariant),
                    onPressed: () => _jumpToPage(_totalPages),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  /// PageView of all pre-rendered pages with pinch-zoom on each.
  Widget _buildReader(ColorScheme cs) {
    return PageView.builder(
      controller: _pageController,
      itemCount: _pageRenders.length,
      onPageChanged: (idx) {
        if (mounted) setState(() => _currentPage = idx + 1);
      },
      itemBuilder: (context, idx) {
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 6.0,
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Image.file(
                File(_pageRenders[idx]),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image,
                          size: 48, color: cs.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(
                        'Page ${idx + 1} could not be rendered',
                        style:
                            TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showGoToPageDialog() {
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(text: '$_currentPage');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Go to page', style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: cs.onSurface),
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1-$_totalPages',
            hintStyle: TextStyle(color: cs.onSurfaceVariant),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null) _jumpToPage(page);
              Navigator.pop(context);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }
}
