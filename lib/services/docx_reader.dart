import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// A parsed DOCX document, ready to render.
///
/// The document is a flat list of [DocxBlock] nodes in reading order. Each
/// block knows how to render itself as a Flutter widget. The parser is
/// deliberately conservative: anything it doesn't understand is preserved as
/// text so nothing is lost — the layout may be flat but no content is gone.
class DocxDocument {
  final List<DocxBlock> blocks;
  final int? embeddedImageCount;
  const DocxDocument({required this.blocks, this.embeddedImageCount});
}

/// A single block-level element in a DOCX. Renders as a Flutter widget.
sealed class DocxBlock {
  const DocxBlock();
}

/// A heading: H1–H6, styled by [level].
class DocxHeading extends DocxBlock {
  final int level; // 1..6
  final List<DocxRun> runs;
  const DocxHeading(this.level, this.runs);
}

/// A plain paragraph.
class DocxParagraph extends DocxBlock {
  final List<DocxRun> runs;
  final DocxAlignment alignment;
  const DocxParagraph(this.runs, {this.alignment = DocxAlignment.left});
}

/// A bulleted or numbered list. Items are themselves paragraphs.
class DocxList extends DocxBlock {
  final bool ordered;
  final List<List<DocxRun>> items;
  const DocxList({required this.ordered, required this.items});
}

/// A table. Cells are rows × cols of runs.
class DocxTable extends DocxBlock {
  final List<List<List<DocxRun>>> rows;
  const DocxTable(this.rows);
}

/// A standalone image (rare in body text; usually inline).
class DocxImage extends DocxBlock {
  final String path;
  final int? width;
  final int? height;
  const DocxImage({required this.path, this.width, this.height});
}

/// Horizontal rule / page break.
class DocxDivider extends DocxBlock {
  const DocxDivider();
}

enum DocxAlignment { left, center, right, both }

/// A text run with its inline formatting.
class DocxRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String? link; // null when not a hyperlink
  final int? superscript; // null = normal; 1 = superscript, -1 = subscript
  const DocxRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.link,
    this.superscript,
  });

  bool get isImage => false;
  bool get isBreak => text == '\n';
  bool get isEmpty => text.isEmpty && link == null;
}

/// Special: an inline image. Carries the local path after extraction.
class DocxInlineImage extends DocxRun {
  final String imagePath;
  final int? width;
  final int? height;
  const DocxInlineImage({
    required this.imagePath,
    this.width,
    this.height,
  }) : super(text: '');

  @override
  bool get isImage => true;
}

/// Special: a forced line break inside a paragraph.
class DocxLineBreak extends DocxRun {
  const DocxLineBreak() : super(text: '\n');
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class DocxReader {
  /// Parses a .docx file at [path] and returns a [DocxDocument] for rendering.
  /// Throws [DocxParseException] on malformed input.
  static Future<DocxDocument> parse(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw DocxParseException('File not found: $path');
    }
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1. Pull word/document.xml out of the ZIP.
    final docXml = archive.findFile('word/document.xml');
    if (docXml == null) {
      throw DocxParseException('Missing word/document.xml — not a real .docx');
    }
    final documentXml =
        utf8.decode(docXml.content as List<int>, allowMalformed: true);

    // 2. Pull the relationship file so we can resolve r:embed="rIdN" → image path.
    final relsBytes = archive.findFile('word/_rels/document.xml.rels');
    final rels = relsBytes != null
        ? _parseRelationships(
            utf8.decode(relsBytes.content as List<int>, allowMalformed: true))
        : <String, String>{};

    // 3. Extract embedded images to the app's temp dir so the renderer can
    //    load them via FileImage. We keep the basename so identical filenames
    //    across runs overwrite each other (cheap, no leak).
    var imageCount = 0;
    String? imageDir;
    final imageFiles = archive.files
        .where((f) => f.name.startsWith('word/media/'))
        .toList();
    if (imageFiles.isNotEmpty) {
      final cache = await getTemporaryDirectory();
      imageDir = p.join(cache.path, 'swordfm_docx_${path.hashCode}');
      await Directory(imageDir).create(recursive: true);
      for (final f in imageFiles) {
        final name = p.basename(f.name);
        final out = File(p.join(imageDir, name));
        await out.writeAsBytes(f.content as List<int>);
        imageCount++;
      }
    }

    // 4. Parse the document XML into a flat block list.
    final doc = XmlDocument.parse(documentXml);
    final body = doc.findAllElements('w:body').firstOrNull;
    if (body == null) {
      throw DocxParseException('Missing <w:body>');
    }

    final blocks = <DocxBlock>[];
    // Block elements are the direct children of <w:body>, BUT real-world
    // documents wrap them in <w:sdt> (content controls — forms, dropdowns,
    // date pickers, etc.) and <w:smartTag> blocks. We walk all descendants
    // so those wrappers don't silently hide their inner paragraphs/tables.
    for (final descendant in body.descendantElements) {
      final parent = descendant.parent;
      if (parent is XmlElement &&
          parent != body &&
          !_isBlockWrapper(parent)) {
        continue; // nested inside something we already visited
      }
      final parsed = _parseBlock(descendant, rels, imageDir);
      if (parsed != null) blocks.addAll(parsed);
    }
    return DocxDocument(blocks: blocks, embeddedImageCount: imageCount);
  }

