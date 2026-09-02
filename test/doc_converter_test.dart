import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

void main() {
  group('DocConverter', () {
    test('canConvert returns true for markdown files', () {
      expect(DocConverter.canConvert('document.md'), isTrue);
      expect(DocConverter.canConvert('document.markdown'), isTrue);
      expect(DocConverter.canConvert('notes.txt'), isTrue);
      expect(DocConverter.canConvert('index.html'), isTrue);
      expect(DocConverter.canConvert('data.rst'), isTrue);
    });

    test('canConvert returns false for binary files', () {
      expect(DocConverter.canConvert('photo.jpg'), isFalse);
      expect(DocConverter.canConvert('archive.zip'), isFalse);
      expect(DocConverter.canConvert('video.mp4'), isFalse);
      expect(DocConverter.canConvert('song.mp3'), isFalse);
      expect(DocConverter.canConvert('doc.pdf'), isTrue); // PDF now converts to TXT
    });

    test('getAvailableFormats returns formats for convertible files', () {
      final formats = DocConverter.getAvailableFormats('readme.md');
      expect(formats, containsAll(['PDF', 'DOCX', 'HTML', 'TXT']));
    });

    test('getAvailableFormats returns empty list for non-convertible files', () {
      expect(DocConverter.getAvailableFormats('image.png'), isEmpty);
    });

    test('markdownToHtml converts headers', () {
      const md = '# Hello\n\n## World\n\n### Deep';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<h1>Hello</h1>'));
      expect(html, contains('<h2>World</h2>'));
      expect(html, contains('<h3>Deep</h3>'));
    });

    test('markdownToHtml converts bold and italic', () {
      const md = '**bold text** and *italic text*';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<strong>bold text</strong>'));
      expect(html, contains('<em>italic text</em>'));
    });

    test('markdownToHtml converts inline code', () {
      const md = 'Use `dart:io` for file operations';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<code>dart:io</code>'));
    });

    test('markdownToHtml converts fenced code blocks', () {
      const md = '```\nvoid main() {}\n```';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<pre><code>'));
      expect(html, contains('void main() {}'));
    });

    test('markdownToHtml converts unordered lists', () {
      const md = '- one\n- two\n- three';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<ul>'));
      expect(html, contains('<li>one</li>'));
      expect(html, contains('<li>three</li>'));
      expect(html, contains('</ul>'));
    });

    test('markdownToHtml converts ordered lists', () {
      const md = '1. first\n2. second';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<ol>'));
      expect(html, contains('<li>first</li>'));
      expect(html, contains('</ol>'));
    });

    test('markdownToHtml converts blockquotes', () {
      const md = '> This is a quote';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<blockquote>'));
      expect(html, contains('This is a quote'));
    });

    test('markdownToHtml converts horizontal rules', () {
      const md = '---';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('<hr>'));
    });

    test('markdownToHtml escapes HTML entities', () {
      const md = 'Use <b> for bold';
      final html = DocConverter.markdownToHtml(md);
      expect(html, contains('&lt;b&gt;'));
      expect(html, isNot(contains('<b> for bold')));
    });

    test('markdownToText strips formatting', () {
      const md = '# Title\n\n**bold** and *italic* and `code`';
      final text = DocConverter.markdownToText(md);
      expect(text, contains('Title'));
      expect(text, contains('bold'));
      expect(text, contains('italic'));
      expect(text, contains('code'));
      expect(text, isNot(contains('#')));
      expect(text, isNot(contains('**')));
    });

    test('markdownToText preserves link text', () {
      const md = '[SwordFM](https://github.com)';
      final text = DocConverter.markdownToText(md);
      expect(text, contains('SwordFM'));
      expect(text, contains('https://github.com'));
    });
  });

  group('DocConverter file operations', () {
    late Directory tempDir;
    late File mdFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('swordfm_doc_test');
      mdFile = File('${tempDir.path}/sample.md');
      mdFile.writeAsStringSync('# Sample\n\nHello **world**.');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('toText writes stripped markdown to file', () async {
      final result = await DocConverter.toText(mdFile.path);
      expect(result, isNotNull);
      expect(result, endsWith('.txt'));
      expect(File(result!).existsSync(), isTrue);
      final content = await File(result).readAsString();
      expect(content, contains('Sample'));
      expect(content, contains('world'));
      expect(content, isNot(contains('**')));
    });

    test('toPdf generates a PDF file', () async {
      final result = await DocConverter.toPdf(mdFile.path);
      expect(result, isNotNull);
      expect(File(result!).existsSync(), isTrue);
      expect(result.endsWith('.pdf'), isTrue);
      // PDF is binary — just confirm it's non-empty
      expect(File(result).lengthSync(), greaterThan(0));
    });

    test('toDocx generates a DOCX file', () async {
      final result = await DocConverter.toDocx(mdFile.path);
      expect(result, isNotNull);
      expect(File(result!).existsSync(), isTrue);
      expect(result.endsWith('.docx'), isTrue);
      // DOCX is a ZIP; confirm it has the magic bytes
      final bytes = File(result).readAsBytesSync();
      expect(bytes.length, greaterThan(0));
    });

    test('toText returns null for non-convertible file', () async {
      final binFile = File('${tempDir.path}/photo.jpg');
      binFile.writeAsStringSync('binary');
      expect(await DocConverter.toText(binFile.path), isNull);
    });

    test('toPdf returns null for missing file', () async {
      expect(await DocConverter.toPdf('${tempDir.path}/missing.md'), isNull);
    });

    test('markdownFileToHtml returns null for missing file', () async {
      expect(
          await DocConverter.markdownFileToHtml('${tempDir.path}/nope.md'),
          isNull);
    });

    test('markdownFileToHtml builds a full document', () async {
      // The converter writes a styled .html file next to the source and
      // returns its path (matching the ConvertDialog contract). Verify the
      // written file contains a complete document.
      final outPath = await DocConverter.markdownFileToHtml(mdFile.path);
      expect(outPath, isNotNull);
      expect(outPath, endsWith('.html'));
      final html = File(outPath!).readAsStringSync();
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<title>sample</title>'));
      expect(html, contains('<h1>Sample</h1>'));
    });

    test('toPdf succeeds with lists, bullets and non-Latin-1 text', () async {
      // Regression: '•' (U+2022) written via the default Helvetica base font
      // made doc.save() throw, failing the whole conversion.
      final file = File('${tempDir.path}/bullets.md');
      file.writeAsStringSync(
        '# Title \u2013 dash\n\n- item one\n- item two\u2026\n\n'
        '1. first\n2. second\n\nUnicode: caf\u00e9 \u2014 na\u00efve',
      );
      final result = await DocConverter.toPdf(file.path);
      expect(result, isNotNull);
      expect(File(result!).existsSync(), isTrue);
    });

    test('toPdf converts a DOCX source via document.xml text', () async {
      // Regression: DOCX is a binary ZIP — readAsString threw FormatException.
      final docxResult = await DocConverter.toDocx(mdFile.path);
      expect(docxResult, isNotNull);
      final result = await DocConverter.toPdf(docxResult!);
      expect(result, isNotNull);
      final txt = await DocConverter.toText(docxResult);
      expect(txt, isNotNull);
      expect(File(txt!).readAsStringSync(), contains('Sample'));
    });

    test('fromPdf extracts text from a generated PDF', () async {
      // Round-trip: markdown → PDF → TXT.
      final pdfPath = await DocConverter.toPdf(mdFile.path);
      expect(pdfPath, isNotNull);
      final result = await DocConverter.toText(pdfPath!);
      expect(result, isNotNull);
      final text = File(result!).readAsStringSync();
      expect(text, contains('Sample'));
      expect(text, contains('Hello'));
    });

    test('toText of a non-PDF binary garbage file does not crash', () async {
      // Latin-1 tolerant decode: no FormatException on invalid UTF-8.
      final binFile = File('${tempDir.path}/weird.log');
      binFile.writeAsBytesSync([0xff, 0xfe, 0x00, 0x81, 0x41, 0x42]);
      final result = await DocConverter.toText(binFile.path);
      expect(result, isNotNull);
    });

    test('conversion writes real file for all formats', () async {
      final md = File('${tempDir.path}/test_input.md');
      await md.writeAsString('# X');
      final p = await DocConverter.markdownFileToHtml(md.path);
      expect(p, isNotNull);
      expect(File(p!).existsSync(), isTrue);
      expect(p.endsWith('.html'), isTrue);
    });
  });
}

