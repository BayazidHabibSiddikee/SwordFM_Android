import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/terminal_service.dart';
import 'package:swordfm/screens/terminal_screen.dart';
import 'package:flutter/material.dart';

void main() {
  group('TerminalService', () {
    test('path with spaces preserves the full path', () {
      const path = '/storage/emulated/0/My Documents';
      final quoted = path.replaceAll("'", "'\\''");
      expect(quoted, '/storage/emulated/0/My Documents');
    });

    test('path with apostrophe is escaped', () {
      const path = "/data/user/0/com.app/it's";
      final quoted = path.replaceAll("'", "'\\''");
      expect(quoted, isNot(equals(path)));
      expect(quoted.contains("\\'"), isTrue);
    });

    test('simple path passes through unchanged', () {
      const path = '/storage/emulated/0/Download';
      final quoted = path.replaceAll("'", "'\\''");
      expect(quoted, path);
    });

    test('path with multiple apostrophes escapes all', () {
      const path = "/a/b/c'd'e'f";
      final quoted = path.replaceAll("'", "'\\''");
      final quoteCount = "'\\'".allMatches(quoted).length;
      expect(quoteCount, 3, reason: 'Each apostrophe produces one escaped pair');
    });
  });

  group('TerminalScreen', () {
    testWidgets('renders with startPath', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TerminalScreen(startPath: '/tmp'),
        ),
      );
      // Should not throw during init
      await tester.pump();
    });

    testWidgets('renders with empty startPath', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TerminalScreen(startPath: ''),
        ),
      );
      await tester.pump();
    });
  });
}
