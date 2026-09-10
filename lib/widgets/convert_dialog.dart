import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../theme/theme.dart';
import '../services/doc_converter.dart';
import '../services/ocr_service.dart';

/// Dialog for converting a file. Uses the pure-Dart [DocConverter] — no
/// external runtime, no Python, no Termux, no native shell.
///
/// Text-based pipelines:
///   MD/TXT/code  → PDF, DOCX, HTML, TXT (direct)
///   DOCX         → PDF   : DOCX → MD (block-aware) → PDF
///   DOCX         → HTML  : DOCX → MD → HTML
///   DOCX         → TXT   : direct XML stripping
///   DOCX         → MD    : DocxReader block walker (preserves structure)
///   PDF          → DOCX  : PDF → MD (layout-aware) → DOCX
///   PDF          → HTML  : PDF → MD → HTML
///   PDF          → TXT   : direct content-stream extraction
///   PDF          → MD    : layout-aware Tj/TJ coordinate clustering
///
/// Image pipelines (JPEG, PNG, WebP, BMP, GIF):
///   Image        → PDF   : single-page A4 PDF wrapping the image
///   Image        → TXT   : offline OCR (Tesseract) → recognised text
class ConvertDialog extends StatefulWidget {
  final String filePath;

  const ConvertDialog({super.key, required this.filePath});

  @override
  State<ConvertDialog> createState() => _ConvertDialogState();
}

class _ConvertDialogState extends State<ConvertDialog> {
  bool _converting = false;
  String? _lastResultPath;
  String? _error;

  static const _imageExts = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'};

  bool get _isImage =>
      _imageExts.contains(p.extension(widget.filePath)
          .toLowerCase()
          .replaceFirst('.', ''));

  String _friendlyResultPath(String path) {
    if (path.startsWith('/storage/emulated/0/')) {
      return 'Phone / ${path.substring(21)}';
    }
    return path;
  }

  Future<void> _convert(String format) async {
    setState(() {
      _converting = true;
      _error = null;
      _lastResultPath = null;
    });
    try {
      final String? outPath;
      final src = widget.filePath.toLowerCase();
      final isDocx = src.endsWith('.docx');
      final isPdf = src.endsWith('.pdf');

      if (_isImage && format != 'TXT') {
        outPath = await _imageToPdf();
      } else if (_isImage && format == 'TXT') {
        outPath = await _imageToText();
      } else {
        outPath = await _textConvert(format, isDocx: isDocx, isPdf: isPdf);
      }

      if (outPath == null) {
        setState(() => _error = 'Conversion produced no output.');
        return;
      }
      setState(() => _lastResultPath = outPath);
    } catch (e) {
      setState(() => _error = 'Conversion failed: $e');
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<String?> _textConvert(
      String format, {required bool isDocx, required bool isPdf}) async {
    switch (format) {
      case 'PDF':
        if (isDocx) {
          final md = await DocConverter.toMarkdown(widget.filePath);
          return md != null ? await DocConverter.toPdf(md) : null;
        }
        return await DocConverter.toPdf(widget.filePath);
      case 'DOCX':
        if (isPdf) {
          final md = await DocConverter.toMarkdown(widget.filePath);
          return md != null ? await DocConverter.toDocx(md) : null;
        } else if (isDocx) {
          final md = await DocConverter.toMarkdown(widget.filePath);
          return md != null ? await DocConverter.toDocx(md) : null;
        }
        return await DocConverter.toDocx(widget.filePath);
      case 'HTML':
        if (isPdf || isDocx) {
          final md = await DocConverter.toMarkdown(widget.filePath);
          return md != null ? await DocConverter.markdownFileToHtml(md) : null;
        }
        return await DocConverter.markdownFileToHtml(widget.filePath);
      case 'Markdown':
      case 'MD':
        return await DocConverter.toMarkdown(widget.filePath);
      default:
        if (isDocx) {
          return await DocConverter.fromDocx(widget.filePath);
        }
        return await DocConverter.toText(widget.filePath);
    }
  }

  Future<String> _imageToPdf() async {
    final file = File(widget.filePath);
    if (!await file.exists()) throw Exception('Image not found');
    final imageBytes = await file.readAsBytes();
    final image = pw.MemoryImage(imageBytes);
    final aspect = image.width! / image.height!;
    final maxW = PdfPageFormat.a4.width;
    final pageW = aspect > maxW / PdfPageFormat.a4.height ? maxW : maxW * 0.8;
    final pageH = pageW / aspect;
    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH, marginAll: 0),
      build: (_) => pw.Center(
          child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
    final base = p.basenameWithoutExtension(widget.filePath);
    final outPath = p.join(p.dirname(widget.filePath), '$base.pdf');
    await File(outPath).writeAsBytes(await doc.save());
    return outPath;
  }

  Future<String> _imageToText() async {
    await OcrService.ensureReady();
    final text = await OcrService.extractText(widget.filePath);
    if (text.trim().isEmpty) {
      throw Exception('OCR returned no text (image may be blank)');
    }
    final base = p.basenameWithoutExtension(widget.filePath);
    final outPath = p.join(p.dirname(widget.filePath), '$base.txt');
    await File(outPath).writeAsString(text);
    return outPath;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OneDarkColors.bgDark,
      title: Text(
        _isImage ? 'Convert Image' : 'Convert File',
        style: TextStyle(color: OneDarkColors.fg),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isImage
                  ? 'Choose what to do with this image:'
                  : 'Choose an output format:',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_isImage) ...[
              _fmtRow([
                _fmtBtn('PDF', Icons.picture_as_pdf, OneDarkColors.red),
              ]),
              const SizedBox(height: 8),
              _fmtRow([
                _fmtBtn('OCR → TXT', Icons.text_fields, OneDarkColors.green),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: OneDarkColors.bg.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: OneDarkColors.fgDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'OCR copies the Tesseract language files '
                        '(~4-26 MB) on first run, then works offline.',
                        style: TextStyle(
                            color: OneDarkColors.fgDim, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              _fmtRow([
                _fmtBtn('PDF', Icons.picture_as_pdf, OneDarkColors.red),
                _fmtBtn('DOCX', Icons.description, OneDarkColors.cyan),
              ]),
              const SizedBox(height: 8),
              _fmtRow([
                _fmtBtn('HTML', Icons.html, OneDarkColors.amber),
                _fmtBtn('TXT', Icons.text_fields, OneDarkColors.green),
              ]),
              const SizedBox(height: 8),
              _fmtRow([
                _fmtBtn('Markdown', Icons.text_snippet, OneDarkColors.purple),
              ]),
            ],
            if (_converting) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: OneDarkColors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: OneDarkColors.red, fontSize: 12),
                ),
              ),
            ],
            if (_lastResultPath != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: OneDarkColors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 16, color: OneDarkColors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Saved to: ${_friendlyResultPath(_lastResultPath!)}',
                        style: TextStyle(
                            color: OneDarkColors.green, fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _openResult,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.green,
                        side: BorderSide(color: OneDarkColors.green),
                      ),
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _openResult() async {
    if (_lastResultPath == null) return;
    try {
      await OpenFile.open(_lastResultPath!);
    } catch (_) {}
  }

  Widget _fmtRow(List<Widget> children) => Row(
        children: children
            .expand((w) => [Expanded(child: w), const SizedBox(width: 8)])
            .toList()
          ..removeLast(),
      );

  Widget _fmtBtn(String label, IconData icon, Color color) =>
      OutlinedButton.icon(
        onPressed: _converting ? null : () => _convert(label),
        icon: Icon(icon, size: 18, color: color),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color),
        ),
      );
}
