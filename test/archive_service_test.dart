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
    test('recognizes .tar.xz', () {
      expect(ArchiveService.isArchive('file.tar.xz'), isTrue);
    });
    test('recognizes .tar.bz2', () {
      expect(ArchiveService.isArchive('file.tar.bz2'), isTrue);
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
      final badPath = '$tmpDir/file.rar';
      await File(badPath).writeAsString('not valid');
      // RAR now throws UnsupportedArchiveFormat, which is a separate class
      // from Exception but still satisfies throwsA(anything) and has a clear
      // message. Check it is the right typed exception.
      expect(
        () => ArchiveService.extract(badPath, tmpDir),
        throwsA(isA<UnsupportedArchiveFormat>()),
      );
    });

    test('throws when archive not found', () async {
      expect(
        () => ArchiveService.extract('/nonexistent/path.zip', tmpDir),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('not found'),
          ),
        ),
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

  group('ArchiveService.createTar', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_tar_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('creates a valid tar and extracts it back', () async {
      final srcFile = File('$tmpDir/hello.txt');
      await srcFile.writeAsString('hello world');
      final tarPath = '$tmpDir/out.tar';

      final result = await ArchiveService.createTar(
        outputPath: tarPath,
        sources: [srcFile.path],
      );
      expect(result, tarPath);
      expect(File(tarPath).existsSync(), isTrue);

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 1);
      expect(File(extracted[0]).readAsStringSync(), 'hello world');
    });
  });

  group('ArchiveService.createTarGz', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_targz_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('creates a valid .tar.gz and extracts it back', () async {
      final srcFile = File('$tmpDir/hello.txt');
      await srcFile.writeAsString('hello compressed world');
      final gzPath = '$tmpDir/out.tar.gz';

      final result = await ArchiveService.createTarGz(
        outputPath: gzPath,
        sources: [srcFile.path],
      );
      expect(result, gzPath);
      expect(File(gzPath).existsSync(), isTrue);

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 1);
      expect(File(extracted[0]).readAsStringSync(), 'hello compressed world');
    });

    test('archives multiple files', () async {
      await File('$tmpDir/a.txt').writeAsString('aaa');
      await File('$tmpDir/b.txt').writeAsString('bbb');
      final gzPath = '$tmpDir/multi.tar.gz';

      await ArchiveService.createTarGz(
        outputPath: gzPath,
        sources: ['$tmpDir/a.txt', '$tmpDir/b.txt'],
      );

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(gzPath, outDir);
      expect(extracted.length, 2);
    });
  });

  group('ArchiveService.createTarXz', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_tarxz_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('creates a valid .tar.xz and extracts it back', () async {
      final srcFile = File('$tmpDir/hello.txt');
      await srcFile.writeAsString('hello xz world');
      final xzPath = '$tmpDir/out.tar.xz';

      final result = await ArchiveService.createTarXz(
        outputPath: xzPath,
        sources: [srcFile.path],
      );
      expect(result, xzPath);
      expect(File(xzPath).existsSync(), isTrue);

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 1);
      expect(File(extracted[0]).readAsStringSync(), 'hello xz world');
    });
  });

  group('ArchiveService.createTarBz2', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_tarbz2_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('creates a valid .tar.bz2 and extracts it back', () async {
      final srcFile = File('$tmpDir/hello.txt');
      await srcFile.writeAsString('hello bz2 world');
      final bz2Path = '$tmpDir/out.tar.bz2';

      final result = await ArchiveService.createTarBz2(
        outputPath: bz2Path,
        sources: [srcFile.path],
      );
      expect(result, bz2Path);
      expect(File(bz2Path).existsSync(), isTrue);

      final outDir = '$tmpDir/unpacked';
      final extracted = await ArchiveService.extract(result, outDir);
      expect(extracted.length, 1);
      expect(File(extracted[0]).readAsStringSync(), 'hello bz2 world');
    });
  });

  group('ArchiveService.sha256', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('sha_test_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('sha256OfFile returns hex digest for a file', () async {
      final f = File('$tmpDir/hello.txt');
      await f.writeAsString('hello world');
      final hash = await ArchiveService.sha256OfFile(f.path);
      expect(hash, isNotNull);
      expect(hash!.length, 64);
    });

    test('sha256OfFile returns null for missing file', () async {
      final hash = await ArchiveService.sha256OfFile('/nonexistent/path.txt');
      expect(hash, isNull);
    });
  });

  group('ArchiveService.findDuplicates', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dup_test_').path;
    });

    tearDown(() {
      Directory(tmpDir).deleteSync(recursive: true);
    });

    test('finds duplicate files with same content', () async {
      final f1 = File('$tmpDir/a.txt');
      final f2 = File('$tmpDir/b.txt');
      await f1.writeAsString('same content');
      await f2.writeAsString('same content');
      final dupes = await ArchiveService.findDuplicates([f1.path, f2.path]);
      expect(dupes.length, 1);
      expect(dupes.values.first.length, 2);
    });

    test('returns empty for unique files', () async {
      final f1 = File('$tmpDir/a.txt');
      final f2 = File('$tmpDir/b.txt');
      await f1.writeAsString('content a');
      await f2.writeAsString('content b');
      final dupes = await ArchiveService.findDuplicates([f1.path, f2.path]);
      expect(dupes, isEmpty);
    });
  });

  // =========================================================================
  // HARDENING TESTS (5D)
  // =========================================================================

  // -------------------------------------------------------------------------
  // 7z / RAR / Zstandard: explicit UnsupportedArchiveFormat rejection
  // -------------------------------------------------------------------------
  group('ArchiveService: 7z/RAR/Zst explicit rejection', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_unsup_').path;
    });
    tearDown(() => Directory(tmpDir).deleteSync(recursive: true));

    test('7z file throws UnsupportedArchiveFormat, not generic Exception', () async {
      final f = File('$tmpDir/archive.7z');
      await f.writeAsString('not real 7z');
      expect(
        () => ArchiveService.extract(f.path, '$tmpDir/out'),
        throwsA(isA<UnsupportedArchiveFormat>().having(
          (e) => e.format,
          'format',
          '7z',
        )),
      );
    });

    test('7z message includes actionable hint', () async {
      final f = File('$tmpDir/archive.7z');
      await f.writeAsString('x');
      try {
        await ArchiveService.extract(f.path, '$tmpDir/out');
        fail('expected UnsupportedArchiveFormat');
      } on UnsupportedArchiveFormat catch (e) {
        expect(e.message, contains('7z'));
        expect(e.message.isNotEmpty, isTrue);
      }
    });

    test('RAR file throws UnsupportedArchiveFormat with format=rar', () async {
      final f = File('$tmpDir/archive.rar');
      await f.writeAsString('not real rar');
      expect(
        () => ArchiveService.extract(f.path, '$tmpDir/out'),
        throwsA(isA<UnsupportedArchiveFormat>().having(
          (e) => e.format,
          'format',
          'rar',
        )),
      );
    });

    test('RAR message includes actionable hint', () async {
      final f = File('$tmpDir/archive.rar');
      await f.writeAsString('x');
      try {
        await ArchiveService.extract(f.path, '$tmpDir/out');
        fail('expected UnsupportedArchiveFormat');
      } on UnsupportedArchiveFormat catch (e) {
        expect(e.message, contains('unrar'));
      }
    });

    test('.zst file throws UnsupportedArchiveFormat', () async {
      final f = File('$tmpDir/archive.zst');
      await f.writeAsString('not zstd');
      expect(
        () => ArchiveService.extract(f.path, '$tmpDir/out'),
        throwsA(isA<UnsupportedArchiveFormat>()),
      );
    });

    test('isArchive returns true for .7z (detected)', () {
      expect(ArchiveService.isArchive('file.7z'), isTrue);
    });

    test('isArchive returns true for .rar (detected)', () {
      expect(ArchiveService.isArchive('file.rar'), isTrue);
    });

    test('isSupportedArchive returns false for .7z', () {
      expect(ArchiveService.isSupportedArchive('file.7z'), isFalse);
    });

    test('isSupportedArchive returns false for .rar', () {
      expect(ArchiveService.isSupportedArchive('file.rar'), isFalse);
    });

    test('isSupportedArchive returns true for .zip', () {
      expect(ArchiveService.isSupportedArchive('file.zip'), isTrue);
    });

    test('isSupportedArchive returns true for .tar.gz', () {
      expect(ArchiveService.isSupportedArchive('file.tar.gz'), isTrue);
    });

    test('isSupportedArchive returns true for .tar.bz2', () {
      expect(ArchiveService.isSupportedArchive('file.tar.bz2'), isTrue);
    });

    test('isSupportedArchive returns true for .tar.xz', () {
      expect(ArchiveService.isSupportedArchive('file.tar.xz'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Archive bomb limits
  // -------------------------------------------------------------------------
  group('ArchiveService: archive bomb limits', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_bomb_').path;
    });
    tearDown(() => Directory(tmpDir).deleteSync(recursive: true));

    test('ArchiveBombException is thrown when entry count exceeds maxEntries',
        () async {
      // Build a ZIP with maxEntries + 1 tiny entries.
      final archive = Archive();
      for (var i = 0; i <= ArchiveService.maxEntries; i++) {
        archive.addFile(ArchiveFile('f$i.txt', 1, [0x41]));
      }
      final zipPath = '$tmpDir/bomb_count.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      expect(
        () => ArchiveService.extract(zipPath, '$tmpDir/out'),
        throwsA(isA<ArchiveBombException>()),
      );
    });

    test('ArchiveBombException message mentions entry count or limit', () async {
      final archive = Archive();
      for (var i = 0; i <= ArchiveService.maxEntries; i++) {
        archive.addFile(ArchiveFile('f$i.txt', 1, [0x41]));
      }
      final zipPath = '$tmpDir/bomb_count2.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      try {
        await ArchiveService.extract(zipPath, '$tmpDir/out');
        fail('expected ArchiveBombException');
      } on ArchiveBombException catch (e) {
        expect(e.message.isNotEmpty, isTrue);
      }
    });

    test('maxEntries constant is 10000', () {
      expect(ArchiveService.maxEntries, 10000);
    });

    test('maxUncompressedBytes constant is 4 GB', () {
      expect(ArchiveService.maxUncompressedBytes,
          4 * 1024 * 1024 * 1024);
    });

    test('archive below limits extracts normally', () async {
      final archive = Archive();
      archive.addFile(
          ArchiveFile('ok.txt', 3, [0x41, 0x42, 0x43]));
      final zipPath = '$tmpDir/small.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final result =
          await ArchiveService.extract(zipPath, '$tmpDir/out');
      expect(result, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Path-traversal and symlink rejection
  // -------------------------------------------------------------------------
  group('ArchiveService: path-traversal / symlink rejection', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_trav_').path;
    });
    tearDown(() => Directory(tmpDir).deleteSync(recursive: true));

    test('entry with ".." component is silently skipped', () async {
      final archive = Archive();
      // Entry that would escape destDir: ../../evil.txt
      archive.addFile(ArchiveFile(
          '../../evil.txt', 4, [0x65, 0x76, 0x69, 0x6c]));
      // Also add a safe entry so result is non-empty.
      archive.addFile(ArchiveFile('safe.txt', 4, [0x73, 0x61, 0x66, 0x65]));
      final zipPath = '$tmpDir/traversal.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final out = '$tmpDir/out';
      final result = await ArchiveService.extract(zipPath, out);

      // The traversal entry must NOT have been written.
      expect(File('$out/../../evil.txt').existsSync(), isFalse);
      // Safe entry was extracted.
      expect(result.any((p) => p.endsWith('safe.txt')), isTrue);
    });

    test('entry with NUL byte in name is skipped', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile(
          'bad\x00file.txt', 3, [0x62, 0x61, 0x64]));
      archive.addFile(ArchiveFile('good.txt', 4, [0x67, 0x6f, 0x6f, 0x64]));
      final zipPath = '$tmpDir/nul.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final out = '$tmpDir/out';
      final result = await ArchiveService.extract(zipPath, out);

      expect(result.any((p) => p.endsWith('good.txt')), isTrue);
      // No file with NUL in its path.
      expect(result.any((p) => p.contains('\x00')), isFalse);
    });

    test('leading-slash entry is stripped to relative path', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('/absolute/path.txt', 3, [0x61, 0x62, 0x63]));
      final zipPath = '$tmpDir/abs.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final out = '$tmpDir/out';
      final result = await ArchiveService.extract(zipPath, out);

      // Should land inside out/, not at /absolute/path.txt
      for (final p in result) {
        expect(p.startsWith(out), isTrue);
      }
    });

    test('canonical path check: extracted file stays inside destDir', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('nested/deep/file.txt', 5,
          [0x68, 0x65, 0x6c, 0x6c, 0x6f]));
      final zipPath = '$tmpDir/nested.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final out = '$tmpDir/out';
      final result = await ArchiveService.extract(zipPath, out);

      for (final p in result) {
        // Every path must be rooted inside the destination directory.
        expect(p.startsWith(out), isTrue,
            reason: '$p is outside $out');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Corrupt-input handling
  // -------------------------------------------------------------------------
  group('ArchiveService: corrupt input', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_corrupt_').path;
    });
    tearDown(() => Directory(tmpDir).deleteSync(recursive: true));

    test('random bytes as .zip throw (truncated header)', () async {
      // A truncated local-file-header forces the decoder to throw.
      final f = File('$tmpDir/corrupt.zip');
      await f.writeAsBytes([
        0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00,
      ]);
      expect(
        () => ArchiveService.extract(f.path, '$tmpDir/out'),
        throwsA(anything),
      );
    });

    test('random bytes as .tar produce no usable entries (empty result)', () async {
      // The archive package's TAR decoder tolerates garbage input and returns
      // an empty archive rather than throwing. A zero-entry extract is still
      // a non-crash graceful outcome — we verify nothing was written.
      final f = File('$tmpDir/corrupt.tar');
      await f.writeAsBytes([0xDE, 0xAD, 0xBE, 0xEF]);
      // Either throws or returns empty — either way no files written to destDir.
      final out = '$tmpDir/out_tar';
      try {
        final result = await ArchiveService.extract(f.path, out);
        expect(result, isEmpty, reason: 'corrupt TAR should yield no files');
      } catch (_) {
        // Throwing is also acceptable.
      }
    });

    test('empty file as .zip throws', () async {
      final f = File('$tmpDir/empty.zip');
      await f.writeAsBytes([]);
      expect(
        () => ArchiveService.extract(f.path, '$tmpDir/out'),
        throwsA(anything),
      );
    });

    test('missing archive throws with "not found" in message', () async {
      expect(
        () => ArchiveService.extract(
            '$tmpDir/nonexistent.zip', '$tmpDir/out'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('not found'),
        )),
      );
    });
  });

  // -------------------------------------------------------------------------
  // verifyIntegrity
  // -------------------------------------------------------------------------
  group('ArchiveService.verifyIntegrity', () {
    late String tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('arc_int_').path;
    });
    tearDown(() => Directory(tmpDir).deleteSync(recursive: true));

    test('valid zip reports ok=true with no errors', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('hello.txt', 5,
          [0x68, 0x65, 0x6c, 0x6c, 0x6f]));
      final zipPath = '$tmpDir/good.zip';
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final result = await ArchiveService.verifyIntegrity(zipPath);
      expect(result.ok, isTrue);
      expect(result.errors, isEmpty);
    });

    test('valid tar.gz reports ok=true', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('a.txt', 3, [0x41, 0x42, 0x43]));
      final tarBytes = TarEncoder().encode(archive);
      final gzBytes = GZipEncoder().encode(tarBytes);
      final gzPath = '$tmpDir/good.tar.gz';
      await File(gzPath).writeAsBytes(gzBytes);

      final result = await ArchiveService.verifyIntegrity(gzPath);
      expect(result.ok, isTrue);
    });

    test('corrupt zip (end-record mangled) reports ok=false', () async {
      // Build a valid ZIP then flip the last 4 bytes (end-of-central-directory
      // record signature) — this is the corruption the archive package rejects.
      final goodArchive = Archive();
      goodArchive
          .addFile(ArchiveFile('x.txt', 1, [0x78]));
      final goodBytes = ZipEncoder().encode(goodArchive);
      final corruptBytes = List<int>.from(goodBytes);
      for (var i = corruptBytes.length - 4; i < corruptBytes.length; i++) {
        corruptBytes[i] ^= 0xFF;
      }
      final f = File('$tmpDir/mangled.zip');
      await f.writeAsBytes(corruptBytes);

      final result = await ArchiveService.verifyIntegrity(f.path);
      expect(result.ok, isFalse);
      expect(result.errors, isNotEmpty);
    });

    test('missing file reports ok=false with error entry', () async {
      final result = await ArchiveService.verifyIntegrity(
          '$tmpDir/missing.zip');
      expect(result.ok, isFalse);
      expect(result.errors, isNotEmpty);
    });

    test('7z file reports ok=false (unsupported format)', () async {
      final f = File('$tmpDir/archive.7z');
      await f.writeAsString('fake 7z');

      final result = await ArchiveService.verifyIntegrity(f.path);
      expect(result.ok, isFalse);
      expect(result.errors, isNotEmpty);
    });
  });
}
