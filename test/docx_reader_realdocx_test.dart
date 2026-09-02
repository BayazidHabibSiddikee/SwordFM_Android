// Regression tests for the DOCX preview error: ZIP entries must be read via
// readBytes() (archive 4.x-safe) instead of the `content` getter, which can
// yield empty data for stored / unsupported-compression entries.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/docx_reader.dart';

/// Builds a minimal valid .docx (ZIP with word/document.xml) on disk.
Future<String> _writeDocx(String path, String bodyXml) async {
  final archive = Archive();
  archive.addFile(ArchiveFile.bytes(
    'word/document.xml',
    utf8.encode(bodyXml),
  ));
  final zipBytes = ZipEncoder().encode(archive);
  await File(path).writeAsBytes(zipBytes);
  return path;
}

void main() {
  late String docxPath;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('swordfm_docx_test_');
    docxPath = await _writeDocx(
      '${tmp.path}/built.docx',
      '''<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Hello preview</w:t></w:r></w:p>
    <w:p><w:r><w:t>Second line</w:t></w:r></w:p>
  </w:body>
</w:document>''',
    );
  });

  test('DocxReader.parse reads document.xml via readBytes()', () async {
    final doc = await DocxReader.parse(docxPath);
    expect(doc.blocks, isNotEmpty);
    final all = doc.blocks
        .whereType<DocxParagraph>()
        .expand((b) => b.runs.map((r) => r.text))
        .join(' ');
    expect(all, contains('Hello preview'));
    expect(all, contains('Second line'));
  });

  test('parses real-world DOCX with namespace soup + SDT', () async {
    const path = '/tmp/swordfm_realdocx.docx';
    if (!File(path).existsSync()) {
      // Fixture is generated locally; skip rather than fail elsewhere.
      return;
    }
    final doc = await DocxReader.parse(path);
    expect(doc.blocks, isNotEmpty);
    expect(doc.blocks.whereType<DocxHeading>(), isNotEmpty);
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

