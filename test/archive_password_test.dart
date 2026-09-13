import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:swordfm/services/archive_service.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zipcrypt_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File seed(String name, String content) {
    final f = File(p.join(tmp.path, name));
    f.writeAsStringSync(content);
    return f;
  }

  group('interop with external zip tools', () {
    test('our AES zip is decryptable by an independent implementation', () async {
      // Guards against the failure mode where our own round-trip passes but the
      // output is unreadable by WinZip / 7-Zip / Android extractors.
      // NOTE: Info-ZIP `unzip` (6.00) cannot read AES (method 99) at all, so
      // libarchive's bsdtar is used: it implements AES and is a genuinely
      // independent implementation of the same format.
      final src = seed('interop.txt', 'external tool must read this\n');
      final zipPath = p.join(tmp.path, 'interop.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'realtest',
      );

      final outDir = Directory(p.join(tmp.path, 'bsdout'))..createSync();
      final res = Process.runSync(
        'bsdtar',
        ['-xvf', zipPath, '--passphrase', 'realtest'],
        workingDirectory: outDir.path,
      );
      expect(
        res.exitCode,
        0,
        reason: 'independent extractor rejected our AES output.\n'
            'stderr: ${res.stderr}\nstdout: ${res.stdout}',
      );
      expect(
        File(p.join(outDir.path, 'interop.txt')).readAsStringSync(),
        'external tool must read this\n',
      );
    });

    test('an external AES zip written by another tool is readable by us',
        () async {
      // The reverse direction: a password zip produced by pyzipper must open in
      // our extractor, proving we do not only round-trip with ourselves.
      final fixture = Directory('/tmp/extzip');
      final external = File(p.join(fixture.path, 'extaes.zip'));
      if (!external.existsSync()) {
        markTestSkipped('external AES fixture not present');
        return;
      }

      final out = await ArchiveService.extract(
        external.path,
        p.join(tmp.path, 'in'),
        password: 'testpass',
      );
      expect(out, hasLength(1));
      expect(File(out.first).readAsStringSync(), 'external aes secret\n');
    });

    test('our AES zip is NOT readable by unzip without the password', () async {
      final src = seed('interop.txt', 'must stay locked\n');
      final zipPath = p.join(tmp.path, 'locked_interop.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'realtest',
      );

      // Wrong password must not yield plaintext via an independent extractor.
      final outDir = Directory(p.join(tmp.path, 'bad'))..createSync();
      Process.runSync(
        'bsdtar',
        ['-xvf', zipPath, '--passphrase', 'wrongpass'],
        workingDirectory: outDir.path,
      );
      final leaked = File(p.join(outDir.path, 'interop.txt'));
      expect(leaked.existsSync() && leaked.readAsStringSync().contains('must stay locked'),
          isFalse,
          reason: 'a wrong password must never yield plaintext');
    });
  });

  group('password-protected ZIP', () {
    test('create with password, extract with correct password', () async {
      final src = seed('secret.txt', 'top secret payload\n');
      final zipPath = p.join(tmp.path, 'locked.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'hunter2',
      );

      final zipBytes = File(zipPath).readAsBytesSync();
      expect(zipBytes, isNotEmpty);

      final outDir = p.join(tmp.path, 'out');
      final extracted = await ArchiveService.extract(
        zipPath,
        outDir,
        password: 'hunter2',
      );

      expect(extracted, hasLength(1));
      expect(File(extracted.first).readAsStringSync(), 'top secret payload\n');
    });

    test('extract without a password raises ArchivePasswordRequiredException',
        () async {
      final src = seed('secret.txt', 'payload\n');
      final zipPath = p.join(tmp.path, 'locked.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'hunter2',
      );

      await expectLater(
        ArchiveService.extract(zipPath, p.join(tmp.path, 'out')),
        throwsA(
          isA<ArchivePasswordRequiredException>()
              .having((e) => e.passwordWasSupplied, 'passwordWasSupplied', false),
        ),
      );
    });

    test('listArchiveContents prompts path: locked listing needs password',
        () async {
      final src = seed('secret.txt', 'payload\n');
      final zipPath = p.join(tmp.path, 'locked.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'hunter2',
      );

      // No password → typed error (the browser screen turns this into a
      // password prompt instead of a raw error).
      await expectLater(
        ArchiveService.listArchiveContents(zipPath),
        throwsA(
          isA<ArchivePasswordRequiredException>()
              .having((e) => e.passwordWasSupplied, 'passwordWasSupplied', false),
        ),
      );

      // Correct password → entries visible.
      final entries = await ArchiveService.listArchiveContents(
        zipPath,
        password: 'hunter2',
      );
      expect(entries.map((e) => e.name), contains('secret.txt'));
    });

    test('extract with the WRONG password reports it was supplied', () async {
      final src = seed('secret.txt', 'payload\n');
      final zipPath = p.join(tmp.path, 'locked.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'correct-horse',
      );

      await expectLater(
        ArchiveService.extract(
          zipPath,
          p.join(tmp.path, 'out'),
          password: 'wrong-battery',
        ),
        throwsA(
          isA<ArchivePasswordRequiredException>()
              .having((e) => e.passwordWasSupplied, 'passwordWasSupplied', true),
        ),
      );
    });

    test('an empty password produces an UNENCRYPTED, readable zip', () async {
      final src = seed('plain.txt', 'not secret\n');
      final zipPath = p.join(tmp.path, 'plain.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: '',
      );

      // Must open with no password at all — a blank field should not lock it.
      final archive = ZipDecoder().decodeBytes(
        File(zipPath).readAsBytesSync(),
      );
      expect(archive.files.map((f) => f.name), contains('plain.txt'));
    });

    test('AES-256 entries survive a full create -> extract round trip at size',
        () async {
      // Exercise the streaming/AES path with content larger than one AES block
      // to be sure multi-block decryption is correct, not just the first block.
      final big = List.generate(4096, (i) => 'line $i of payload').join('\n');
      final src = seed('big.txt', big);
      final zipPath = p.join(tmp.path, 'big.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
        password: 'pw',
      );

      final out = await ArchiveService.extract(
        zipPath,
        p.join(tmp.path, 'out'),
        password: 'pw',
      );
      expect(File(out.first).readAsStringSync(), big);
    });
  });

  group('extractEntry traversal guard', () {
    test('rejects ".." entry names', () async {
      final src = seed('ok.txt', 'x\n');
      final zipPath = p.join(tmp.path, 'a.zip');
      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [src.path],
      );

      await expectLater(
        ArchiveService.extractEntry(zipPath, '../escape.txt', tmp.path),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects an embedded traversal component', () async {
      final src = seed('ok.txt', 'x\n');
      final zipPath = p.join(tmp.path, 'b.zip');
      await ArchiveService.createZip(outputPath: zipPath, sources: [src.path]);

      await expectLater(
        ArchiveService.extractEntry(zipPath, 'a/../../escape.txt', tmp.path),
        throwsA(isA<Exception>()),
      );
    });

    test('extracts a legitimate nested entry successfully', () async {
      // Build a zip containing a nested path, then pull that one entry out.
      final nested = Directory(p.join(tmp.path, 'src', 'sub'))
        ..createSync(recursive: true);
      File(p.join(nested.path, 'deep.txt')).writeAsStringSync('nested content\n');
      final zipPath = p.join(tmp.path, 'nested.zip');

      await ArchiveService.createZip(
        outputPath: zipPath,
        sources: [File(p.join(tmp.path, 'src')).path],
      );

      // Discover the real stored entry name rather than assuming the layout,
      // so this test validates extraction rather than guessing the convention.
      final stored = ZipDecoder()
          .decodeBytes(File(zipPath).readAsBytesSync())
          .files
          .map((f) => f.name)
          .toList();
      final nestedName =
          stored.firstWhere((n) => n.endsWith('deep.txt'));
      expect(nestedName, isNotEmpty);

      final destDir = p.join(tmp.path, 'pulled');
      final out = await ArchiveService.extractEntry(
        zipPath,
        nestedName,
        destDir,
      );
      expect(File(out).readAsStringSync(), 'nested content\n');
      expect(p.isWithin(destDir, out), isTrue,
          reason: 'extracted path must stay inside the destination directory');
    });
  });
}
