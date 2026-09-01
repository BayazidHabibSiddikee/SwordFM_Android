import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/docx_reader.dart';

/// Full-screen DOCX reader. Takes the file path, parses the document via
/// [DocxReader.parse], and renders the resulting block tree with proper
/// headings, formatting, lists, tables, images, and links.
///
/// Uses the active [ColorScheme] so the reader matches the rest of the app
/// in dark or cream/light theme.
class DocxReaderScreen extends StatefulWidget {
  final String filePath;
  const DocxReaderScreen({super.key, required this.filePath});

  @override
  State<DocxReaderScreen> createState() => _DocxReaderScreenState();
}

class _DocxReaderScreenState extends State<DocxReaderScreen> {
  DocxDocument? _doc;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await DocxReader.parse(widget.filePath);
      if (mounted) setState(() => _doc = doc);
    } on DocxParseException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String get _fileName => widget.filePath.split('/').last;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerHighest,
        foregroundColor: cs.onSurface,
        iconTheme: IconThemeData(color: cs.onSurface),
        title: Text(
          _fileName,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _error != null
          ? _buildError(cs, _error!)
          : _doc == null
              ? Center(child: CircularProgressIndicator(color: cs.primary))
              : _doc!.blocks.isEmpty
                  ? Center(
                      child: Text(
                        'Document is empty.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : _DocxDocumentView(doc: _doc!),
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
            Text(
              'Cannot open DOCX',
              style: TextStyle(color: cs.onSurface),
            ),
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

// ---------------------------------------------------------------------------
// Renderer — walks the block tree and emits Flutter widgets.
// ---------------------------------------------------------------------------

class _DocxDocumentView extends StatelessWidget {
  final DocxDocument doc;
  const _DocxDocumentView({required this.doc});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 80),
      itemCount: doc.blocks.length,
      itemBuilder: (context, i) {
        final block = doc.blocks[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _BlockRenderer(block: block, cs: cs),
        );
      },
    );
  }
}

