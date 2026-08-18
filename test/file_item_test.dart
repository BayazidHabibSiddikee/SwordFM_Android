import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/utils/file_utils.dart';
import 'package:swordfm/theme/theme.dart';

void main() {
  // Helper to create a FileItem — uses a real temporary directory path
  FileItem makeFile(String name, {bool isDir = false, int size = 0}) {
    return FileItem(
      entity: isDir ? Directory('/tmp/fake/path/$name') : File('/tmp/fake/path/$name'),
      name: name,
      path: '/tmp/fake/path/$name',
      isDirectory: isDir,
      size: size,
      lastModified: DateTime.now(),
    );
  }

  group('FileItem', () {
    test('formatSize returns bytes correctly', () {
      expect(makeFile('test.txt', size: 500).formattedSize, '500 B');
    });

    test('formatSize returns KB correctly', () {
      expect(makeFile('test.txt', size: 1500).formattedSize, '1.5 KB');
    });

    test('formatSize returns MB correctly', () {
      expect(makeFile('video.mp4', size: 5 * 1024 * 1024).formattedSize, '5.0 MB');
    });

    test('directories return empty formattedSize', () {
      expect(makeFile('my_folder', isDir: true).formattedSize, '');
    });

    test('image files get correct icon and color', () {
      final item = makeFile('photo.png', size: 1000);
      expect(item.icon, Icons.image);
      expect(item.iconColor, const Color(0xFFE5C07B));
    });

    test('code files get description icon with green color', () {
      final item = makeFile('main.dart', size: 500);
      expect(item.icon, Icons.description);
      expect(item.iconColor, const Color(0xFF98C379));
    });

    test('PDF gets red picture icon', () {
      final item = makeFile('doc.pdf', size: 10000);
      expect(item.icon, Icons.picture_as_pdf);
      expect(item.iconColor, const Color(0xFFE06C75));
    });

    test('directories get cyan folder icon', () {
      final item = makeFile('folder', isDir: true);
      expect(item.icon, Icons.folder);
      expect(item.iconColor, Colors.cyan);
    });

    test('markdown detection flags', () {
      final item = makeFile('README.md', size: 100);
      expect(item.isMarkdown, true);
      expect(item.isText, true);
    });

    test('image detection flag', () {
      final item = makeFile('photo.jpg', size: 10000);
      expect(item.isImage, true);
    });
  });

  group('OneDarkTheme colors', () {
    test('theme has correct primary and background colors', () {
      final theme = buildOneDarkTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF282C34));
      expect(theme.colorScheme.primary, const Color(0xFF61AFEF));
      expect(theme.colorScheme.secondary, const Color(0xFF98C379));
    });

    test('OneDarkColors constants have expected hex values', () {
      expect(OneDarkColors.bg, const Color(0xFF282C34));
      expect(OneDarkColors.bgDark, const Color(0xFF21252B));
      expect(OneDarkColors.cyan, const Color(0xFF61AFEF));
      expect(OneDarkColors.amber, const Color(0xFFE5C07B));
      expect(OneDarkColors.red, const Color(0xFFE06C75));
      expect(OneDarkColors.purple, const Color(0xFFC678DD));
    });
  });
}
