// Smoke test for the DOCX parser using a real .docx fixture.
// Build the fixture first with python (see test/_docx_fixture.sh), then run:
//   flutter test test/docx_reader_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/docx_reader.dart';

void main() {
  const path = '/tmp/swordfm_test.docx';

  setUpAll(() {
    if (!File(path).existsSync()) {
      throw StateError(
        'Missing $path — build it first with the included python script',
      );
    }
  });

  test('parses a real .docx fixture end-to-end', () async {
    final doc = await DocxReader.parse(path);
    expect(doc.blocks, isNotEmpty);

    final headings = doc.blocks.whereType<DocxHeading>().toList();
    expect(headings, isNotEmpty);
    expect(headings.first.level, 1);
    expect(
      headings.first.runs.map((r) => r.text).join(),
      contains('SwordFM'),
    );

    final tables = doc.blocks.whereType<DocxTable>().toList();
    expect(tables, hasLength(1));
    expect(tables.first.rows, hasLength(2));
    expect(tables.first.rows.first, hasLength(2));

    final rich = doc.blocks.whereType<DocxParagraph>().firstWhere(
          (p) => p.runs.any((r) => r.bold) && p.runs.any((r) => r.italic),
        );
    expect(rich.runs.length, greaterThanOrEqualTo(4));
    expect(rich.runs.where((r) => r.bold), isNotEmpty);
    expect(rich.runs.where((r) => r.italic), isNotEmpty);

    final hasLink = doc.blocks.any(
      (b) => b is DocxParagraph && b.runs.any((r) => r.link != null),
    );
    expect(hasLink, isTrue);
  });
}
