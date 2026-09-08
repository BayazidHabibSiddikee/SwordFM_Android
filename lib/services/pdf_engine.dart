import 'dart:io';

import 'package:pdfx/pdfx.dart';

/// Platform-aware PDF rasterizer.
///
/// The app must show *rendered* PDF pages (not just extracted text) on every
/// platform it runs on. Android ships a bundled pdfium via `pdfx`, so it uses
/// that. The Linux/Windows/macOS desktop builds have **no** pdfium backend —
/// `pdfx.hasPdfSupport()` returns false there and every PDF used to dead-end
/// into the text fallback. Those platforms instead render through the
/// `poppler` command-line tools (`pdfinfo` + `pdftoppm`), which are present on
/// a typical developer machine and give a real, scrollable, zoomable reader.
///
/// All methods degrade gracefully: any failure returns `null` so callers can
/// fall back to the extracted-text reader and the document still opens.
class PdfEngine {
  PdfEngine._();

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Locate an executable on [PATH]. Returns the absolute path or null.
  static String? _which(String exe) {
    // PATH entries are separated by ';' on Windows and ':' elsewhere.
    final sep = Platform.isWindows ? ';' : ':';
    final dirs = (Platform.environment['PATH'] ?? '').split(sep);
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final candidate = File(dir + Platform.pathSeparator + exe);
      try {
        if (candidate.existsSync()) return candidate.path;
      } catch (_) {}
    }
    return null;
  }

  /// True when a native rasterizer is available on this platform.
  static Future<bool> get hasRenderer async {
    if (_isMobile) return await hasPdfSupport();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return _which('pdftoppm') != null;
    }
    return false;
  }

  /// Number of pages in [path], or null when it cannot be determined.
  static Future<int?> pageCount(String path) async {
    if (_isMobile) {
      try {
        final doc = await PdfDocument.openFile(path);
        final n = doc.pagesCount;
        await doc.close();
        return n;
      } catch (_) {
        return null;
      }
    }
    try {
      final r = await Process.run('pdfinfo', [path]);
      if (r.exitCode != 0) return null;
      final m = RegExp(r'^Pages:\s*(\d+)', multiLine: true)
          .firstMatch(r.stdout.toString());
      return m == null ? null : int.tryParse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// Renders [page] (1-based) of [path] to a PNG and returns the output file
  /// path, or null when the page could not be rendered. [width] is the target
  /// pixel width; the height is derived from the page aspect ratio.
  static Future<String?> renderPage(
    String path,
    int page, {
    double width = 1080,
  }) async {
    if (_isMobile) {
      try {
        final doc = await PdfDocument.openFile(path);
        try {
          final p = await doc.getPage(page);
          final img = await p.render(
            width: width,
            height: (p.height * width / p.width),
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          );
          await p.close();
          if (img == null || img.bytes.isEmpty) return null;
          final out = File(
              '${Directory.systemTemp.path}/swordfm_pdfx_p$page.png');
          await out.writeAsBytes(img.bytes);
          return out.path;
        } finally {
          await doc.close();
        }
      } catch (_) {
        return null;
      }
    }

    // Desktop — render via poppler. A fixed, sane DPI is enough because the
    // reader/preview scale the image with BoxFit.contain anyway; 150 dpi keeps
    // body text crisp while staying fast and small.
    try {
      final tmp = await Directory.systemTemp.createTemp('swordfm_pdfppm_');
      final dpi = (width / 8.5).clamp(96, 300).round();
      final prefix = '${tmp.path}/p';
      final r = await Process.run(
          'pdftoppm', ['-png', '-r', '$dpi', '-f', '$page', '-l', '$page', path, prefix]);
      if (r.exitCode != 0) {
        await _safeDelete(tmp);
        return null;
      }
      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      if (files.isEmpty) {
        await _safeDelete(tmp);
        return null;
      }
      return files.first.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _safeDelete(Directory d) async {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }
}
