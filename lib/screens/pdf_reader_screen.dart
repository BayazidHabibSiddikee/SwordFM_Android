import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import '../theme/theme.dart';

/// Full-screen PDF reader with page navigation, zoom, and go-to-page.
class PdfReaderScreen extends StatefulWidget {
  final String filePath;
  const PdfReaderScreen({super.key, required this.filePath});
  @override
  State<PdfReaderScreen> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReaderScreen> {
  PdfController? _controller;
  PdfDocument? _doc;
  int _currentPage = 1;
  int _totalPages = 0;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      _doc = doc;
      _totalPages = doc.pagesCount;
      _controller = PdfController(document: Future.value(doc));
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _doc?.close();
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
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      appBar: AppBar(
        title: Text(
          '${widget.filePath.split('/').last} (${_currentPage}/${_totalPages > 0 ? _totalPages : "?"})',
          style: const TextStyle(fontSize: 13),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: IconThemeData(color: OneDarkColors.fg),
        actions: [
          if (_totalPages > 0)
            IconButton(
              icon: Icon(
                Icons.text_fields,
                size: 20,
                color: OneDarkColors.fgDim,
              ),
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
                  Icon(Icons.error_outline, size: 48, color: OneDarkColors.red),
                  const SizedBox(height: 12),
                  Text(
                    'Cannot open PDF',
                    style: TextStyle(color: OneDarkColors.fg),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                  ),
                ],
              ),
            )
          : !_loaded
          ? Center(child: CircularProgressIndicator(color: OneDarkColors.cyan))
          : _buildReader(),
      bottomNavigationBar: _loaded
          ? Container(
              color: OneDarkColors.bgDark,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.first_page,
                      size: 20,
                      color: OneDarkColors.fgDim,
                    ),
                    onPressed: () => _jumpToPage(1),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.navigate_before,
                      size: 20,
                      color: OneDarkColors.fgDim,
                    ),
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
                      activeColor: OneDarkColors.cyan,
                      inactiveColor: OneDarkColors.border,
                      onChanged: (v) => _jumpToPage(v.round()),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.navigate_next,
                      size: 20,
                      color: OneDarkColors.fgDim,
                    ),
                    onPressed: _currentPage < _totalPages
                        ? () => _jumpToPage(_currentPage + 1)
                        : null,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.last_page,
                      size: 20,
                      color: OneDarkColors.fgDim,
                    ),
                    onPressed: () => _jumpToPage(_totalPages),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _buildReader() {
    return PdfView(
      controller: _controller!,
      onPageChanged: (page) {
        if (mounted) setState(() => _currentPage = page);
      },
      builders: PdfViewBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) =>
            Center(child: CircularProgressIndicator(color: OneDarkColors.cyan)),
        pageLoaderBuilder: (_) =>
            Center(child: CircularProgressIndicator(color: OneDarkColors.cyan)),
        errorBuilder: (context, error) => Center(
          child: Text(
            'Error: $error',
            style: TextStyle(color: OneDarkColors.fgDim),
          ),
        ),
      ),
    );
  }

  void _showGoToPageDialog() {
    final controller = TextEditingController(text: '$_currentPage');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: OneDarkColors.bg,
        title: Text('Go to page', style: TextStyle(color: OneDarkColors.fg)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: OneDarkColors.fg),
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1-$_totalPages',
            hintStyle: TextStyle(color: OneDarkColors.fgDim),
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
