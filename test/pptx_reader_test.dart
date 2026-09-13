import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/pptx_reader.dart';

List<int> buildTestPptx() {
  const slide1 = '''<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:sp><p:txBody><a:p><a:r><a:t>Quarterly Review</a:t></a:r></a:p>
<a:p><a:r><a:t>Revenue grew &amp; costs fell</a:t></a:r></a:p></p:txBody></p:sp></p:sld>''';
  const slide2 = '''<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:sp><p:txBody><a:p><a:r><a:t></a:t></a:r></a:p></p:txBody></p:sp></p:sld>''';
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('ppt/slides/slide1.xml', utf8.encode(slide1)),
    )
    ..addFile(
      ArchiveFile.bytes('ppt/slides/slide2.xml', utf8.encode(slide2)),
    );
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pptx_reader_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String writePptx(List<int> bytes, [String name = 'deck.pptx']) {
    final path = p.join(tmp.path, name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  test('parses titles and body lines in order', () {
    final outline = PptxReader.parse(writePptx(buildTestPptx()));
    expect(outline.slideCount, 2);
    expect(outline.slides[0].number, 1);
    expect(outline.slides[0].title, 'Quarterly Review');
    expect(outline.slides[0].lines, ['Revenue grew & costs fell']);
  });

  test('empty slides parse without lines', () {
    final outline = PptxReader.parse(writePptx(buildTestPptx()));
    expect(outline.slides[1].isEmpty, isTrue);
  });

  test('missing file throws a descriptive error', () {
    expect(
      () => PptxReader.parse(p.join(tmp.path, 'nope.pptx')),
      throwsA(isA<Exception>()),
    );
  });

  test('non-presentation zip throws (no slides)', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode('<w/>')));
    final path = writePptx(ZipEncoder().encode(archive), 'fake.pptx');
    expect(() => PptxReader.parse(path), throwsA(isA<Exception>()));
  });

  test('tryParse never throws', () {
    expect(
      PptxReader.tryParse(p.join(tmp.path, 'nope.pptx')).slides,
      isEmpty,
    );
  });
}
