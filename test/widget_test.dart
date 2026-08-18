import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/main.dart';
import 'package:swordfm/screens/bluetooth_screen.dart';
import 'package:swordfm/screens/lan_screen.dart';
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

    testWidgets('Navigating between tabs switches pages', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());

      // Initial page should be Files
      expect(find.byType(MainScreen), findsOneWidget);

      // Tap on Bluetooth tab
      await tester.tap(find.text('Bluetooth'));
      await tester.pumpAndSettle();

      // Should show Bluetooth screen content
      expect(find.text('Paired Devices'), findsOneWidget);

      // Tap on LAN tab
      await tester.tap(find.text('LAN'));
      await tester.pumpAndSettle();

      // Should show LAN sharing content
      expect(find.text('How to Use'), findsOneWidget);
    });

    testWidgets('Theme uses One Dark color scheme', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());

      final ThemeData theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF282C34));
      expect(theme.colorScheme.primary, const Color(0xFF61AFEF));
      expect(theme.colorScheme.secondary, const Color(0xFF98C379));
    });

    testWidgets('Settings screen renders all sections', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('File Management'), findsOneWidget);
      expect(find.text('Sharing'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('Toggle sidebar button exists in main screen',
        (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });
  });

  group('Bluetooth Screen UI', () {
    testWidgets('shows disconnected state by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const BluetoothScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Start Listening'), findsOneWidget);
    });
  });

  group('LAN Screen UI', () {
    testWidgets('renders start server button', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LANSharingScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Start Server'), findsOneWidget);
      expect(find.text('Scan QR'), findsOneWidget);
    });
  });
}
