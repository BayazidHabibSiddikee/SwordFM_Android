import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Document conversion utilities for SwordFM Android.
///
/// Provides Markdown -> HTML, Markdown -> plain text, Markdown -> PDF, and
/// Markdown -> DOCX conversion entirely in Dart (no native helpers required).
/// PDF export uses the `pdf` package; DOCX export is built as a real OOXML
/// (ZIP) document via the `archive` package.
class DocConverter {
  /// Converts a Markdown/text file to a real PDF, writing `<base>.pdf` next to
  /// the source. Returns the output path, or null if the source is not
  /// convertible or missing.
  ///
  /// Supported Markdown constructs: headings (h1-h6), paragraphs, fenced and
  /// inline code, unordered lists, ordered lists, blockquotes, and horizontal
  /// rules.
  static Future<String?> toPdf(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final bytes = await _buildPdfBytes(_preprocessForMarkdown(
      sourcePath,
      content,
    ));
    final outPath = p.setExtension(sourcePath, '.pdf');
    await File(outPath).writeAsBytes(bytes);
    return outPath;
  }

  /// Converts a Markdown/text file to a real DOCX (OOXML ZIP), writing
  /// `<base>.docx` next to the source. Returns the output path, or null if the
  /// source is not convertible or missing.
  static Future<String?> toDocx(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final bytes = await _buildDocxBytes(_preprocessForMarkdown(
      sourcePath,
      content,
    ));
    final outPath = p.setExtension(sourcePath, '.docx');
    await File(outPath).writeAsBytes(bytes);
    return outPath;
  }

  /// Converts a file to plain text (Markdown stripped).
  static Future<String?> toText(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final text = markdownToText(_preprocessForMarkdown(sourcePath, content));
    final outPath = p.setExtension(sourcePath, '.txt');
    await File(outPath).writeAsString(text);
    return outPath;
  }

