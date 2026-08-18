import 'package:path/path.dart' as p;

/// Document conversion utilities for SwordFM Android.
///
/// Note: Full PDF/Word conversion requires heavy native dependencies
/// (e.g., pandoc, LibreOffice). This module provides stubs that can be
/// connected to a server-side converter or external API.
class DocConverter {
  /// Converts a file to PDF format.
  /// Returns null if conversion is not available.
  static Future<String?> toPdf(String sourcePath) async {
    // TODO: Integrate with pandoc/LibreOffice or cloud API
    return null;
  }

  /// Converts a file to DOCX format.
  /// Returns null if conversion is not available.
  static Future<String?> toDocx(String sourcePath) async {
    // TODO: Integrate with pandoc/LibreOffice or cloud API
    return null;
  }

  /// Converts markdown content to plain HTML string.
  static Future<String> markdownToHtml(String markdown) async {
    // Simple inline conversion for preview purposes
    // For full conversion, use a dedicated markdown parser
    var html = markdown;
    html = html.replaceAllMapped(RegExp(r'^# (.+$)', multiLine: true), (m) => '<h1>${m.group(1)}</h1>');
    html = html.replaceAllMapped(RegExp(r'^## (.+$)', multiLine: true), (m) => '<h2>${m.group(1)}</h2>');
    html = html.replaceAllMapped(RegExp(r'^### (.+$)', multiLine: true), (m) => '<h3>${m.group(1)}</h3>');
    html = html.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => '<strong>${m.group(1)}</strong>');
    html = html.replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => '<em>${m.group(1)}</em>');
    html = html.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => '<code>${m.group(1)}</code>');
    html = html.replaceAll('\n\n', '</p><p>');
    html = html.replaceAll('\n', '<br>');
    return '<p>$html</p>';
  }

  /// Checks if the file can be converted.
  static bool canConvert(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.md', '.txt', '.html', '.csv', '.rst'].contains(ext);
  }

  /// Lists available output formats for a given file.
  static List<String> getAvailableFormats(String path) {
    if (!canConvert(path)) return [];
    return ['PDF', 'DOCX', 'HTML'];
  }
}
