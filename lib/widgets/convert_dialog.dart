import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/theme.dart';
import '../services/doc_converter.dart';
import '../services/conversion_tool_service.dart';
import 'package:path/path.dart' as p;

/// Dialog for converting a markdown/text file to PDF or DOCX.
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
  // Full toolchain status — drives the install button and engine chip.
  ToolchainStatus? _status;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final s = await ConversionToolService().status();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _runInstall() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final msg = await ConversionToolService().installMissing();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Install error: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _installing = false);
        // Re-probe a few seconds later — the install runs in Termux in the
        // background. The user can also pull-to-refresh by re-opening.
        Future.delayed(const Duration(seconds: 4), _refreshStatus);
      }
    }
  }

  Future<void> _openPlayStore() async {
    // Reuse the same launch pattern as the terminal screen.
    final uri = Uri.parse(
        'https://play.google.com/store/apps/details?id=com.termux');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _convert(String format) async {
    setState(() {
      _converting = true;
      _error = null;
      _lastResultPath = null;
    });
    try {
      // Try the high-fidelity Termux/Python engine first (Phase 10 plan). It
      // covers PDF→DOCX/HTML/TXT etc. with a real editable re-layout, far
      // better than the pure-Dart string-slicing for PDF. Any failure
      // (Termux not installed, missing python module, error in script) is
      // returned as null, and we fall back to the existing DocConverter so
      // the dialog never regresses offline / no-Termux.
      final tool = ConversionToolService();
      final toolAvailable = await tool.isAvailable();
      if (toolAvailable) {
        final outExt = _extFor(format);
        final outPath = _resolveOutPath(widget.filePath, outExt);
        final toolResult = await tool.convert(
          target: format.toLowerCase(),
          inputPath: widget.filePath,
          outputPath: outPath,
          onProgress: (msg) {
            if (mounted) {
              setState(() {
                _error = msg; // surface progress; cleared on success
              });
            }
          },
        );
        if (toolResult != null) {
          if (mounted) setState(() => _lastResultPath = toolResult);
          return;
        }
        // Fall through to the pure-Dart fallback below.
      }

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

  static String _extFor(String format) {
    switch (format) {
      case 'PDF':
        return '.pdf';
      case 'DOCX':
        return '.docx';
      case 'HTML':
        return '.html';
      default:
        return '.txt';
    }
  }

  // Mirror the same source-vs-SwordFM-Downloads fallback the DocConverter
  // uses, so the toolchain output lands where users expect.
  static String _resolveOutPath(String sourcePath, String newExt) {
    final base = p.basenameWithoutExtension(sourcePath);
    final dir = p.dirname(sourcePath);
    // Try source dir; the service's own _writeOutput mirrors this.
    return p.join(dir, '$base$newExt');
  }

  /// Title chip — colours flip between "high-fidelity" (cyan, ready) and
  /// "fallback" (dim, not ready) so the user always knows which engine ran.
  Widget _buildStatusChip(ToolchainStatus s) {
    final ready = s.state == ToolchainState.ready;
    final color = ready ? OneDarkColors.cyan : OneDarkColors.fgDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        ready ? 'high-fidelity' : 'fallback',
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }

  /// Shown above the format grid when the toolchain is missing anything.
  /// Drives the user to either install Termux (Play Store) or run a one-shot
  /// install command in Termux via the existing com.swordfm/terminal channel.
  Widget _buildInstallPanel(ToolchainStatus s) {
    final themeColor = OneDarkColors.amber;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: themeColor.withValues(alpha: 0.10),
        border: Border.all(color: themeColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: themeColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _panelTitle(s.state),
                  style: TextStyle(
                      color: themeColor, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            s.hint,
            style: TextStyle(color: OneDarkColors.fg, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (s.state == ToolchainState.termuxMissing)
            FilledButton.icon(
              onPressed: _installing ? null : _openPlayStore,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Install Termux'),
              style: FilledButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: Colors.black,
              ),
            )
          else
            FilledButton.icon(
              onPressed: _installing ? null : _runInstall,
              icon: _installing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.download, size: 16),
              label: Text(_installing
                  ? 'Installing…'
                  : _installButtonLabel(s.state)),
              style: FilledButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: Colors.black,
              ),
            ),
        ],
      ),
    );
  }

  static String _panelTitle(ToolchainState s) {
    switch (s) {
      case ToolchainState.termuxMissing:
        return 'High-fidelity converter needs Termux';
      case ToolchainState.pythonMissing:
        return 'High-fidelity converter needs Python';
      case ToolchainState.modulesMissing:
        return 'High-fidelity converter needs Python modules';
      case ToolchainState.ready:
        return '';
    }
  }

  static String _installButtonLabel(ToolchainState s) {
    switch (s) {
      case ToolchainState.pythonMissing:
        return 'Install python in Termux';
      case ToolchainState.modulesMissing:
        return 'Install modules in Termux';
      case ToolchainState.termuxMissing:
      case ToolchainState.ready:
        return '';
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
    // PDF sources can only be converted to TXT (text extraction); offering
    // PDF/DOCX/HTML targets for a .pdf previously always ended in
    // "Conversion failed".
    final isPdfSource = widget.filePath.toLowerCase().endsWith('.pdf');
    return AlertDialog(
      backgroundColor: OneDarkColors.bg,
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Convert $baseName',
              style: TextStyle(color: OneDarkColors.cyan),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_status != null) _buildStatusChip(_status!),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_status != null &&
                _status!.state != ToolchainState.ready)
              _buildInstallPanel(_status!),
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
                        'Saved to: ${_lastResultPath!}',
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
