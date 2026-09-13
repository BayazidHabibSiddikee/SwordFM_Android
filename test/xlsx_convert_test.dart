import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/doc_converter.dart';

/// Builds a minimal .xlsx ZIP in memory covering: shared strings, inline
/// strings, numbers, booleans, sparse columns (missing <c>), and two sheets.
List<int> buildTestXlsx() {
  const sharedStrings = '''<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
<si><t>Name</t></si><si><t>Age</t></si><si><t>Alice</t></si></sst>''';
  const sheet1 = '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1"><v>99</v></c></row>
<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>30</v></c></row>
<row r="3"><c r="A3" t="inlineStr"><is><t>Bob</t></is></c><c r="B3" t="b"><v>1</v></c></row>
</sheetData></worksheet>''';
  const sheet2 = '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1"><c r="A1"><v>1.5</v></c></row>
</sheetData></worksheet>''';
  const workbook = '''<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets>
<sheet name="People" sheetId="1"/><sheet name="Numbers" sheetId="2"/>
</sheets></workbook>''';
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        'xl/sharedStrings.xml',
        utf8.encode(sharedStrings),
      ),
    )
    ..addFile(
      ArchiveFile.bytes('xl/worksheets/sheet1.xml', utf8.encode(sheet1)),
    )
    ..addFile(
      ArchiveFile.bytes('xl/worksheets/sheet2.xml', utf8.encode(sheet2)),
    )
    ..addFile(
      ArchiveFile.bytes('xl/workbook.xml', utf8.encode(workbook)),
    );
  return ZipEncoder().encode(archive);
}

void main() {
  group('XLSX sheet parsing', () {
    test('shared strings resolve by index', () {
      final sheets = DocConverter.parseXlsxSheets(buildTestXlsx());
      expect(sheets['People']![0][0], 'Name');
      expect(sheets['People']![1][0], 'Alice');
    });

    test('sparse columns pad with empty strings', () {
      final sheets = DocConverter.parseXlsxSheets(buildTestXlsx());
      final header = sheets['People']![0];
      expect(header.length, 4); // A B (C missing) D
      expect(header[2], '');
      expect(header[3], '99');
    });

    test('inline strings, booleans, numbers', () {
      final sheets = DocConverter.parseXlsxSheets(buildTestXlsx());
      expect(sheets['People']![2][0], 'Bob');
      expect(sheets['People']![2][1], 'TRUE');
      expect(sheets['Numbers']![0][0], '1.5');
    });

    test('sheet names come from the workbook', () {
      final sheets = DocConverter.parseXlsxSheets(buildTestXlsx());
      expect(sheets.keys, containsAll(['People', 'Numbers']));
    });

    test('garbage input yields empty map, never throws', () {
      expect(DocConverter.parseXlsxSheets([1, 2, 3]), isEmpty);
      expect(DocConverter.parseXlsxSheets([]), isEmpty);
    });

    test('markdown renders one table per sheet', () {
      final md = DocConverter.xlsxSheetsToMarkdown(
        DocConverter.parseXlsxSheets(buildTestXlsx()),
      );
      expect(md, contains('## People'));
      expect(md, contains('| Name | Age |'));
      expect(md, contains('## Numbers'));
    });
  });

  group('XLSX conversion outputs', () {
    late Directory tmp;
    late String xlsxPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xlsx_conv_');
      xlsxPath = p.join(tmp.path, 'data.xlsx');
      File(xlsxPath).writeAsBytesSync(buildTestXlsx());
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('canConvert accepts xlsx', () {
      expect(DocConverter.canConvert(xlsxPath), isTrue);
      expect(DocConverter.getAvailableFormats(xlsxPath),
          containsAll(['PDF', 'TXT', 'Markdown']));
    });

    test('toMarkdown produces tables', () async {
      final out = await DocConverter.toMarkdown(xlsxPath);
      expect(out, endsWith('.md'));
      final md = File(out!).readAsStringSync();
      expect(md, contains('Alice'));
      expect(md, contains('|'));
    });

    test('toText produces tab-separated rows', () async {
      final out = await DocConverter.toText(xlsxPath);
      expect(out, endsWith('.txt'));
      final text = File(out!).readAsStringSync();
      expect(text, contains('Alice\t30'));
      expect(text, isNot(contains('|')));
    });

    test('toPdf renders without throwing', () async {
      final out = await DocConverter.toPdf(xlsxPath);
      expect(out, endsWith('.pdf'));
      expect(File(out!).lengthSync(), greaterThan(0));
    });

    test('toDocx renders without throwing', () async {
      final out = await DocConverter.toDocx(xlsxPath);
      expect(out, endsWith('.docx'));
      expect(File(out!).lengthSync(), greaterThan(0));
    });

    test('convertBatch converts sequentially with progress', () async {
      final second = p.join(tmp.path, 'data2.xlsx');
      File(xlsxPath).copySync(second);
      final progress = <List<int>>[];
      final results = await DocConverter.convertBatch(
        [xlsxPath, second, p.join(tmp.path, 'missing.xlsx')],
        'TXT',
        onProgress: (done, total) => progress.add([done, total]),
      );
      expect(results, hasLength(3));
      expect(results[0].ok, isTrue);
      expect(results[1].ok, isTrue);
      expect(results[2].ok, isFalse);
      expect(progress.last, [3, 3]);
    });
  });
}
