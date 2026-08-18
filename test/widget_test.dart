import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/main.dart';
import 'package:swordfm/screens/bluetooth_screen.dart';
import 'package:swordfm/screens/lan_screen.dart';
import 'package:swordfm/widgets/file_browser.dart';

void main() {
  group('SwordFM App Integration Tests', () {
    testWidgets('App builds with One Dark theme and bottom navigation',
        (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());

      // Verify app builds and Scaffold is present
      expect(find.byType(Scaffold), findsOneWidget);

      // Verify bottom navigation bar is present
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('Theme uses One Dark color scheme', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());

      final ThemeData theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF282C34));
      expect(theme.colorScheme.primary, const Color(0xFF61AFEF));
      expect(theme.colorScheme.secondary, const Color(0xFF98C379));
    });

    testWidgets('Toggle sidebar button exists in main screen',
        (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets('File browser loads default path', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());
      expect(find.byType(FileBrowser), findsOneWidget);
    });
  });

  group('Bluetooth Screen UI', () {
    testWidgets('shows disconnected state by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BluetoothScreen()),
      );
            // First pump renders loading indicator; pumpAndSettle runs the post-frame
      // permission-check callback to completion (resolving the platform channel
      // call which fails in tests → isSupported() returns false → shows the
      // "need permissions" UI).
      await tester.pumpWidget(
        const MaterialApp(home: BluetoothScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Disconnected'), findsOneWidget);
      // In tests, permissions aren't granted so it shows "Request Permissions"
      expect(find.text('Request Permissions'), findsOneWidget);
    });
  });

  group('LAN Screen UI', () {
    testWidgets('renders start server button', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LANSharingScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Start Server'), findsOneWidget);
      expect(find.text('Scan QR'), findsOneWidget);
    });
  });
}
