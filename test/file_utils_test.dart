import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/utils/file_utils.dart';

void main() {
  group('FileUtils', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('swordfm_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('listDirectory returns empty list for non-existent path', () async {
      final items = await FileUtils.listDirectory('/nonexistent/path/that/does/not/exist');
      expect(items, isEmpty);
    });

    test('listDirectory returns items in a valid directory', () async {
      await File('${tempDir.path}/test.txt').create();
      await Directory('${tempDir.path}/subdir').create();

      final items = await FileUtils.listDirectory(tempDir.path);
      expect(items.length, 2);
      expect(items.any((i) => i.name == 'test.txt'), isTrue);
      expect(items.any((i) => i.isDirectory && i.name == 'subdir'), isTrue);
    });

    test('listDirectory excludes hidden files by default', () async {
      await File('${tempDir.path}/.hidden').create();
      await File('${tempDir.path}/visible.txt').create();

      final items = await FileUtils.listDirectory(tempDir.path);
      expect(items.any((i) => i.name == '.hidden'), isFalse);
      expect(items.any((i) => i.name == 'visible.txt'), isTrue);
    });

    test('listDirectory includes hidden files when requested', () async {
      await File('${tempDir.path}/.hidden').create();
      await File('${tempDir.path}/visible.txt').create();

      final items = await FileUtils.listDirectory(tempDir.path, includeHidden: true);
      expect(items.any((i) => i.name == '.hidden'), isTrue);
    });

    test('copy file works correctly', () async {
      final src = File('${tempDir.path}/source.txt');
      await src.writeAsString('hello swordfm');
      final dest = File('${tempDir.path}/dest.txt');

      await FileUtils.copy(src.path, dest.path);
      expect(await dest.exists(), isTrue);
      expect(await dest.readAsString(), equals('hello swordfm'));
    });

    test('move file works correctly', () async {
      final src = File('${tempDir.path}/old.txt');
      await src.writeAsString('moving');
      final dest = File('${tempDir.path}/new.txt');

      await FileUtils.move(src.path, dest.path);
      expect(await src.exists(), isFalse);
      expect(await dest.exists(), isTrue);
      expect(await dest.readAsString(), equals('moving'));
    });

    test('rename works correctly', () async {
      final file = File('${tempDir.path}/old_name.txt');
      await file.writeAsString('content');

      await FileUtils.rename(file.path, 'renamed.txt');
      final renamed = File('${tempDir.path}/renamed.txt');
      expect(await renamed.exists(), isTrue);
      expect(await renamed.readAsString(), equals('content'));
    });

    test('delete removes file from disk', () async {
      final file = File('${tempDir.path}/to_delete.txt');
      await file.writeAsString('bye');
      expect(await file.exists(), isTrue);

      await FileUtils.delete(file.path);
      expect(await file.exists(), isFalse);
    });

    test('clipboard copy and paste works', () async {
      final src = File('${tempDir.path}/clip.txt');
      await src.writeAsString('clipboard content');
      final destDir = '${tempDir.path}/dest';
      await Directory(destDir).create();

      FileUtils.setClipboard(src.path, 'copy');
      await FileUtils.paste(destDir);
      expect(await File('$destDir/clip.txt').exists(), isTrue);
      FileUtils.clearClipboard();
    });

    test('clipboard cut and paste moves the file', () async {
      final src = File('${tempDir.path}/cut_file.txt');
      await src.writeAsString('move me');
      final destDir = '${tempDir.path}/cut_dest';
      await Directory(destDir).create();

      FileUtils.setClipboard(src.path, 'cut');
      await FileUtils.paste(destDir);
      expect(await src.exists(), isFalse);
      expect(await File('$destDir/cut_file.txt').exists(), isTrue);
      FileUtils.clearClipboard();
    });

    test('createDirectory creates nested directories', () async {
      final path = '${tempDir.path}/a/b/c';
      await FileUtils.createDirectory(path);
      expect(await Directory(path).exists(), isTrue);
    });
  });

  group('FileUtils Clipboard', () {
    test('clearClipboard clears state', () async {
      FileUtils.setClipboard('/some/path', 'copy');
      FileUtils.clearClipboard();
      // Clearing should prevent subsequent paste from doing anything
      final destDir = '${Directory.systemTemp.path}/clear_test';
      await Directory(destDir).create();
      await FileUtils.paste(destDir);
      // No file should be copied since clipboard was cleared
      expect(await Directory(destDir).list().length, 0);
      await Directory(destDir).delete();
    });
  });
}
