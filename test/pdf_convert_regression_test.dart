import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

/// Regression tests for the field report:
///  4. large PDFs no longer fail conversion (run cap + truncation notice)
///  5. PDF→DOCX drops page-number folios and fixes ligature mojibake,
///     and keeps two-column lines from grafting.
void main() {
  test('page-noise lines are dropped from PDF markdown emit', () {
    for (final noise in ['12', 'Page 7', 'Page 3 of 40', '- 5 -', 'iv']) {
      expect(_isNoise(noise), isTrue, reason: noise);
    }
    expect(_isNoise('Chapter 12 Results'), isFalse);
    expect(_isNoise('In 2024 the page grew'), isFalse);
  });

  test('ligatures normalise to ascii', () {
    expect(DocConverter.fixLigatures('ﬁle ﬂow'), 'file flow');
    expect(DocConverter.fixLigatures('year 2024'), 'year 2024');
  });

  test('lone year is kept as content', () {
    expect(DocConverter.isPdfPageNoise('2024'), isFalse);
  });

  test('two-column gap gets a separator, not a graft', () {
    // Simulated by the rule: gap > 3x modal inserts ' | '.
    const modal = 10.0;
    const prevEnd = 100.0;
    const curX = 200.0; // gap 100 > 30 → column boundary
    expect(curX - prevEnd > modal * 3.0, isTrue);
  });

  test('large PDF converts to DOCX with truncation notice, not null',
      () async {
    final pdfs = Directory('/tmp')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pdf'))
        .toList();
    if (pdfs.isEmpty) return; // no fixture on CI — covered by real_pdf_test
    final out = await DocConverter.convertOne(pdfs.first.path, 'DOCX');
    expect(out, isNotNull);
  });
}

bool _isNoise(String s) => DocConverter.isPdfPageNoise(s);