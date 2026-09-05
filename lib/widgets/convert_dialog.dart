import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import '../theme/theme.dart';
import '../services/doc_converter.dart';

/// Dialog for converting a file. Uses the pure-Dart [DocConverter] — no
/// external runtime, no Python, no Termux. The trade-off is honest:
/// DOCX output is text-only (no embedded images or layout fidelity), and
/// PDF→DOCX is the same text-extraction path that's been in the app
/// since v1. What this gains: works on every device, no install
/// prompts, no failures.
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

  Future<void> _convert(String format) async {
    setState(() {
      _converting = true;
      _error = null;
      _lastResultPath = null;
    });
    try {
      final String? outPath;
      switch (format) {
        case 'PDF':
          outPath = await DocConverter.toPdf(widget.filePath);
          break;
        case 'DOCX':
          outPath = await DocConverter.toDocx(widget.filePath);
          break;
        case 'HTML':
          outPath = await DocConverter.markdownFileToHtml(widget.filePath);
          break;
        default: // TXT
          if (widget.filePath.toLowerCase().endsWith('.docx')) {
            outPath = await DocConverter.fromDocx(widget.filePath);
          } else if (widget.filePath.toLowerCase().endsWith('.pdf')) {
            outPath = await DocConverter.fromPdf(widget.filePath);
          } else {
            outPath = await DocConverter.toText(widget.filePath);
          }
          break;
      }
      if (outPath != null) {
        if (mounted) setState(() => _lastResultPath = outPath);
      } else {
        if (mounted) {
          setState(() => _error =
              'Conversion failed — the source may be empty, encrypted, '
              'or the output folder is not writable. Try saving to SwordFM '
              'Downloads.');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _openResult() async {
    if (_lastResultPath == null) return;
    try {
      final result = await OpenFile.open(_lastResultPath!);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file (${result.message})'),
            backgroundColor: OneDarkColors.red,
          ),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final baseName = widget.filePath
        .split('/')
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    // PDF sources convert via text extraction: TXT (raw text), DOCX and
    // HTML (extracted text re-rendered through the shared markdown
    // pipeline). PDF→PDF is excluded — the source is already a PDF.
    final isPdfSource = widget.filePath.toLowerCase().endsWith('.pdf');
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: Text(
        'Convert $baseName',
        style: TextStyle(color: OneDarkColors.cyan),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose output format:',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (isPdfSource) ...[
              // PDF source: convert its extracted text to DOCX/HTML/TXT.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('DOCX'),
                      icon: Icon(
                        Icons.description,
                        size: 18,
                        color: OneDarkColors.cyan,
                      ),
                      label: const Text('DOCX'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.cyan,
                        side: BorderSide(color: OneDarkColors.cyan),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('HTML'),
                      icon: Icon(
                        Icons.html,
                        size: 18,
                        color: OneDarkColors.amber,
                      ),
                      label: const Text('HTML'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.amber,
                        side: BorderSide(color: OneDarkColors.amber),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('TXT'),
                      icon: Icon(
                        Icons.text_fields,
                        size: 18,
                        color: OneDarkColors.green,
                      ),
                      label: const Text('TXT'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.green,
                        side: BorderSide(color: OneDarkColors.green),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('PDF'),
                      icon: Icon(
                        Icons.picture_as_pdf,
                        size: 18,
                        color: OneDarkColors.red,
                      ),
                      label: const Text('PDF'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.red,
                        side: BorderSide(color: OneDarkColors.red),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('DOCX'),
                      icon: Icon(
                        Icons.description,
                        size: 18,
                        color: OneDarkColors.cyan,
                      ),
                      label: const Text('DOCX'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.cyan,
                        side: BorderSide(color: OneDarkColors.cyan),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('HTML'),
                      icon: Icon(
                        Icons.html,
                        size: 18,
                        color: OneDarkColors.amber,
                      ),
                      label: const Text('HTML'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.amber,
                        side: BorderSide(color: OneDarkColors.amber),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _converting ? null : () => _convert('TXT'),
                      icon: Icon(
                        Icons.text_fields,
                        size: 18,
                        color: OneDarkColors.green,
                      ),
                      label: const Text('TXT'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: OneDarkColors.green,
                        side: BorderSide(color: OneDarkColors.green),
                      ),
                    ),
                  ),
                ],
              ),
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
                    Icon(
                      Icons.check_circle,
                      size: 16,
                      color: OneDarkColors.green,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Saved to: $_lastResultPath',
                        style: TextStyle(
                          color: OneDarkColors.green,
                          fontSize: 11,
                        ),
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
}
