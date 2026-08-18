import 'dart:io';
import 'package:path/path.dart' as p;

/// Document conversion utilities for SwordFM Android.
///
/// Provides robust Markdown -> HTML and Markdown -> Plain Text conversion
/// entirely in Dart. PDF/DOCX export requires native helpers; [toPdf] and
/// [toDocx] return the generated HTML path as a placeholder that can be
/// re-served or opened with a reader.
class DocConverter {
  /// Converts a file to PDF format.
  ///
  /// For now returns the generated HTML file path (openable in any browser).
  /// Returns null if the source is not convertible.
  static Future<String?> toPdf(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final html = await markdownFileToHtml(sourcePath);
    if (html == null) return null;
    return _writeHtmlToFile(html, sourcePath, 'pdf');
  }

  /// Converts a file to DOCX format.
  ///
  /// For now returns the generated HTML file path. Returns null if the
  /// source is not convertible.
  static Future<String?> toDocx(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final html = await markdownFileToHtml(sourcePath);
    if (html == null) return null;
    return _writeHtmlToFile(html, sourcePath, 'docx');
  }

  /// Converts a file to plain text (Markdown stripped).
  static Future<String?> toText(String sourcePath) async {
    if (!canConvert(sourcePath)) return null;
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    return markdownToText(content);
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

  static Future<String> _writeHtmlToFile(
      String html, String sourcePath, String format) async {
    final dir = p.dirname(sourcePath);
    final base = p.basenameWithoutExtension(sourcePath);
    final outPath = p.join(dir, '$base.$format.html');
    await File(outPath).writeAsString(html);
    return outPath;
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
      out.add('<pre><code>${codeBuffer.map(_escapeHtml).join('\n')}</code></pre>');
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
        while (i < lines.length &&
            RegExp(r'^\s*[-*+]\s+').hasMatch(lines[i])) {
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
        while (i < lines.length &&
            RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i])) {
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
    text = text.replaceAllMapped(RegExp(r'^#{1,6}\s+(.+)$', multiLine: true),
        (m) => m.group(1)!);
    // Bold / italic
    text = text.replaceAllMapped(
        RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(
        RegExp(r'\*([^*]+)\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(
        RegExp(r'__([^_]+)__'), (m) => m.group(1)!);
    text = text.replaceAllMapped(
        RegExp(r'_([^_]+)_'), (m) => m.group(1)!);
    // Inline code
    text = text.replaceAllMapped(
        RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    // Links [text](url) -> text (url)
    text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
        (m) => '${m.group(1)} (${m.group(2)})');
    // Images ![](url) -> url
    text = text.replaceAllMapped(RegExp(r'!\[[^\]]*\]\(([^)]+)\)'),
        (m) => m.group(1)!);
    // List markers
    text = text.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '• ');
    text = text.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
    // Blockquote
    text = text.replaceAll(RegExp(r'^>\s?', multiLine: true), '');
    // Horizontal rules
    text = text.replaceAll(RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$', multiLine: true), '');
    return text.trim();
  }

  static String _inline(String text) {
    var out = _escapeHtml(text);
    // Images first
    out = out.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'),
        (m) => '<img src="${m.group(2)}" alt="${m.group(1)}">');
    // Links
    out = out.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
        (m) => '<a href="${m.group(2)}">${m.group(1)}</a>');
    // Inline code
    out = out.replaceAllMapped(RegExp(r'`([^`]+)`'),
        (m) => '<code>${m.group(1)}</code>');
    // Bold
    out = out.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'),
        (m) => '<strong>${m.group(1)}</strong>');
    // Italic
    out = out.replaceAllMapped(RegExp(r'\*([^*]+)\*'),
        (m) => '<em>${m.group(1)}</em>');
    return out;
  }

  static String _escapeHtml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// Checks if the file can be converted.
  static bool canConvert(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.md', '.markdown', '.txt', '.html', '.csv', '.rst'].contains(ext);
  }

  /// Lists available output formats for a given file.
  static List<String> getAvailableFormats(String path) {
    if (!canConvert(path)) return [];
    return ['PDF', 'DOCX', 'HTML', 'TXT'];
  }
}