  /// Extracts the plain text of a `.docx` file (word/document.xml inside the
  /// OOXML ZIP), writing `<base>.txt` next to the source.
  static Future<String?> fromDocx(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final docXml = archive.files
          .where((f) => f.name == 'word/document.xml')
          .firstOrNull;
      if (docXml == null) return null;
      final xml = utf8.decode(docXml.content as List<int>);
      // Strip tags; break paragraphs/rows onto separate lines.
      final text = xml
          .replaceAll(RegExp(r'</w:p>'), '\n')
          .replaceAll(RegExp(r'</w:tr>'), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
      final outPath = p.setExtension(sourcePath, '.txt');
      await File(outPath).writeAsString(text);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  /// Prepares the raw file content for the shared markdown pipeline:
  /// HTML → plain text (tags stripped), CSV → a markdown table, anything
  /// else passes through unchanged.
  static String _preprocessForMarkdown(String sourcePath, String content) {
    final ext = p.extension(sourcePath).toLowerCase();
    if (ext == '.html' || ext == '.htm') {
      return _stripHtml(content);
    }
    if (ext == '.csv') {
      return _csvToMarkdown(content);
    }
    if (ext == '.docx') {
      // DOCX content is raw XML from word/document.xml — extract text
      return content
          .replaceAll('</w:p>', '\n')
          .replaceAll('</w:tr>', '\n')
          .replaceAll('<w:tab/>', '\t')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .trim();
    }
    return content;
  }

  /// Crude-but-effective HTML → text: drop scripts/styles and tags, decode a
  /// few common entities, collapse blank lines.
  static String _stripHtml(String html) {
    var text = html.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
    text = text.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Turns CSV rows into a GitHub-style markdown table so the shared pipeline
  /// renders it as a real table in PDF/DOCX/HTML output.
  static String _csvToMarkdown(String csv) {
    final rows = csv
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .map((l) => _splitCsvLine(l))
        .toList();
    if (rows.isEmpty) return csv;
    final cell = (String s) => s.trim().replaceAll('|', '\\|');
    final header = rows.first;
    final sb = StringBuffer();
    sb.writeln('| ${header.map(cell).join(' | ')} |');
    sb.writeln('|${header.map((_) => '---').join('|')}|');
    for (final row in rows.skip(1)) {
      sb.writeln('| ${row.map(cell).join(' | ')} |');
    }
    return sb.toString();
  }

  static List<String> _splitCsvLine(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString());
    return result;
  }

  /// Reads a Markdown/text file and returns full HTML document.
  static Future<String?> markdownFileToHtml(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final title = p.basenameWithoutExtension(path);
    final body = markdownToHtml(content);
    return '<!DOCTYPE html>\n<html>\n<head>\n'
        '<meta charset="utf-8">\n<title>$title</title>\n'
        '<style>'
        'body{font-family:-apple-system,sans-serif;line-height:1.6;'
        'max-width:760px;margin:32px auto;padding:0 20px;color:#333}'
        'pre{background:#f4f4f4;padding:12px;border-radius:6px;overflow:auto}'
        'code{background:#f4f4f4;padding:2px 4px;border-radius:3px}'
        'blockquote{border-left:4px solid #61afef;margin:0;padding-left:12px;color:#555}'
        '</style>\n</head>\n<body>\n$body\n</body>\n</html>\n';
  }

  /// Converts Markdown content to a full HTML string.
  ///
  /// Supports: headings, bold/italic, inline code, fenced + indented code
  /// blocks, blockquotes, unordered/ordered lists, links, images, and
  /// horizontal rules.
  static String markdownToHtml(String markdown) {
    final lines = markdown.split('\n');
    final out = <String>[];
    var i = 0;
    var inCodeBlock = false;
    final codeBuffer = <String>[];

    void flushCode() {
      if (codeBuffer.isEmpty) return;
      out.add(
        '<pre><code>${codeBuffer.map(_escapeHtml).join('\n')}</code></pre>',
      );
      codeBuffer.clear();
    }

    while (i < lines.length) {
      final line = lines[i];

      // Fenced code block
      if (line.trimLeft().startsWith('```')) {
        if (!inCodeBlock) {
          flushCode();
          inCodeBlock = true;
        } else {
          inCodeBlock = false;
          flushCode();
        }
        i++;
        continue;
      }
      if (inCodeBlock) {
        codeBuffer.add(line);
        i++;
        continue;
      }

      // Horizontal rule
      if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
        flushCode();
        out.add('<hr>');
        i++;
        continue;
      }

      // Headings
      final h = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
      if (h != null) {
        flushCode();
        final level = h.group(1)!.length;
        out.add('<h$level>${_inline(h.group(2)!)}</h$level>');
        i++;
        continue;
      }

      // Blockquote
      if (line.startsWith('> ')) {
        flushCode();
        final buf = <String>[];
        while (i < lines.length && lines[i].startsWith('> ')) {
          buf.add(lines[i].substring(2));
          i++;
        }
        out.add('<blockquote>${_inline(buf.join(' '))}</blockquote>');
        continue;
      }

      // Unordered list
      if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
        flushCode();
        final buf = <String>[];
        while (i < lines.length && RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i])) {
          final item = lines[i].replaceFirst(RegExp(r'^\s*[-*+]\s+'), '');
          buf.add('<li>${_inline(item)}</li>');
          i++;
        }
        out.add('<ul>${buf.join('')}</ul>');
        continue;
      }

