// Regression tests for the DOCX preview error: ZIP entries must be read via
// readBytes() (archive 4.x-safe) instead of the `content` getter, which can
// yield empty data for stored / unsupported-compression entries.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/docx_reader.dart';
import 'package:swordfm/widgets/preview_panel.dart'
    show docxTextFromPath, readTextCapped;

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

  test('preview isolate entry point extracts DOCX text via compute()',
      () async {
    // Regression: the old code ran Isolate.run(() => _extractDocx(path))
    // from inside the State class — the closure captured `this` (the widget
    // tree) and blew up with "object is unsendable". compute() with a
    // top-level function must succeed.
    final text = await compute(docxTextFromPath, docxPath);
    expect(text, contains('Hello preview'));
    expect(text, contains('Second line'));
    expect(text, isNot(contains('[Could not read document')));
  });

  test('preview isolate entry point reads capped text via compute()',
      () async {
    final tmp = await Directory.systemTemp.createTemp('swordfm_txt_test_');
    final txt = File('${tmp.path}/note.txt');
    await txt.writeAsString('plain text preview');
    final text = await compute(readTextCapped, txt.path);
    expect(text, contains('plain text preview'));
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

