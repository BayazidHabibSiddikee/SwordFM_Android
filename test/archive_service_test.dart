import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/archive_service.dart';

void main() {
  group('ArchiveService.isArchive', () {
    test('recognizes .zip', () {
      expect(ArchiveService.isArchive('file.zip'), isTrue);
    });
    test('recognizes .tar.gz', () {
      expect(ArchiveService.isArchive('file.tar.gz'), isTrue);
    });
    test('rejects .pdf', () {
      expect(ArchiveService.isArchive('file.pdf'), isFalse);
    });
    test('is case-insensitive', () {
      expect(ArchiveService.isArchive('FILE.ZIP'), isTrue);
    });
  });

  group('ArchiveService.extract', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_test_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('extracts a zip archive', () async {
      final zipPath = '$tmpDir/test.zip';
      
      final archive = Archive();
      archive.addFile(ArchiveFile('src.txt', 13, utf8.encode('hello archive')));
      final bytes = ZipEncoder().encode(archive);
      await File(zipPath).writeAsBytes(bytes);

      final destDir = '$tmpDir/out';
      final result = await ArchiveService.extract(zipPath, destDir);
      expect(result.length, 1);
      expect(File(result[0]).readAsStringSync(), 'hello archive');
    });

    test('rejects unsupported format', () async {
      final badPath = '$tmpDir/file.bz2';
      await File(badPath).writeAsString('not valid');
      expect(
        () => ArchiveService.extract(badPath, tmpDir),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('unsupported'))),
      );
    });

    test('throws when archive not found', () async {
      expect(
        () => ArchiveService.extract('/nonexistent/path.zip', tmpDir),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('not found'))),
      );
    });
  });

  group('ArchiveService.createZip', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_create_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('creates a valid zip from a single file', () async {
      final srcFile = File('$tmpDir/hello.txt');
      await srcFile.writeAsString('hello world');
      final zipPath = '$tmpDir/out.zip';

      final result = await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [srcFile.path],
      );
      expect(result, zipPath);
      expect(File(result).existsSync(), isTrue);

      // Verify we can extract it back
      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 1);
      expect(File(extracted[0]).readAsStringSync(), 'hello world');
    });

    test('creates a valid zip from multiple files', () async {
      await File('$tmpDir/a.txt').writeAsString('aaa');
      await File('$tmpDir/b.txt').writeAsString('bbb');
      final zipPath = '$tmpDir/multi.zip';

      final result = await ArchiveService.createZip(
        outputPath: zipPath,
        sources: ['$tmpDir/a.txt', '$tmpDir/b.txt'],
      );
      expect(result, zipPath);

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 2);
    });
  });
}