  /// True when [el] is a transparent block-level wrapper whose children
  /// should be treated as direct body children for parsing purposes.
  static bool _isBlockWrapper(XmlElement? el) {
    if (el == null) return false;
    final name = el.name.local;
    // sdt: <w:sdt><w:sdtContent>…</w:sdtContent></w:sdt> — common in Word
    // forms and content controls.
    if (name == 'sdt' || name == 'sdtContent') return true;
    // smartTag: legacy Word feature, occasionally seen.
    if (name == 'smartTag') return true;
    return false;
  }

  // ---------- block parsing ----------

  static List<DocxBlock>? _parseBlock(
    XmlElement el,
    Map<String, String> rels,
    String? imageDir,
  ) {
    switch (el.name.local) {
      case 'p':
        final parsed = _parseParagraph(el, rels, imageDir);
        return parsed == null ? null : [parsed];
      case 'tbl':
        final table = _parseTable(el, rels, imageDir);
        return table == null ? null : [table];
      case 'sectPr':
        return null; // section properties — layout info, ignore
      default:
        return null;
    }
  }

  static DocxBlock? _parseParagraph(
    XmlElement p,
    Map<String, String> rels,
    String? imageDir,
  ) {
    // 1. Detect heading style: <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>.
    var isHeading = false;
    var headingLevel = 0;
    var alignment = DocxAlignment.left;
    final pPr = p.findElements('w:pPr').firstOrNull;
    if (pPr != null) {
      final pStyle = pPr.findElements('w:pStyle').firstOrNull;
      final styleId = pStyle?.getAttribute('w:val') ?? '';
      final h = RegExp(r'^(?:Heading|heading)(\d)$').firstMatch(styleId);
      if (h != null) {
        isHeading = true;
        headingLevel = int.parse(h.group(1)!);
      }
      final jc = pPr.findElements('w:jc').firstOrNull;
      final jcVal = jc?.getAttribute('w:val') ?? '';
      alignment = switch (jcVal) {
        'center' => DocxAlignment.center,
        'right' => DocxAlignment.right,
        'both' => DocxAlignment.both,
        _ => DocxAlignment.left,
      };
    }

    // 2. Walk runs. Group consecutive runs that share formatting? For now we
    //    emit one DocxRun per <w:r>, since the renderer is happy to merge
    //    adjacent text via Text.rich.
    final runs = <DocxRun>[];
    for (final child in p.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 'r':
          final run = _parseRun(child, rels, imageDir);
          if (run != null) runs.add(run);
          break;
        case 'hyperlink':
          final linkRuns = _parseHyperlink(child, rels, imageDir);
          runs.addAll(linkRuns);
          break;
        // bookmarks, proofErr, etc. — ignore
      }
    }

    // 3. Decide the block kind. If the paragraph is empty AND there's a
    //    w:r with a w:br type=page, emit a divider (page break).
    if (runs.isEmpty) {
      final hasPageBreak = p.findAllElements('w:br').any(
            (b) => (b.getAttribute('w:type') ?? '') == 'page',
          );
      if (hasPageBreak) return const DocxDivider();
      return null; // empty paragraph — skip
    }

