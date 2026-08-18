import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/doc_converter.dart';

void main() {
  group('DocConverter', () {
    test('canConvert returns true for markdown files', () {
      expect(DocConverter.canConvert('document.md'), isTrue);
      expect(DocConverter.canConvert('notes.txt'), isTrue);
      expect(DocConverter.canConvert('index.html'), isTrue);
    });

    test('canConvert returns false for binary files', () {
      expect(DocConverter.canConvert('photo.jpg'), isFalse);
      expect(DocConverter.canConvert('archive.zip'), isFalse);
      expect(DocConverter.canConvert('video.mp4'), isFalse);
    });

    test('getAvailableFormats returns formats for convertible files', () {
      final formats = DocConverter.getAvailableFormats('readme.md');
      expect(formats, containsAll(['PDF', 'DOCX', 'HTML']));
    });

    test('getAvailableFormats returns empty list for non-convertible files', () {
      expect(DocConverter.getAvailableFormats('image.png'), isEmpty);
    });

    test('markdownToHtml converts headers', () async {
      const md = '# Hello\n\n## World';
      final html = await DocConverter.markdownToHtml(md);
      expect(html.contains('<h1>Hello</h1>'), isTrue);
      expect(html.contains('<h2>World</h2>'), isTrue);
    });

    test('markdownToHtml converts bold and italic', () async {
      const md = '**bold text** and *italic text*';
      final html = await DocConverter.markdownToHtml(md);
      expect(html.contains('<strong>bold text</strong>'), isTrue);
      expect(html.contains('<em>italic text</em>'), isTrue);
    });

    test('markdownToHtml converts inline code', () async {
      const md = 'Use `dart:io` for file operations';
      final html = await DocConverter.markdownToHtml(md);
      expect(html.contains('<code>dart:io</code>'), isTrue);
    });
  });
}
