import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen reader for text, code, and Markdown files.
///
/// - Markdown files (`.md`, `.markdown`) get a real markdown renderer
///   with headings, lists, code blocks, and links.
/// - Everything else renders as monospaced text with a left-gutter line
///   number column. The gutter is its own scrollable column so the line
///   number on the left always lines up with the line of text on the
///   right, even at extreme zoom or on long lines.
///
/// Both modes support pinch-zoom, a "copy all" action, and a refresh
/// after editing the file in another app.
class TextReaderScreen extends StatefulWidget {
  final String filePath;
  const TextReaderScreen({super.key, required this.filePath});

  @override
  State<TextReaderScreen> createState() => _TextReaderScreenState();
}

class _TextReaderScreenState extends State<TextReaderScreen> {
  String? _content;
  String? _error;
  // Zoom level (1.0 = default). Bound to the +/- buttons in the app bar.
  double _scale = 1.0;
  // Common scroll controller shared by the line-number gutter and the
  // text body so vertical scrolling stays in sync.
  final ScrollController _verticalScroll = ScrollController();

  bool get _isMarkdown {
    final ext = p.extension(widget.filePath).toLowerCase();
    return ext == '.md' || ext == '.markdown';
  }

  bool get _isHtml {
    final ext = p.extension(widget.filePath).toLowerCase();
    return ext == '.html' || ext == '.htm';
  }

  String get _fileName => widget.filePath.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _verticalScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      if (!file.existsSync()) {
        setState(() => _error = 'File not found');
        return;
      }
      // 5 MB cap — reading bigger files would block the UI thread.
      final length = file.lengthSync();
      if (length > 5 * 1024 * 1024) {
        setState(() => _error = 'File is too large to preview (5 MB cap)');
        return;
      }
      final text = file.readAsStringSync();
      if (!mounted) return;
      setState(() => _content = text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _copyAll() async {
    if (_content == null) return;
    await Clipboard.setData(ClipboardData(text: _content!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _setScale(double s) {
    setState(() {
      _scale = s.clamp(0.5, 4.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(
          _fileName,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: cs.surfaceContainerHighest,
        foregroundColor: cs.onSurface,
        iconTheme: IconThemeData(color: cs.onSurface),
        actions: [
          if (!_isHtml) ...[
            IconButton(
              icon: Icon(Icons.zoom_out, color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Zoom out',
              onPressed: _content == null ? null : () => _setScale(_scale - 0.1),
            ),
            IconButton(
              icon: Icon(Icons.zoom_in, color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Zoom in',
              onPressed: _content == null ? null : () => _setScale(_scale + 0.1),
            ),
            IconButton(
              icon: Icon(Icons.content_copy, color: cs.onSurfaceVariant, size: 20),
              tooltip: 'Copy all',
              onPressed: _content == null ? null : _copyAll,
            ),
          ],
        ],
      ),
      body: _error != null
          ? _buildError(cs, _error!)
          : _content == null
              ? const Center(child: CircularProgressIndicator())
              : _isHtml
                  ? _buildHtmlView()
                  : InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: _isMarkdown
                          ? _buildMarkdown(cs)
                          : _buildPlainText(cs),
                    ),
    );
  }

  /// Renders HTML files in a full WebView — proper styling, images, links.
  Widget _buildHtmlView() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadFile(widget.filePath);
    return WebViewWidget(controller: controller);
  }

  Widget _buildMarkdown(ColorScheme cs) {
    return Transform.scale(
      scale: _scale,
      child: Markdown(
        data: _content!,
        padding: const EdgeInsets.all(16),
        selectable: true,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: TextStyle(color: cs.onSurface, fontSize: 14, height: 1.5),
          h1: TextStyle(color: cs.onSurface, fontSize: 22),
          h2: TextStyle(color: cs.onSurface, fontSize: 18),
          h3: TextStyle(color: cs.onSurface, fontSize: 16),
          code: TextStyle(
            color: cs.primary,
            fontFamily: 'monospace',
            fontSize: 12,
            backgroundColor: cs.surfaceContainerHighest,
          ),
          codeblockDecoration:
              BoxDecoration(color: cs.surfaceContainerHighest),
        ),
      ),
    );
  }

  Widget _buildPlainText(ColorScheme cs) {
    final lines = _content!.split('\n');
    return Transform.scale(
      scale: _scale,
      child: _LineNumberedText(
        lines: lines,
        cs: cs,
        scrollController: _verticalScroll,
      ),
    );
  }

  Widget _buildError(ColorScheme cs, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: cs.error),
            const SizedBox(height: 12),
            Text('Cannot open file', style: TextStyle(color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain-text / code renderer with a left gutter of line numbers.
///
/// The gutter and the text body are two side-by-side columns wrapped in a
/// single scrollable so vertical scrolling stays in sync. Each row has
/// the line number on the left and the line text on the right.
class _LineNumberedText extends StatelessWidget {
  final List<String> lines;
  final ColorScheme cs;
  final ScrollController scrollController;

  const _LineNumberedText({
    required this.lines,
    required this.cs,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final cs = this.cs;
    // ~8 px per char at 13pt monospace — used to size the content width
    // so long lines are visible without horizontal scroll. We add a
    // small constant for line numbers + padding.
    const charWidth = 7.5;
    final longestLine =
        lines.fold<int>(0, (w, l) => l.length > w ? l.length : w);
    final contentWidth =
        (longestLine * charWidth).clamp(0.0, MediaQuery.of(context).size.width * 3);

    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: scrollController,
        child: SizedBox(
          width: contentWidth + 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++)
                  _buildLineRow(cs, i + 1, lines[i]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLineRow(ColorScheme cs, int lineNum, String text) {
    final gutterStyle = TextStyle(
      color: cs.onSurfaceVariant,
      fontFamily: 'monospace',
      fontSize: 13,
    );
    final textStyle = TextStyle(
      color: cs.onSurface,
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.4,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              '$lineNum',
              style: gutterStyle,
              textAlign: TextAlign.right,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text.isEmpty ? ' ' : text,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}