      // Ordered list
      if (RegExp(r'^\s*\d+\.\s+').hasMatch(line)) {
        flushCode();
        final buf = <String>[];
        while (i < lines.length && RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i])) {
          final item = lines[i].replaceFirst(RegExp(r'^\s*\d+\.\s+'), '');
          buf.add('<li>${_inline(item)}</li>');
          i++;
        }
        out.add('<ol>${buf.join('')}</ol>');
        continue;
      }

      // Blank line ends a paragraph
      if (line.trim().isEmpty) {
        flushCode();
        i++;
        continue;
      }

      // Collect paragraph until blank line
      final buf = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        if (lines[i].trimLeft().startsWith('```')) break;
        buf.add(lines[i].trim());
        i++;
      }
      if (buf.isNotEmpty) {
        flushCode();
        out.add('<p>${_inline(buf.join(' '))}</p>');
      }
    }

    flushCode();
    return out.join('\n');
  }

  /// Converts Markdown content to plain text (strips formatting).
  static String markdownToText(String markdown) {
    var text = markdown;
    // Remove fenced code blocks but keep content
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    // Headings
    text = text.replaceAllMapped(
      RegExp(r'^#{1,6}\s+(.+)$', multiLine: true),
      (m) => m.group(1)!,
    );
    // Bold / italic
    text = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => m.group(1)!,
    );
    text = text.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'_([^_]+)_'), (m) => m.group(1)!);
    // Inline code
    text = text.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    // Links [text](url) -> text (url)
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
      (m) => '${m.group(1)} (${m.group(2)})',
    );
    // Images ![](url) -> url
    text = text.replaceAllMapped(
      RegExp(r'!\[[^\]]*\]\(([^)]+)\)'),
      (m) => m.group(1)!,
    );
    // List markers
    text = text.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '• ');
    text = text.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
    // Blockquote
    text = text.replaceAll(RegExp(r'^>\s?', multiLine: true), '');
    // Horizontal rules
    text = text.replaceAll(
      RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$', multiLine: true),
      '',
    );
    return text.trim();
  }

  static String _inline(String text) {
    var out = _escapeHtml(text);
    // Images first
    out = out.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'),
      (m) => '<img src="${m.group(2)}" alt="${m.group(1)}">',
    );
    // Links
    out = out.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
      (m) => '<a href="${m.group(2)}">${m.group(1)}</a>',
    );
    // Inline code
    out = out.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (m) => '<code>${m.group(1)}</code>',
    );
    // Bold
    out = out.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => '<strong>${m.group(1)}</strong>',
    );
    // Italic
    out = out.replaceAllMapped(
      RegExp(r'\*([^*]+)\*'),
      (m) => '<em>${m.group(1)}</em>',
    );
    return out;
  }

  static String _escapeHtml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// Checks if the file can be converted. Accepts every plain-text format —
  /// markdown, code and data files all flow through the same text pipeline.
  static bool canConvert(String path) {
    final ext = p.extension(path).toLowerCase();
    const textExts = {
      '.md', '.markdown', '.txt', '.html', '.htm', '.csv', '.rst',
      '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
      '.log', '.css', '.js', '.ts', '.jsx', '.tsx', '.py', '.dart',
      '.java', '.kt', '.c', '.cpp', '.h', '.rs', '.go', '.sh', '.bat',
      '.sql', '.env', '.gitignore', '.diff', '.docx',
    };
    return textExts.contains(ext);
  }

  /// Lists available output formats for a given file.
  static List<String> getAvailableFormats(String path) {
    if (!canConvert(path)) return [];
    return ['PDF', 'DOCX', 'HTML', 'TXT'];
  }

  // ---------------------------------------------------------------------------
  // Markdown -> PDF / DOCX
  //
  // [markdownToHtml] already classifies Markdown into HTML; the PDF and DOCX
  // builders below reuse the *same* classification rules but emit structured
  // blocks ([_MdNode]) so one input renders consistently in every format.
  // ---------------------------------------------------------------------------

  static List<_MdNode> _parseMarkdown(String markdown) {
    final lines = markdown.split('\n');
    final nodes = <_MdNode>[];
    var i = 0;
    var inCode = false;
    final codeBuf = <String>[];
    final paraBuf = <String>[];
    String codeLang = '';

    void flushPara() {
      if (paraBuf.isEmpty) return;
      final joined = paraBuf
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join(' ');
      if (joined.isNotEmpty) {
        nodes.add(_MdNode(kind: 'paragraph', text: joined));
      }
      paraBuf.clear();
    }

    void flushCode() {
      if (codeBuf.isNotEmpty) {
        nodes.add(
          _MdNode(kind: 'code', text: codeBuf.join('\n'), lang: codeLang),
        );
      }
      codeBuf.clear();
      codeLang = '';
    }

    while (i < lines.length) {
      final line = lines[i];

      if (inCode) {
        if (line.trimLeft().startsWith('```')) {
          inCode = false;
          flushCode();
        } else {
          codeBuf.add(line);
        }
        i++;
        continue;
      }

      // Opening fence of a fenced code block.
      final open = RegExp(r'^\s*```(\S*)\s*$').firstMatch(line);
      if (open != null) {
        flushPara();
        codeLang = open.group(1) ?? '';
        inCode = true;
        i++;
        continue;
      }

      // Headings (h1-h6).
      final h = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
      if (h != null) {
        flushPara();
        nodes.add(
          _MdNode(
            kind: 'heading',
            text: h.group(2)!,
            level: h.group(1)!.length,
          ),
        );
        i++;
        continue;
      }

      // Horizontal rule.
      if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
        flushPara();
        flushCode();
        nodes.add(const _MdNode(kind: 'hr'));
        i++;
        continue;
      }

      // Blockquote.
      if (line.startsWith('> ')) {
        flushPara();
        final buf = <String>[];
        while (i < lines.length && lines[i].startsWith('> ')) {
          buf.add(lines[i].substring(2).trim());
          i++;
        }
        nodes.add(_MdNode(kind: 'blockquote', text: buf.join(' ')));
        continue;
      }

      // Unordered list.
      if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
        flushPara();
        final buf = <String>[];
        while (i < lines.length && RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i])) {
          buf.add(lines[i].replaceFirst(RegExp(r'^\s*[-*+]\s+'), '').trim());
          i++;
        }
        nodes.add(_MdNode(kind: 'ul', items: buf));
        continue;
      }

      // Ordered list.
      if (RegExp(r'^\s*\d+\.\s+').hasMatch(line)) {
        flushPara();
        final buf = <String>[];
        while (i < lines.length && RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i])) {
          buf.add(lines[i].replaceFirst(RegExp(r'^\s*\d+\.\s+'), '').trim());
          i++;
        }
        nodes.add(_MdNode(kind: 'ol', items: buf));
        continue;
      }

      // Blank line ends the current paragraph.
      if (line.trim().isEmpty) {
        flushPara();
        i++;
        continue;
      }

      // Otherwise it is a paragraph line.
      paraBuf.add(line);
      i++;
    }
    flushPara();
    flushCode();
    return nodes;
  }

  static int _pdfHeaderLevel(int level) => level.clamp(1, 5);

  static pw.Widget _pdfCode(String text) {
    return pw.Container(
      decoration: const pw.BoxDecoration(color: PdfColors.grey300),
      padding: const pw.EdgeInsets.all(6),
      margin: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          font: pw.Font.courier(),
          fontSize: 9,
          color: PdfColors.grey900,
        ),
      ),
    );
  }

  static pw.Widget _pdfBulletList(List<String> items) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: items.map((i) => pw.Text('• $i')).toList(),
    );
  }

  static pw.Widget _pdfNumberedList(List<String> items) {
    var n = 0;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: items.map((i) => pw.Text('${++n}. $i')).toList(),
    );
  }

  static pw.Widget _pdfBlockquote(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(left: 12),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontStyle: pw.FontStyle.italic,
          color: PdfColors.grey800,
        ),
      ),
    );
  }

  /// Builds a real PDF document (bytes) from Markdown content.
  static Future<Uint8List> _buildPdfBytes(String markdown) async {
    final nodes = _parseMarkdown(markdown);
    final doc = pw.Document();
    final widgets = <pw.Widget>[];
    for (final n in nodes) {
      switch (n.kind) {
        case 'heading':
          widgets.add(pw.Header(level: _pdfHeaderLevel(n.level), text: n.text));
          break;
        case 'paragraph':
          widgets.add(pw.Text(n.text));
          break;
        case 'code':
          widgets.add(_pdfCode(n.text));
          break;
        case 'ul':
          widgets.add(_pdfBulletList(n.items));
          break;
        case 'ol':
          widgets.add(_pdfNumberedList(n.items));
          break;
        case 'blockquote':
          widgets.add(_pdfBlockquote(n.text));
          break;
        case 'hr':
          widgets.add(pw.Divider());
          break;
      }
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) => widgets.toList(),
      ),
    );
    return doc.save();
  }

  static String _docxHeadingLevel(int level) => level.clamp(1, 9).toString();

  static String _escapeXml(String s) => _escapeHtml(s);

  static void _writeDocxNode(StringBuffer buffer, _MdNode n) {
    final esc = _escapeXml;
    switch (n.kind) {
      case 'heading':
        buffer.write(
          '<w:p><w:pPr><w:pStyle w:val="Heading${_docxHeadingLevel(n.level)}"/></w:pPr>'
          '<w:r><w:t>${esc(n.text)}</w:t></w:r></w:p>',
        );
        break;
      case 'paragraph':
        buffer.write('<w:p><w:r><w:t>${esc(n.text)}</w:t></w:r></w:p>');
        break;
      case 'code':
        buffer.write(
          '<w:p><w:pPr><w:pStyle w:val="HTMLPreformatted"/></w:pPr>'
          '<w:r><w:t>${esc(n.text)}</w:t></w:r></w:p>',
        );
        break;
      case 'ul':
        for (final item in n.items) {
          buffer.write('<w:p><w:r><w:t>\u2022 ${esc(item)}</w:t></w:r></w:p>');
        }
        break;
      case 'ol':
        var number = 0;
        for (final item in n.items) {
          number++;
          buffer.write(
            '<w:p><w:r><w:t>$number. ${esc(item)}</w:t></w:r></w:p>',
          );
        }
        break;
      case 'blockquote':
        buffer.write(
          '<w:p><w:r><w:rPr><w:i/></w:rPr><w:t>${esc(n.text)}</w:t></w:r></w:p>',
        );
        break;
      case 'hr':
        buffer.write('<w:p><w:r><w:t>\u2014\u2014\u2014</w:t></w:r></w:p>');
        break;
    }
  }

  /// Builds a real DOCX (OOXML) document as a ZIP byte buffer from Markdown.
  static Future<Uint8List> _buildDocxBytes(String markdown) async {
    final nodes = _parseMarkdown(markdown);
    final buffer = StringBuffer();
    buffer.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    buffer.write(
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    );
    buffer.write('<w:body>');
    for (final n in nodes) {
      _writeDocxNode(buffer, n);
    }
    buffer.write('<w:sectPr/>');
    buffer.write('</w:body></w:document>');

    final archive = Archive();
    archive.addFile(
      ArchiveFile.bytes('[Content_Types].xml', utf8.encode(_kDocxContentTypes)),
    );
    archive.addFile(ArchiveFile.bytes('_rels/.rels', utf8.encode(_kDocxRels)));
    archive.addFile(
      ArchiveFile.bytes(
        'word/_rels/document.xml.rels',
        utf8.encode(_kDocxDocRels),
      ),
    );
    archive.addFile(
      ArchiveFile.bytes('word/document.xml', utf8.encode(buffer.toString())),
    );
    final List<int> zip = ZipEncoder().encode(archive);
    return Uint8List.fromList(zip);
  }
}

/// A single classified Markdown block, shared by the PDF and DOCX builders.
///
/// [kind] is one of: `heading`, `paragraph`, `code`, `ul`, `ol`, `blockquote`,
/// or `hr`.
class _MdNode {
  final String kind;
  final String text;
  final int level; // heading level (1..6)
  final List<String> items; // list items (ul/ol)
  final String lang; // code-fence language
  const _MdNode({
    required this.kind,
    this.text = '',
    this.level = 0,
    this.items = const [],
    this.lang = '',
  });
}

// ---------------------------------------------------------------------------
// Minimal OOXML (DOCX) package parts. A .docx is a ZIP containing these XML
// files; together they form a valid, openable Word document.
// ---------------------------------------------------------------------------
const String _kDocxContentTypes =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>''';

const String _kDocxRels =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''';

const String _kDocxDocRels =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>''';
