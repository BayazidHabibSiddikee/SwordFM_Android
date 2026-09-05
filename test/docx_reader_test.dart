// Smoke test for the DOCX parser using a real .docx fixture.
// The fixture (ZIP with word/document.xml + relationships) is built in Dart
// at setup — no external script or pre-existing file needed.
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/docx_reader.dart';

/// Builds a minimal valid .docx (ZIP with word/document.xml) on disk.
Future<String> _writeDocx(String path, String bodyXml, String relsXml) async {
  final archive = Archive();
  archive.addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(bodyXml)));
  archive.addFile(
    ArchiveFile.bytes('word/_rels/document.xml.rels', utf8.encode(relsXml)),
  );
  final zipBytes = ZipEncoder().encode(archive);
  await File(path).writeAsBytes(zipBytes);
  return path;
}

void main() {
  late String path;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('swordfm_docx_smoke_');
    path = await _writeDocx(
      '${tmp.path}/swordfm_test.docx',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>SwordFM</w:t></w:r>
      <w:r><w:t> heading</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:rPr><w:b/></w:rPr><w:t>Bold </w:t></w:r>
      <w:r><w:rPr><w:i/></w:rPr><w:t>italic </w:t></w:r>
      <w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>both </w:t></w:r>
      <w:r><w:t>plain.</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>See the </w:t></w:r>
      <w:hyperlink r:id="rId1"><w:r><w:t>docs</w:t></w:r></w:hyperlink>
      <w:r><w:t> online.</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Value</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>audio</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>mp3</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
      Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
      Target="https://example.com/docs" TargetMode="External"/>
</Relationships>''',
    );
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
