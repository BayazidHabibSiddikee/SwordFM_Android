import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

/// One slide's recovered text: the first non-empty run is treated as the
/// title (matching what most slides look like), the rest as bullet lines.
class PptxSlide {
  final int number;
  final String title;
  final List<String> lines;
  const PptxSlide({
    required this.number,
    required this.title,
    required this.lines,
  });

  bool get isEmpty => title.isEmpty && lines.isEmpty;
}

/// A parsed presentation outline: per-slide text in reading order.
class PptxOutline {
  final List<PptxSlide> slides;
  const PptxOutline({required this.slides});

  int get slideCount => slides.length;
}

/// Pure-Dart PPTX outline parser (no native deps).
///
/// A `.pptx` is a ZIP of slide XML files; text lives in `<a:t>…</a:t>`
/// elements. This recovers per-slide titles + body lines — an outline, not
/// a render: shapes, images, charts, and themes are out of scope for a
/// text-recovery pass and are documented as such in the viewer.
class PptxReader {
  /// Slides larger than this are skipped cheaply (same cap the preview uses).
  static const int maxFileBytes = 16 * 1024 * 1024;

  /// Parses [sourcePath] into an outline. Throws a descriptive [Exception]
  /// when the file is missing, oversized, or not a real presentation.
  static PptxOutline parse(String sourcePath) {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw Exception('File not found: $sourcePath');
    }
    if (file.lengthSync() > maxFileBytes) {
      throw Exception('Presentation is too large to open in-app.');
    }
    final bytes = file.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final slideFiles = archive.files
        .where(
          (f) =>
              f.name.startsWith('ppt/slides/slide') && f.name.endsWith('.xml'),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (slideFiles.isEmpty) {
      throw Exception('No slides found — is this a real .pptx file?');
    }
    const maxLinesPerSlide = 20;
    final slides = <PptxSlide>[];
    for (final slide in slideFiles) {
      final slideBytes = slide.readBytes();
      if (slideBytes == null) continue;
      final xml = utf8.decode(slideBytes, allowMalformed: true);
      final runs = RegExp(r'<a:t[^>]*>([^<]*)</a:t>')
          .allMatches(xml)
          .map((m) => _unescape(m.group(1)?.trim() ?? ''))
          .where((s) => s.isNotEmpty)
          .toList();
      final number = _slideNumber(slide.name);
      if (runs.isEmpty) {
        slides.add(PptxSlide(number: number, title: '', lines: const []));
        continue;
      }
      slides.add(
        PptxSlide(
          number: number,
          title: runs.first,
          lines: runs.skip(1).take(maxLinesPerSlide).toList(),
        ),
      );
    }
    return PptxOutline(slides: slides);
  }

  /// Best-effort outline that never throws: returns the slides, or an empty
  /// outline when parsing fails. The viewer surfaces the reason separately.
  static PptxOutline tryParse(String sourcePath) {
    try {
      return parse(sourcePath);
    } catch (_) {
      return const PptxOutline(slides: []);
    }
  }

  static int _slideNumber(String name) {
    final m = RegExp(r'slide(\d+)\.xml$').firstMatch(name);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  /// PPTX text runs use XML escapes; decode the common ones so titles read
  /// naturally instead of showing `&amp;`.
  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}
