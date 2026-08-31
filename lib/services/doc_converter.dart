import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../utils/constants.dart' show AppPaths;

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
    try {
      final content = await _readSourceText(sourcePath);
      final bytes = await _buildPdfBytes(_preprocessForMarkdown(
        sourcePath,
        content,
      ));
      final outPath = _resolveOutputPath(sourcePath, '.pdf');
      await _writeOutput(outPath, bytes);
      return outPath;
    } catch (e) {
      // Surface the real reason instead of silently returning null.
      debugPrint('toPdf failed for $sourcePath: $e');
      return null;
    }
  }

  /// Converts a Markdown/text file to a real DOCX (OOXML ZIP), writing
  /// `<base>.docx` next to the source. Returns the output path, or null if the
  /// source is not convertible or missing.
  static Future<String?> toDocx(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    try {
      final content = await _readSourceText(sourcePath);
      final bytes = await _buildDocxBytes(_preprocessForMarkdown(
        sourcePath,
        content,
      ));
      final outPath = _resolveOutputPath(sourcePath, '.docx');
      await _writeOutput(outPath, bytes);
      return outPath;
    } catch (e) {
      debugPrint('toDocx failed for $sourcePath: $e');
      return null;
    }
  }

  /// Converts a file to plain text (Markdown stripped). PDF sources are
  /// handled by [fromPdf] (crude text extraction from content streams).
  static Future<String?> toText(String sourcePath) async {
    if (sourcePath.toLowerCase().endsWith('.pdf')) return fromPdf(sourcePath);
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    try {
      final content = await _readSourceText(sourcePath);
      final text = markdownToText(_preprocessForMarkdown(sourcePath, content));
      final outPath = _resolveOutputPath(sourcePath, '.txt');
      await _writeOutput(outPath, text.codeUnits);
      return outPath;
    } catch (e) {
      debugPrint('toText failed for $sourcePath: $e');
      return null;
    }
  }

  /// Reads any convertible source as text. `.docx` sources are ZIP binaries —
  /// the text is pulled from `word/document.xml`; everything else is decoded
  /// as UTF-8 with malformed bytes tolerated (previously a strict
  /// `readAsString` threw FormatException on DOCX or non-UTF-8 files, making
  /// conversion fail).
  static Future<String> _readSourceText(String sourcePath) async {
    final ext = p.extension(sourcePath).toLowerCase();
    if (ext == '.docx') {
      // DOCX is a ZIP binary — pull the text out of word/document.xml
      // directly (without writing anything).
      try {
        final bytes = await File(sourcePath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final docXml = archive.files
            .where((f) => f.name == 'word/document.xml')
            .firstOrNull;
        if (docXml == null) return '';
        final xml = utf8.decode(docXml.content as List<int>, allowMalformed: true);
        return xml
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
      } catch (_) {
        return '';
      }
    }
    if (ext == '.pdf') {
      return _extractPdfTextSync(sourcePath) ?? '';
    }
    final bytes = await File(sourcePath).readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Extracts the plain text of a `.pdf` file, writing `<base>.txt` next to
  /// the source. Text is recovered by decompressing the FlateDecode content
  /// streams and pulling the literal strings from the text-showing operators
  /// (Tj / TJ). Encrypted or image-only PDFs yield null.
  static Future<String?> fromPdf(String sourcePath) async {
    final text = _extractPdfTextSync(sourcePath);
    if (text == null || text.isEmpty) return null;
    try {
      final outPath = _resolveOutputPath(sourcePath, '.txt');
      await _writeOutput(outPath, text.codeUnits);
      return outPath;
    } catch (e) {
      debugPrint('fromPdf write failed for $sourcePath: $e');
      return null;
    }
  }

  /// Synchronous PDF text extraction. Handles both `(…)Tj` literal strings and
  /// `<hex>Tj` hex strings from TJ/Tj operators, tries every content stream
  /// (Flate-compressed with an uncompressed fallback), and tolerates the
  /// font/graphics operators mixed in so real-world PDFs convert reliably.
  static String? _extractPdfTextSync(String sourcePath) {
    try {
      final file = File(sourcePath);
      if (!file.existsSync()) return null;
      if (file.lengthSync() > 32 * 1024 * 1024) return null;
      final bytes = file.readAsBytesSync();
      // Latin-1 round-trips every byte 1:1, letting us slice raw stream
      // boundaries on a String without corrupting binary data.
      final raw = latin1.decode(bytes, allowInvalid: true);
      final out = StringBuffer();
      for (final part in raw.split('endstream')) {
        final s = part.indexOf('stream');
        if (s < 0) continue;
        var data = part.substring(s + 'stream'.length);
        if (data.startsWith('\r\n')) {
          data = data.substring(2);
        } else if (data.startsWith('\n') || data.startsWith('\r')) {
          data = data.substring(1);
        }
        String content;
        try {
          final inflated = ZLibDecoder().decodeBytes(data.codeUnits);
          content = latin1.decode(inflated, allowInvalid: true);
        } catch (_) {
          // Not FlateDecode — try the raw data as the content stream.
          content = latin1.decode(data.codeUnits, allowInvalid: true);
        }
        // Only text-showing content streams matter.
        if (!content.contains('BT') || !RegExp(r'\bTj\b|\bTJ\b').hasMatch(content)) {
          continue;
        }
        final chunk = StringBuffer();
        // Literal strings: ( ... )
        for (final m
            in RegExp(r'\(((?:\\.|[^()\\])*)\)').allMatches(content)) {
          chunk.write(_unescapePdfString(m.group(1)!));
          chunk.write(' ');
        }
        // Hex strings: < ... >
        for (final m in RegExp(r'<([0-9a-fA-F\s]+)>').allMatches(content)) {
          chunk.write(_decodePdfHex(m.group(1)!));
          chunk.write(' ');
        }
        final line = chunk.toString().trim();
        if (line.isNotEmpty) out.writeln(line);
      }
      final text = out.toString().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Decodes a PDF hex string (`<414243>` → `ABC`). Digits are pairs of hex
  /// bytes; whitespace is ignored.
  static String _decodePdfHex(String hex) {
    final buf = StringBuffer();
    final cleaned = hex.replaceAll(RegExp(r'\s+'), '');
    for (var i = 0; i + 1 < cleaned.length; i += 2) {
      final byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (byte == null) continue;
      if (byte >= 0x20 && byte <= 0x7e) {
        buf.writeCharCode(byte);
      } else {
        buf.writeCharCode(byte.toUnsigned(8));
      }
    }
    return buf.toString();
  }

  /// Resolves PDF literal-string escapes (\n \r \t \b \f \( \) \\ and octal).
  static String _unescapePdfString(String s) {
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == r'\' && i + 1 < s.length) {
        final next = s[++i];
        switch (next) {
          case 'n':
            buf.write('\n');
            break;
          case 'r':
            buf.write('\r');
            break;
          case 't':
            buf.write('\t');
            break;
          case 'b':
            buf.write('\b');
            break;
          case 'f':
            buf.write('\f');
            break;
          case '(':
          case ')':
          case r'\':
            buf.write(next);
            break;
          default:
            if (next.codeUnitAt(0) >= 0x30 && next.codeUnitAt(0) <= 0x37) {
              // Octal escape: up to 3 digits.
              var oct = next;
              while (oct.length < 3 &&
                  i + 1 < s.length &&
                  s[i + 1].codeUnitAt(0) >= 0x30 &&
                  s[i + 1].codeUnitAt(0) <= 0x37) {
                oct += s[++i];
              }
              buf.writeCharCode(int.parse(oct, radix: 8));
            } else {
              buf.write(next);
            }
        }
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
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
      final outPath = _resolveOutputPath(sourcePath, '.txt');
      await _writeOutput(outPath, text.codeUnits);
      return outPath;
    } catch (e) {
      debugPrint('fromDocx failed for $sourcePath: $e');
      return null;
    }
  }

  /// Resolves a writable output path for a converted file. Prefers the source
  /// directory (output next to the original) but falls back to a dedicated,
  /// guaranteed-writable folder when the source directory cannot be written
  /// (e.g. a read-only scoped-storage location on Android without
  /// MANAGE_EXTERNAL_STORAGE). Returns an absolute path that may not yet exist.
  static String _resolveOutputPath(String sourcePath, String newExt) {
    final sourceDir = p.dirname(sourcePath);
    final base = p.basenameWithoutExtension(sourcePath);
    // Try writing next to the source only if that directory is writable;
    // otherwise fall back to the SwiftFM downloads folder.
    final dir = _isWritable(sourceDir) ? sourceDir : AppPaths.swordfmDownloads;
    Directory(dir).createSync(recursive: true);
    return p.join(dir, '$base$newExt');
  }

  static bool _isWritable(String dir) {
    try {
      final probe = File(
        p.join(dir, '.swordfm_probe_${DateTime.now().millisecondsSinceEpoch}'),
      );
      probe.createSync();
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Writes bytes to [path], creating the parent directory if needed.
  static Future<void> _writeOutput(String path, List<int> bytes) async {
    final dir = p.dirname(path);
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}
    await File(path).writeAsBytes(bytes);
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

  /// Reads a Markdown/text file, renders it to a full HTML document, and
  /// writes `<base>.html` to the resolved output directory. Returns the output
  /// path (or null if the source is missing).
  static Future<String?> markdownFileToHtml(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final content = await _readSourceText(path);
      final title = p.basenameWithoutExtension(path);
      final body = markdownToHtml(content);
      final html = '<!DOCTYPE html>\n<html>\n<head>\n'
          '<meta charset="utf-8">\n<title>$title</title>\n'
          '<style>'
          'body{font-family:-apple-system,sans-serif;line-height:1.6;'
          'max-width:760px;margin:32px auto;padding:0 20px;color:#333}'
          'pre{background:#f4f4f4;padding:12px;border-radius:6px;overflow:auto}'
          'code{background:#f4f4f4;padding:2px 4px;border-radius:3px}'
          'blockquote{border-left:4px solid #61afef;margin:0;padding-left:12px;color:#555}'
          '</style>\n</head>\n<body>\n$body\n</body>\n</html>\n';
      final outPath = _resolveOutputPath(path, '.html');
      await _writeOutput(outPath, utf8.encode(html));
      return outPath;
    } catch (e) {
      debugPrint('markdownFileToHtml failed for $path: $e');
      return null;
    }
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
  /// PDF and DOCX are also accepted as source inputs (DOCX→text, PDF→cover
  /// page thumbnail only; full PDF→other is handled externally).
  static bool canConvert(String path) {
    final ext = p.extension(path).toLowerCase();
    const textExts = {
      '.md', '.markdown', '.txt', '.html', '.htm', '.csv', '.rst',
      '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
      '.log', '.css', '.js', '.ts', '.jsx', '.tsx', '.py', '.dart',
      '.java', '.kt', '.c', '.cpp', '.h', '.rs', '.go', '.sh', '.bat',
      '.sql', '.env', '.gitignore', '.diff', '.docx', '.pdf',
    };
    return textExts.contains(ext);
  }

  /// Lists available output formats for a given file (PDF→PDF is not offered —
  /// the source is already a PDF).
  static List<String> getAvailableFormats(String path) {
    if (!canConvert(path)) return [];
    final list = ['PDF', 'DOCX', 'HTML', 'TXT'];
    if (p.extension(path).toLowerCase() == '.pdf') list.remove('PDF');
    return list;
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
    // NB: '•' (U+2022) is not encodable by the default Helvetica base font
    // and made doc.save() throw — plain ASCII bullets keep conversion working.
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: items.map((i) => pw.Text('- $i')).toList(),
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
          widgets.add(
            pw.Header(level: _pdfHeaderLevel(n.level), text: _pdfSafe(n.text)),
          );
          break;
        case 'paragraph':
          widgets.add(pw.Text(_pdfSafe(n.text)));
          break;
        case 'code':
          widgets.add(_pdfCode(_pdfSafe(n.text)));
          break;
        case 'ul':
          widgets.add(
            _pdfBulletList(n.items.map(_pdfSafe).toList(growable: false)),
          );
          break;
        case 'ol':
          widgets.add(
            _pdfNumberedList(n.items.map(_pdfSafe).toList(growable: false)),
          );
          break;
        case 'blockquote':
          widgets.add(_pdfBlockquote(_pdfSafe(n.text)));
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

  /// Makes text encodable by the default Helvetica base 14 font. Any code
  /// point outside Latin-1 previously made `doc.save()` throw, failing the
  /// whole conversion. Common typographic characters are mapped to ASCII
  /// equivalents; the rest become '?'.
  static String _pdfSafe(String text) {
    const map = {
      '\u2013': '-', // en dash
      '\u2014': '-', // em dash
      '\u2018': "'", '\u2019': "'", '\u201A': ',',
      '\u201C': '"', '\u201D': '"',
      '\u2022': '-', '\u2026': '...',
      '\u00A0': ' ', '\u2192': '->', '\u2190': '<-',
      '\t': '    ',
    };
    final buf = StringBuffer();
    for (final rune in text.runes) {
      if (rune <= 0xFF) {
        buf.writeCharCode(rune);
      } else {
        final ch = String.fromCharCode(rune);
        buf.write(map[ch] ?? '?');
      }
    }
    return buf.toString();
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
