import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/doc_converter.dart';
import '../theme/theme.dart';

/// Batch conversion dialog: converts several files to one output format.
///
/// Only convertible sources (per [DocConverter.canConvert]) participate;
/// anything else is filtered before the dialog opens and reported in the
/// summary. Conversions run sequentially with a progress bar; per-file
/// results list output paths and failures.
class BatchConvertDialog extends StatefulWidget {
  final List<String> filePaths;

  const BatchConvertDialog({super.key, required this.filePaths});

  @override
  State<BatchConvertDialog> createState() => _BatchConvertDialogState();
}

class _BatchConvertDialogState extends State<BatchConvertDialog> {
  late final List<String> _sources;
  String _format = 'PDF';
  bool _running = false;
  int _done = 0;
  int _total = 0;
  List<BatchConvertResult> _results = [];

  @override
  void initState() {
    super.initState();
    // Keep input order; drop anything the converter can't read so one stray
    // binary doesn't fail the whole batch.
    _sources = widget.filePaths.where(DocConverter.canConvert).toList();
  }

  int get _skipped => widget.filePaths.length - _sources.length;

  Future<void> _run() async {
    if (_running || _sources.isEmpty) return;
    setState(() {
      _running = true;
      _done = 0;
      _total = _sources.length;
      _results = [];
    });
    final results = await DocConverter.convertBatch(
      _sources,
      _format,
      onProgress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );
    if (mounted) {
      setState(() {
        _results = results;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final okCount = _results.where((r) => r.ok).length;
    return AlertDialog(
      backgroundColor: OneDarkColors.bgDark,
      title: Text(
        'Batch convert (${_sources.length} files)',
        style: TextStyle(color: OneDarkColors.fg),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_skipped > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$_skipped file(s) skipped — not convertible in-app.',
                  style: TextStyle(color: OneDarkColors.amber, fontSize: 12),
                ),
              ),
            // Format picker
            Wrap(
              spacing: 8,
              children: DocConverter.outputFormats.map((f) {
                final selected = f == _format;
                return ChoiceChip(
                  label: Text(f),
                  selected: selected,
                  onSelected: _running
                      ? null
                      : (_) => setState(() => _format = f),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            if (_running) ...[
              LinearProgressIndicator(
                value: _total > 0 ? _done / _total : null,
              ),
              const SizedBox(height: 8),
              Text(
                'Converting $_done of $_total…',
                style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              ),
            ],
            if (!_running && _results.isNotEmpty) ...[
              Text(
                '$okCount of ${_results.length} converted.',
                style: TextStyle(
                  color: okCount == _results.length
                      ? OneDarkColors.green
                      : OneDarkColors.amber,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: _results.map((r) {
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          r.ok ? Icons.check_circle : Icons.error,
                          size: 18,
                          color: r.ok
                              ? OneDarkColors.green
                              : OneDarkColors.red,
                        ),
                        title: Text(
                          p.basename(r.sourcePath),
                          style: TextStyle(
                            color: OneDarkColors.fg,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          r.ok
                              ? '→ ${p.basename(r.outputPath!)}'
                              : (r.error ?? 'Failed'),
                          style: TextStyle(
                            color: OneDarkColors.fgDim,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        // Closing mid-run does not cancel: conversions already write their
        // outputs next to the sources, so finished files are kept.
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (!_running)
          FilledButton.icon(
            onPressed: _sources.isEmpty ? null : _run,
            icon: const Icon(Icons.transform, size: 18),
            label: Text(
              _results.isEmpty ? 'Convert' : 'Convert again',
            ),
          ),
      ],
    );
  }
}
