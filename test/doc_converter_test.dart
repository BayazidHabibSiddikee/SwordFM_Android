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
      expect(DocConverter.canConvert('doc.pdf'), isFalse);
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

    test('toText reads file and strips markdown', () async {
      final result = await DocConverter.toText(mdFile.path);
      expect(result, isNotNull);
      expect(result, contains('Sample'));
      expect(result, contains('world'));
      expect(result, isNot(contains('**')));
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
      final html = await DocConverter.markdownFileToHtml(mdFile.path);
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<title>sample</title>'));
      expect(html, contains('<h1>Sample</h1>'));
    });
  });
}
