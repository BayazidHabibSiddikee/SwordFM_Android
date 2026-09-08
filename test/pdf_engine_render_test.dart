import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/pdf_engine.dart';

/// Proves the poppler desktop render backend produces real, non-empty PNG
/// pages for a real multi-page PDF, and that pageCount() matches `pdfinfo`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? findRealPdf() {
    const candidates = [
      '/home/sword/Documents/Study/RUET/course-curriculum_11.pdf',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  group('PdfEngine (poppler backend)', () {
    test('hasRenderer is true where pdftoppm is installed', () async {
      // On this dev box poppler is present; if it isn't, the rest is moot.
      if (which('pdftoppm') == null) return; // skip softly
      expect(await PdfEngine.hasRenderer, isTrue);
    });

    test('pageCount matches pdfinfo and renderPage yields a real PNG', () async {
      final path = findRealPdf();
      if (path == null) return; // corpus not mounted

      final pages = await PdfEngine.pageCount(path);
      expect(pages, isNotNull);
      expect(pages, greaterThan(1));

      // Cross-check against pdfinfo directly.
      final info = await Process.run('pdfinfo', [path]);
      final m =
          RegExp(r'^Pages:\s*(\d+)', multiLine: true).firstMatch(info.stdout.toString());
      expect(pages, int.parse(m!.group(1)!));

      for (final page in [1, 2]) {
        final out = await PdfEngine.renderPage(path, page, width: 640);
        expect(out, isNotNull, reason: 'page $page should render');
        final f = File(out!);
        expect(f.existsSync(), isTrue);
        final len = f.lengthSync();
        expect(len, greaterThan(5000),
            reason: 'rendered page $page should be a real image, got $len B');
        await f.delete(); // cleanup
      }
    });
  });
}

String? which(String exe) {
  final dirs = (Platform.environment['PATH'] ?? '').split(':');
  for (final d in dirs) {
    if (d.isEmpty) continue;
    final c = File('$d/$exe');
    if (c.existsSync()) return c.path;
  }
  return null;
}
