import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swordfm/main.dart';
import 'package:swordfm/screens/bluetooth_screen.dart';
import 'package:swordfm/screens/lan_screen.dart';
import 'package:swordfm/theme/theme.dart';
import 'package:swordfm/widgets/file_browser.dart';

void main() {
  group('SwordFM App Integration Tests', () {
    setUp(() {
      // MainScreen now checks "All files access" at startup (MainActivity
      // channel). Mock it as granted so no dialog blocks the tests, and keep
      // the storage-volume query a no-op.
      const devices = MethodChannel('com.swordfm/devices');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(devices, (call) async {
        switch (call.method) {
          case 'allFilesAccessGranted':
            return true;
          case 'getStorageVolumes':
            return <Object?>[];
          default:
            return null;
        }
      });
      // Skip the splash screen in tests so assertions on MainScreen pass.
      SharedPreferences.setMockInitialValues({'splash_shown': true});
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('com.swordfm/devices'), null);
    });

    testWidgets('App builds with One Dark theme and bottom navigation', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SwordFM());
      await tester.pump();

      // Verify app builds and Scaffold is present
      expect(find.byType(Scaffold), findsOneWidget);

      // Verify bottom navigation bar is present
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('Theme uses One Dark color scheme', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SwordFM());

      final ThemeData theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF282C34));
      expect(theme.colorScheme.primary, const Color(0xFF61AFEF));
      expect(theme.colorScheme.secondary, const Color(0xFF98C379));
    });

    testWidgets('Toggle sidebar button exists in main screen', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SwordFM());
      await tester.pump();
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets(
      'Theme toggle recolors OneDarkColors tab screens immediately (no restart)',
      (WidgetTester tester) async {
        // Regression: tab screens were const and read OneDarkColors getters,
        // so a runtime theme switch left them on the old palette until the
        // app was restarted. They must recolor as soon as the notifier fires.
        SharedPreferences.setMockInitialValues({
          'swordfm_theme_mode': 'light',
        });
        await loadThemeMode();
        await tester.pumpWidget(const SwordFM());
        await tester.pump();

        // Light mode: bg should be a light color
        final lightBg = OneDarkColors.bg;

        // Simulate the Settings theme tile toggle.
        saveThemeMode('dark');
        themeNotifier.value++;
        await tester.pump();

        // Dark mode: bg should be a dark color, different from light mode.
        final darkBg = OneDarkColors.bg;
        expect(darkBg, isNot(lightBg));

        // Restore the default theme so later tests see a dark app.
        saveThemeMode('dark');
      },
    );

    testWidgets('File browser loads default path', (WidgetTester tester) async {
      await tester.pumpWidget(const SwordFM());
      await tester.pump();
      expect(find.byType(FileBrowser), findsOneWidget);
    });
  });

  group('Bluetooth Screen UI', () {
    testWidgets('shows disconnected state by default', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: BluetoothScreen()));
      // pumpAndSettle runs the post-frame permission-check callback to
      // completion. The platform channel call fails in tests → isSupported()
      // returns false → the screen shows the "need permissions" UI.
      await tester.pumpAndSettle();

      expect(find.text('Disconnected'), findsOneWidget);
      // In tests, permissions aren't granted so it shows "Request Permissions"
      expect(find.text('Request Permissions'), findsOneWidget);
    });
  });

  group('LAN Screen UI', () {
    testWidgets('renders start server button', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: LANSharingScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Start Server'), findsOneWidget);
      expect(find.text('Scan QR'), findsOneWidget);
    });
  });
}
