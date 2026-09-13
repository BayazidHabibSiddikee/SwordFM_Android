import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';
import 'package:swordfm/services/docx_reader.dart';

/// Regression tests for the "extra page numbers in DOCX output" reports:
/// Word stores PAGE/NUMPAGES/TOC fields as begin→instrText→separate→cached
/// result→end run sequences. The cached result is a STALE number from the
/// last Word save — it must never leak into converted output.
void main() {
  group('DOCX hidden field text', () {
    test('DocxReader drops PAGE field cached result', () async {
      final path = await _writeDocxWithBody('''
<w:p><w:r><w:t>Hello world</w:t></w:r></w:p>
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:fldChar w:fldCharType="begin"/></w:r>
<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
<w:r><w:fldChar w:fldCharType="separate"/></w:r>
<w:r><w:t>7</w:t></w:r>
<w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p>''');
      final doc = await DocxReader.parse(path);
      final text = doc.blocks
          .whereType<DocxParagraph>()
          .map((b) => b.runs.map((r) => r.text).join())
          .join('\n');
      expect(text, contains('Hello world'));
      expect(text, isNot(contains('7')));
      expect(text, isNot(contains('PAGE')));
    });

    test('DocxReader drops tracked deletions, keeps insertions', () async {
      final path = await _writeDocxWithBody('''
<w:p><w:r><w:t>Keep me</w:t></w:r></w:p>
<w:p><w:del><w:r><w:delText>Delete me</w:delText></w:r></w:del></w:p>
<w:p><w:ins><w:r><w:t>Added</w:t></w:r></w:ins></w:p>''');
      final doc = await DocxReader.parse(path);
      final text = doc.blocks
          .whereType<DocxParagraph>()
          .map((b) => b.runs.map((r) => r.text).join())
          .join('\n');
      expect(text, contains('Keep me'));
      expect(text, isNot(contains('Delete me')));
      expect(text, contains('Added'));
    });

    test('hidden-text strip removes instr/del/fldChar runs', () {
      const xml = '<w:p><w:r><w:t>Hi</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText>PAGE</w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>3</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
          '<w:del><w:r><w:delText>gone</w:delText></w:r></w:del>';
      final out = DocConverter.stripDocxHiddenTextForTest(xml);
      expect(out, contains('Hi'));
      expect(out, isNot(contains('PAGE')));
      expect(out, isNot(contains('gone')));
      expect(out, isNot(contains('fldChar')));
    });

    test('DOCX->PDF markdown has no stale page numbers', () async {
      final path = await _writeDocxWithBody('''
<w:p><w:r><w:t>Real content here</w:t></w:r></w:p>
<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>
<w:r><w:instrText> NUMPAGES </w:instrText></w:r>
<w:r><w:fldChar w:fldCharType="separate"/></w:r>
<w:r><w:t>42</w:t></w:r>
<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>''');
      final mdPath = await DocConverter.toMarkdown(path);
      expect(mdPath, isNotNull);
      final md = File(mdPath!).readAsStringSync();
      expect(md, contains('Real content here'));
      expect(md, isNot(contains('42')));
    });
  });
}

/// Builds a minimal .docx containing [bodyXml] as word/document.xml.
Future<String> _writeDocxWithBody(String bodyXml) async {
  final docXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$bodyXml<w:sectPr/></w:body></w:document>';
  final archive = Archive();
  archive.addFile(ArchiveFile.bytes(
      '[Content_Types].xml', DocConverter.testContentTypes.bytes));
  archive.addFile(
      ArchiveFile.bytes('_rels/.rels', DocConverter.testRels.bytes));
  archive.addFile(ArchiveFile.bytes('word/document.xml', docXml.codeUnits));
  final dir = await Directory.systemTemp.createTemp('docx_hidden_');
  final path = '${dir.path}/test.docx';
  await File(path).writeAsBytes(ZipEncoder().encode(archive));
  return path;
}
