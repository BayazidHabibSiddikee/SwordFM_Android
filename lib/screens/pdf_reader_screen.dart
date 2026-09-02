import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Full-screen PDF reader with page navigation, pinch-to-zoom, and go-to-page.
///
/// Uses the active Material [ColorScheme] (like the rest of the app) instead
/// of the hard-coded One-Dark palette so the reader matches whichever theme
/// (dark or cream/light, with dynamic color blending) is currently active.
/// Pinch-to-zoom is provided by [PdfViewPinch] for a smooth full-screen
/// reading experience (the plain [PdfView] did not support zoom).
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});
  @override
  State<PdfReaderScreen> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReaderScreen> {
  PdfControllerPinch? _controller;
  int _currentPage = 1;
  int _totalPages = 0;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPdf();
    // Update the page count from the controller once the document finishes
    // loading. PdfControllerPinch exposes pagesCount which goes from null
    // to a real number when the Future resolves.
    () async {
      // Spin until the controller has a real page count.
      while (mounted && (_controller?.pagesCount ?? 0) <= 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (mounted) setState(() => _totalPages = _controller!.pagesCount!);
    }();
  }

  Future<void> _loadPdf() async {
    try {
      // Hand the controller a Future that opens the file itself, and let
      // it own the document lifetime. We don't pre-open or pre-resolve the
      // page count — the controller's _loadDocument does `_state!._releasePages()`
      // which would crash if we passed it an already-resolved doc. Instead
      // the controller's loading state listener drives UI state via the
      // loadingState ValueNotifier.
      _controller = PdfControllerPinch(
        document: PdfDocument.openFile(widget.filePath),
      );
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _jumpToPage(int page) {
    if (_controller != null && page >= 1 && page <= _totalPages) {
      _controller!.jumpToPage(page);
      setState(() => _currentPage = page);
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
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            )
          : !_loaded
          ? Center(
              child: CircularProgressIndicator(color: cs.primary),
            )
          : _buildReader(cs),
      bottomNavigationBar: _loaded
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
                    onPressed:
                        _currentPage > 1 ? () => _jumpToPage(_currentPage - 1) : null,
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

    Widget _buildReader(ColorScheme cs) {
    // PdfViewPinch renders each page at full resolution with pinch-to-zoom.
    // The background matches the active theme so the reader is consistent
    // across dark / light modes (no hard-coded One-Dark colors).
    return PdfViewPinch(
      controller: _controller!,
      onPageChanged: (page) {
        if (mounted) setState(() => _currentPage = page);
      },
      backgroundDecoration: BoxDecoration(color: cs.surface),
      padding: 8,
      minScale: 1.0,
      maxScale: 8.0,
      builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) =>
            Center(child: CircularProgressIndicator(color: cs.primary)),
        pageLoaderBuilder: (_) =>
            Center(child: CircularProgressIndicator(color: cs.primary)),
        errorBuilder: (context, error) => Center(
          child: Text(
            'Error: $error',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ),
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
