// Test the parser against a more representative real-world DOCX (with
// namespace soup, SDT, etc.). Mirrors what most Word docs look like.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/docx_reader.dart';

void main() {
  const path = '/tmp/swordfm_realdocx.docx';

  test('parses real-world DOCX with namespace soup + SDT', () async {
    if (!File(path).existsSync()) {
      throw StateError('Missing $path');
    }
    final doc = await DocxReader.parse(path);
    expect(doc.blocks, isNotEmpty);
    // Heading should be detected.
    expect(doc.blocks.whereType<DocxHeading>(), isNotEmpty);
    // SDT content is collapsed into a paragraph.
    final paras = doc.blocks.whereType<DocxParagraph>().toList();
    expect(paras.length, greaterThanOrEqualTo(3));
    // "Inside an SDT" must appear.
    final all = doc.blocks
        .where((b) => b is DocxParagraph || b is DocxHeading)
        .expand((b) => b is DocxHeading
            ? b.runs.map((r) => r.text)
            : (b as DocxParagraph).runs.map((r) => r.text))
        .join(' ');
    expect(all, contains('Inside an SDT'));
    expect(all, contains('Real-world DOCX'));
  });
}
