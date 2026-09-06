import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

/// Path to the real-world PDF under test.
const String _kTestPdf =
    '/home/sword/Documents/Study/RUET/32 Semester/Sessionals/ME 3256/ME 3256 Lab Guideline Manual.pdf';

void main() {
  group('ME 3256 Lab Guideline Manual PDF', () {
    late File pdfFile;

    setUpAll(() {
      pdfFile = File(_kTestPdf);
    });

    test('file exists on disk', () {
      expect(pdfFile.existsSync(), isTrue,
          reason: 'PDF file not found at $_kTestPdf');
    });

    test('file is non-empty and reasonable size', () {
      final size = pdfFile.lengthSync();
      expect(size, greaterThan(1024),
          reason: 'PDF should be at least 1 KB');
      expect(size, lessThan(100 * 1024 * 1024),
          reason: 'PDF should be under 100 MB');
    });

    test('canConvert returns true for .pdf', () {
      expect(DocConverter.canConvert(_kTestPdf), isTrue);
    });

    test('getAvailableFormats excludes PDF (already a PDF)', () {
      final formats = DocConverter.getAvailableFormats(_kTestPdf);
      expect(formats, isNot(contains('PDF')));
      expect(formats, containsAll(['DOCX', 'HTML', 'TXT']));
    });

    test('fromPdf extracts text without crashing', () async {
      final txtPath = await DocConverter.fromPdf(_kTestPdf);
      // The method may return null for image-only or encrypted PDFs —
      // that is acceptable. What matters is it doesn't throw.
      if (txtPath != null) {
        expect(File(txtPath).existsSync(), isTrue);
        // fromPdf writes Latin-1 code units; read back as latin1.
        final bytes = File(txtPath).readAsBytesSync();
        final content = latin1.decode(bytes, allowInvalid: true);
        expect(content.length, greaterThan(0),
            reason: 'Extracted text should not be empty');
      }
    });

    test('toText round-trips PDF to TXT', () async {
      final txtPath = await DocConverter.toText(_kTestPdf);
      if (txtPath != null) {
        expect(txtPath, endsWith('.txt'));
        expect(File(txtPath).existsSync(), isTrue);
        final bytes = File(txtPath).readAsBytesSync();
        final content = latin1.decode(bytes, allowInvalid: true);
        expect(content.length, greaterThan(0));
      }
    });

    test('toDocx converts PDF source to DOCX', () async {
      final docxPath = await DocConverter.toDocx(_kTestPdf);
      if (docxPath != null) {
        expect(docxPath, endsWith('.docx'));
        expect(File(docxPath).existsSync(), isTrue);
        final size = File(docxPath).lengthSync();
        expect(size, greaterThan(0));
      }
    });

    test('markdownFileToHtml handles PDF source path', () async {
      // PDF is not markdown, but the converter should handle it gracefully
      // (read the text and produce HTML, or return null).
      final htmlPath = await DocConverter.markdownFileToHtml(_kTestPdf);
      if (htmlPath != null) {
        expect(htmlPath, endsWith('.html'));
        expect(File(htmlPath).existsSync(), isTrue);
      }
    });
  });
}
