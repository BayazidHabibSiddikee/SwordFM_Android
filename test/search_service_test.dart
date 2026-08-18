import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/search_service.dart';

void main() {
  group('SearchService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('search_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('finds matching files by name (case-insensitive)', () async {
      await File('${tempDir.path}/notes.txt').create();
      await File('${tempDir.path}/README.md').create();
      await File('${tempDir.path}/other.doc').create();

      final results = await SearchService.searchDirectory(tempDir.path, 'note');
      expect(results.length, 1);
      expect(results.first.name, 'notes.txt');
    });

    test('hidden files are excluded by default', () async {
      await File('${tempDir.path}/visible.txt').create();
      await File('${tempDir.path}/.hidden.txt').create();

      final results = await SearchService.searchDirectory(tempDir.path, 'hidden');
      expect(results.any((r) => r.isHidden), isFalse);
    });

    test('includes hidden files when requested', () async {
      await File('${tempDir.path}/.secret.md').create();

      final results = await SearchService.searchDirectory(
        tempDir.path, 'secret', includeHidden: true,
      );
      expect(results.length, 1);
      expect(results.first.isHidden, isTrue);
    });

    test('respects limit parameter', () async {
      for (var i = 0; i < 10; i++) {
        await File('${tempDir.path}/file_$i.txt').create();
      }
      final results = await SearchService.searchDirectory(tempDir.path, 'file', limit: 5);
      expect(results.length, lessThanOrEqualTo(5));
    });

    test('returns empty list for non-existent root', () async {
      final results = await SearchService.searchDirectory('/nonexistent/path', 'anything');
      expect(results, isEmpty);
    });

    test('recursive search finds nested files', () async {
      final subdir = await Directory('${tempDir.path}/subdir').create();
      await File('${subdir.path}/nested.pdf').create();

      final results = await SearchService.searchDirectory(tempDir.path, 'nested');
      expect(results.length, 1);
      expect(results.first.name, 'nested.pdf');
    });
  });
}