class _BlockRenderer extends StatelessWidget {
  final DocxBlock block;
  final ColorScheme cs;
  const _BlockRenderer({required this.block, required this.cs});

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      DocxHeading h => _renderHeading(h, cs),
      DocxParagraph p => _renderParagraph(p, cs),
      DocxList l => _renderList(l, cs),
      DocxTable t => _renderTable(t, cs),
      DocxImage i => _renderImage(i, cs),
      DocxDivider() => const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(height: 1),
        ),
    };
  }

  Widget _renderHeading(DocxHeading h, ColorScheme cs) {
    final baseSize = switch (h.level) {
      1 => 26.0,
      2 => 22.0,
      3 => 18.0,
      4 => 16.0,
      5 => 14.0,
      _ => 13.0,
    };
    return Padding(
      padding: EdgeInsets.only(top: h.level <= 2 ? 12 : 6, bottom: 4),
      child: _InlineRuns(
        runs: h.runs,
        base: TextStyle(
          color: cs.onSurface,
          fontSize: baseSize,
          fontWeight: h.level <= 2 ? FontWeight.w700 : FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _renderParagraph(DocxParagraph p, ColorScheme cs) {
    return _InlineRuns(
      runs: p.runs,
      base: TextStyle(color: cs.onSurface, fontSize: 15, height: 1.5),
      alignment: p.alignment,
    );
  }

  Widget _renderList(DocxList l, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < l.items.length; i++)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    l.ordered ? '${i + 1}.' : '•',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                ),
                Expanded(
                  child: _InlineRuns(
                    runs: l.items[i],
                    base: TextStyle(
                        color: cs.onSurface, fontSize: 15, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _renderTable(DocxTable t, ColorScheme cs) {
    // Width heuristic: first cell of first row drives the column count, then
    // we use Expanded inside Row to distribute evenly. For wide tables this
    // is approximate; full-fidelity table layout is out of scope.
    if (t.rows.isEmpty) return const SizedBox.shrink();
    final colCount =
        t.rows.map((r) => r.length).fold<int>(0, (a, b) => a > b ? a : b);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          for (var r = 0; r < t.rows.length; r++) ...[
            if (r > 0) Divider(height: 1, color: cs.outlineVariant),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < colCount; c++) ...[
                    if (c > 0)
                      VerticalDivider(
                          width: 1, color: cs.outlineVariant),
                    Expanded(
                      child: Container(
                        color: r == 0
                            ? cs.surfaceContainerHighest
                            : Colors.transparent,
                        padding: const EdgeInsets.all(8),
                        child: _InlineRuns(
                          runs: c < t.rows[r].length
                              ? t.rows[r][c]
                              : const <DocxRun>[],
                          base: TextStyle(
                              color: cs.onSurface,
                              fontSize: 13,
                              fontWeight: r == 0
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              height: 1.4),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _renderImage(DocxImage img, ColorScheme cs) {
    // Standalone image (rare in body text; usually inline). Best-effort
    // aspect ratio when EMU dimensions are present.
    final aspect = (img.width != null && img.height != null && img.height! > 0)
        ? img.width! / img.height!
        : null;
    Widget errorFallback(double? h) => Container(
          height: h ?? 120,
          color: cs.surfaceContainerHighest,
          child: Center(
            child: Icon(Icons.broken_image, color: cs.onSurfaceVariant),
          ),
        );
    if (aspect != null) {
      return AspectRatio(
        aspectRatio: aspect,
        child: Image.file(
          File(img.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => errorFallback(null),
        ),
      );
    }
    return Image.file(
      File(img.path),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => errorFallback(120),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline runs (text + images) → RichText.
// ---------------------------------------------------------------------------

class _InlineRuns extends StatelessWidget {
  final List<DocxRun> runs;
  final TextStyle base;
  final DocxAlignment alignment;
  const _InlineRuns({
    required this.runs,
    required this.base,
    this.alignment = DocxAlignment.left,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (runs.isEmpty) return const SizedBox.shrink();

    // Build a single TextSpan with the link color and per-run decoration.
    final linkColor = cs.primary;
    final spans = <InlineSpan>[];
    for (final r in runs) {
      if (r is DocxInlineImage) {
        // Inline image — end any current text span and emit a widget span.
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Image.file(
                File(r.imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  width: 120,
                  height: 80,
                  color: cs.surfaceContainerHighest,
                  child: Center(
                    child:
                        Icon(Icons.broken_image, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ));
        continue;
      }
      if (r is DocxLineBreak || r.isBreak) {
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      if (r.text.isEmpty) continue;
      var style = base.copyWith(
        fontWeight: r.bold ? FontWeight.w700 : base.fontWeight,
        fontStyle: r.italic ? FontStyle.italic : base.fontStyle,
        decoration: TextDecoration.combine(r.underline || r.link != null
            ? <TextDecoration>[TextDecoration.underline]
            : (r.strike
                ? <TextDecoration>[TextDecoration.lineThrough]
                : <TextDecoration>[])),
        color: r.link != null ? linkColor : base.color,
      );
      if (r.superscript == 1) {
        // Flutter TextSpan doesn't have a super/subscript flag; we approximate
        // with a smaller fontSize + baseline offset (RichText supports
        // textBaseline on TextSpan).
        style = style.copyWith(
          fontSize: (style.fontSize ?? 14) * 0.75,
        );
        spans.add(TextSpan(
          text: r.text,
          style: style,
        ));
        continue;
      }
      if (r.link != null) {
        spans.add(TextSpan(
          text: r.text,
          style: style,
          recognizer: null, // see GestureDetector below
        ));
      } else {
        spans.add(TextSpan(text: r.text, style: style));
      }
    }

    final text = TextSpan(style: base, children: spans);

    // Wrap in a GestureDetector for link taps. Multi-link handling is
    // approximate (we use Text.rich with a default recognizer). For a
    // single link this is enough.
    final firstLink = runs.firstWhere(
      (r) => r.link != null,
      orElse: () => const DocxRun(text: ''),
    );
    return Align(
      alignment: switch (alignment) {
        DocxAlignment.center => Alignment.center,
        DocxAlignment.right => Alignment.centerRight,
        DocxAlignment.both => Alignment.centerLeft,
        DocxAlignment.left => Alignment.centerLeft,
      },
      child: GestureDetector(
        onTap: firstLink.link == null
            ? null
            : () => _openLink(firstLink.link!),
        child: Text.rich(text),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