    if (isHeading) {
      return DocxHeading(headingLevel, runs);
    }
    return DocxParagraph(runs, alignment: alignment);
  }

  static DocxRun? _parseRun(
    XmlElement r,
    Map<String, String> rels,
    String? imageDir,
  ) {
    // Inline image: <w:r><w:drawing>…<a:blip r:embed="rIdN"/>…</w:drawing></w:r>
    final drawing = r.findElements('w:drawing').firstOrNull;
    if (drawing != null) {
      final blip = drawing
          .findAllElements('a:blip')
          .firstOrNull;
      if (blip != null) {
        final rid = blip.getAttribute('r:embed');
        if (rid != null && rels.containsKey(rid) && imageDir != null) {
          final relTarget = rels[rid]!;
          final fileName = p.basename(relTarget);
          final local = File(p.join(imageDir, fileName));
          if (local.existsSync()) {
            // Try to read the extent (in EMU — English Metric Units, 914400 per inch).
            final extent = drawing
                .findAllElements('wp:extent')
                .firstOrNull;
            final cx = extent != null ? int.tryParse(extent.getAttribute('cx') ?? '') : null;
            final cy = extent != null ? int.tryParse(extent.getAttribute('cy') ?? '') : null;
            return DocxInlineImage(
              imagePath: local.path,
              width: cx,
              height: cy,
            );
          }
        }
      }
      // Unresolvable drawing — return empty run, image will be skipped.
      return null;
    }

    // Plain text run.
    final rPr = r.findElements('w:rPr').firstOrNull;
    final props = _parseRunProps(rPr);
    // Concatenate <w:t> children — Word often splits a phrase into multiple <w:t>
    // elements for no good reason.
    final buffer = StringBuffer();
    var sawBreak = false;
    for (final child in r.children.whereType<XmlElement>()) {
      switch (child.name.local) {
        case 't':
          buffer.write(child.innerText);
          break;
        case 'tab':
          buffer.write('\t');
          break;
        case 'br':
          final type = child.getAttribute('w:type') ?? '';
          if (type == 'page') {
            // Page break inside a run — emit a divider, caller will handle.
            // (Inside a paragraph: a real Word doc treats this as the
            // paragraph ending the page; we treat it as a blank line.)
            buffer.write('\n');
            sawBreak = true;
          } else {
            buffer.write('\n');
          }
          break;
      }
    }
    if (buffer.isEmpty && !sawBreak) return null;
    return DocxRun(
      text: buffer.toString(),
      bold: props.bold,
      italic: props.italic,
      underline: props.underline,
      strike: props.strike,
      superscript: props.superscript,
    );
  }

  static List<DocxRun> _parseHyperlink(
    XmlElement h,
    Map<String, String> rels,
    String? imageDir,
  ) {
    final rid = h.getAttribute('r:id');
    final link = rid != null ? rels[rid] : null;
    final runs = <DocxRun>[];
    for (final r in h.findElements('w:r')) {
      final run = _parseRun(r, rels, imageDir);
      if (run == null) continue;
      runs.add(DocxRun(
        text: run.text,
        bold: run.bold,
        italic: run.italic,
        underline: true, // hyperlinks always underline
        strike: run.strike,
        link: link,
        superscript: run.superscript,
      ));
    }
    return runs;
  }

  static DocxTable? _parseTable(
    XmlElement tbl,
    Map<String, String> rels,
    String? imageDir,
  ) {
    final rows = <List<List<DocxRun>>>[];
    for (final tr in tbl.findElements('w:tr')) {
      final cells = <List<DocxRun>>[];
      for (final tc in tr.findElements('w:tc')) {
        final cellRuns = <DocxRun>[];
        for (final p in tc.findElements('w:p')) {
          final block = _parseParagraph(p, rels, imageDir);
          if (block is DocxParagraph) cellRuns.addAll(block.runs);
        }
        cells.add(cellRuns);
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    return rows.isEmpty ? null : DocxTable(rows);
  }

  // ---------- run properties ----------

  static _RunProps _parseRunProps(XmlElement? rPr) {
    if (rPr == null) return const _RunProps();
    var bold = false;
    var italic = false;
    var underline = false;
    var strike = false;
    var superscript = 0;
    if (rPr.findElements('w:b').isNotEmpty) bold = true;
    if (rPr.findElements('w:i').isNotEmpty) italic = true;
    if (rPr.findElements('w:u').isNotEmpty) underline = true;
    if (rPr.findElements('w:strike').isNotEmpty) strike = true;
    if (rPr.findElements('w:vertAlign').any(
          (e) => (e.getAttribute('w:val') ?? '') == 'superscript',
        )) {
      superscript = 1;
    } else if (rPr.findElements('w:vertAlign').any(
          (e) => (e.getAttribute('w:val') ?? '') == 'subscript',
        )) {
      superscript = -1;
    }
    return _RunProps(
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      superscript: superscript,
    );
  }

  // ---------- rels ----------

  static Map<String, String> _parseRelationships(String xml) {
    final result = <String, String>{};
    try {
      final doc = XmlDocument.parse(xml);
      for (final rel in doc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null && target != null) result[id] = target;
      }
    } catch (_) {
      // Bad rels file — caller proceeds without link resolution.
    }
    return result;
  }
}

class _RunProps {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int superscript; // 0 = normal, 1 = sup, -1 = sub
  const _RunProps({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.superscript = 0,
  });
}

class DocxParseException implements Exception {
  final String message;
  DocxParseException(this.message);
  @override
  String toString() => 'DocxParseException: $message';
}
