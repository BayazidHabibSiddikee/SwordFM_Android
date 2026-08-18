import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:pdfx/pdfx.dart';
import '../utils/file_utils.dart';
import '../theme/theme.dart';

/// A collapsible panel that previews the selected file.
class PreviewPanel extends StatefulWidget {
  final FileItem? item;
  final double width;
  final bool isVisible;

  const PreviewPanel({
    super.key,
    required this.item,
    required this.width,
    required this.isVisible,
  });

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  String _content = '';
  bool _loading = false;
  String? _error;
  PdfDocument? _pdfDocument;
  int _pdfPageCount = 0;
  int _currentPdfPage = 1;
  Uint8List? _pdfPageBytes;

  @override
  void didUpdateWidget(covariant PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.path != widget.item?.path ||
        !oldWidget.isVisible && widget.isVisible) {
      _loadContent();
    }
  }

  Future<void> _loadContent() async {
    if (widget.item == null) {
      setState(() { _content = ''; _error = null; _pdfDocument = null; _pdfPageBytes = null; });
      return;
    }
    setState(() { _loading = true; _content = ''; _error = null; _pdfDocument = null; _pdfPageBytes = null; });

    try {
      final path = widget.item!.path;
      if (widget.item!.isPdf) {
        final doc = await PdfDocument.openFile(path);
        if (mounted) {
          setState(() {
            _pdfDocument = doc;
            _pdfPageCount = doc.pagesCount;
            _currentPdfPage = 1;
          });
          await _renderPdfPage(doc, 1);
        }
      } else if (widget.item!.isMarkdown) {
        final file = File(path);
        if (await file.exists()) {
          _content = await file.readAsString();
        } else {
          _content = '[File not found]';
        }
      } else if (widget.item!.isText) {
        final file = File(path);
        if (await file.exists()) {
          _content = await file.readAsString();
        }
      }
    } catch (e) {
      setState(() { _error = 'Failed to load preview: $e'; });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _renderPdfPage(PdfDocument doc, int page) async {
    try {
      final pdfPage = await doc.getPage(page);
      final image = await pdfPage.render(width: 400, height: 560);
      if (mounted) {
        setState(() {
          _pdfPageBytes = image?.bytes;
        });
      }
      await pdfPage.close();
    } catch (_) {}
  }

  @override
  void dispose() {
    _pdfDocument?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (!widget.isVisible || item == null) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: widget.width,
      child: Card(
        margin: const EdgeInsets.all(8),
        color: OneDarkColors.bgDark,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(item.icon, color: item.iconColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.name,
                      style: const TextStyle(color: OneDarkColors.fg, fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {},
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: OneDarkColors.red)))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: _buildPreview(),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final item = widget.item!;
    if (item.isPdf && _pdfDocument != null) {
      return _buildPdfPreview();
    }
    if (item.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(item.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image, size: 48, color: OneDarkColors.fgDim),
        ),
      );
    }
    if (item.isMarkdown) {
      return MarkdownBody(
        data: _content,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: const TextStyle(color: OneDarkColors.fg, fontSize: 13),
          code: const TextStyle(color: OneDarkColors.amber, fontFamily: 'monospace', fontSize: 12),
          codeblockDecoration: const BoxDecoration(color: OneDarkColors.dim),
        ),
      );
    }
    if (item.isText) {
      return SelectableText(
        _content,
        style: const TextStyle(color: OneDarkColors.fg, fontSize: 12, fontFamily: 'monospace'),
      );
    }
    if (item.isDirectory) {
      return _buildMetadataCard();
    }
    return _buildMetadataCard();
  }

  Widget _buildPdfPreview() {
    return Column(
      children: [
        // Page navigation
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: _currentPdfPage > 1
                    ? () async {
                        final doc = _pdfDocument!;
                        await doc.close();
                        final newDoc = await PdfDocument.openFile(widget.item!.path);
                        setState(() { _pdfDocument = newDoc; _currentPdfPage--; });
                        await _renderPdfPage(newDoc, _currentPdfPage);
                      }
                    : null,
              ),
              Text('Page $_currentPdfPage / $_pdfPageCount',
                  style: const TextStyle(color: OneDarkColors.fg, fontSize: 12)),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                onPressed: _currentPdfPage < _pdfPageCount
                    ? () async {
                        setState(() => _currentPdfPage++);
                        await _renderPdfPage(_pdfDocument!, _currentPdfPage);
                      }
                    : null,
              ),
            ],
          ),
        ),
        // Page image
        _pdfPageBytes != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  _pdfPageBytes!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.picture_as_pdf, size: 48, color: OneDarkColors.fgDim),
                ),
              )
            : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    );
  }

  Widget _buildMetadataCard() {
    final item = widget.item!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _metaRow('Size', item.formattedSize),
        _metaRow('Modified', item.formattedDate),
        _metaRow('Type',
            item.extension.isEmpty ? 'Folder' : item.extension.toUpperCase().replaceAll('.', '')),
        _metaRow('Path', item.path),
      ],
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 70),
          Expanded(
            child: Text(value, style: const TextStyle(color: OneDarkColors.fg, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
