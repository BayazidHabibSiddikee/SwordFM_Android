import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/spreadsheet_html_builder.dart';
import '../theme/theme.dart';

/// In-app spreadsheet viewer for XLSX / XLS / ODS / CSV files.
///
/// XLSX/XLS/ODS: reads raw bytes, passes base64 to embedded SheetJS
/// (bundled locally at assets/js/xlsx.full.min.js — works fully offline)
/// which renders an HTML table. CSV: reads as text and formats directly
/// without SheetJS.
class SpreadsheetViewerScreen extends StatefulWidget {
  final String filePath;
  const SpreadsheetViewerScreen({super.key, required this.filePath});

  @override
  State<SpreadsheetViewerScreen> createState() =>
      _SpreadsheetViewerScreenState();
}

class _SpreadsheetViewerScreenState extends State<SpreadsheetViewerScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  String get _fileName => p.basename(widget.filePath);
  String get _ext => p.extension(widget.filePath).toLowerCase();
  bool get _isCsv => _ext == '.csv';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (err) {
          if (mounted) setState(() => _error = err.description);
        },
      ));
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      if (_isCsv) {
        await _loadCsv();
      } else {
        await _loadBinarySheet();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ── CSV ─────────────────────────────────────────────────────────────────
  Future<void> _loadCsv() async {
    final raw = await File(widget.filePath).readAsString();
    final html = buildCsvViewerHtml(raw);
    await _loadInWebView(html);
  }

  // ── XLSX / XLS / ODS ────────────────────────────────────────────────────
  Future<void> _loadBinarySheet() async {
    try {
      // Read the file bytes
      final bytes = await File(widget.filePath).readAsBytes();
      final b64 = base64Encode(bytes);

      // Load SheetJS from the bundled asset
      final bundle = DefaultAssetBundle.of(context);
      final sheetJs = await bundle.loadString('assets/js/xlsx.full.min.js');

      // Build the HTML with SheetJS embedded
      final html = buildSheetJsViewerHtml(sheetJsSource: sheetJs, base64Bytes: b64);

      // Load into WebView
      await _loadInWebView(html);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load spreadsheet: $e\n\n'
              'The file may be corrupted or in an unsupported format.\n'
              'Try opening it with another app.';
        });
      }
    }
  }

  /// Loads [html] in the WebView.
  ///
  /// Uses temp file approach which is more reliable than loadHtmlString
  /// for large documents with embedded JS.
  Future<void> _loadInWebView(String html) async {
    try {
      final dir = await getTemporaryDirectory();
      // Use unique filename to avoid conflicts
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tmp = File('${dir.path}/swordfm_sheet_$timestamp.html');
      await tmp.writeAsString(html, flush: true);

      // Load the file
      await _controller.loadFile(tmp.path);

      // Clean up temp file after loading (with delay to ensure WebView has it)
      Future.delayed(const Duration(seconds: 2), () {
        try {
          tmp.delete();
        } catch (_) {}
      });
    } catch (e) {
      // If temp file approach fails, try inline loading
      try {
        await _controller.loadHtmlString(html);
      } catch (e2) {
        if (mounted) {
          setState(() {
            _error = 'Failed to display spreadsheet: $e2';
            _loading = false;
          });
        }
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        title: Text(_fileName,
            style: TextStyle(color: OneDarkColors.fg, fontSize: 14)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: OneDarkColors.fg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: OneDarkColors.fgDim),
            tooltip: 'Reload',
            onPressed: _loadFile,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline,
                        color: OneDarkColors.red, size: 48),
                    const SizedBox(height: 12),
                    Text('Failed to load spreadsheet',
                        style: TextStyle(
                            color: OneDarkColors.fg,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(
                            color: OneDarkColors.fgDim, fontSize: 12),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading && _error == null)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
