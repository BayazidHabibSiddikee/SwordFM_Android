import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swordfm/main.dart';
import 'package:swordfm/screens/lan_screen.dart';
import 'package:swordfm/services/web_share_server.dart';
import 'package:swordfm/widgets/file_browser.dart';

void main() {
  // Phone-like logical viewport: 1080x2400 px @ 3x = 360x800 dp.
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  setUp(() {
    // NetworkScreen loads profiles via shared_preferences at startup.
    SharedPreferences.setMockInitialValues({});
    // MainScreen checks "All files access" at startup (MainActivity channel) —
    // mock as granted so no dialog blocks the overflow test.
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
    // BookmarksService uses path_provider; no plugin in the test harness.
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.createTempSync('swordfm_test').path;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.swordfm/devices'), null);
  });

  group('UI overflow regression (narrow phone viewport)', () {
    testWidgets('sidebar tiles fit the 160px drawer without overflow',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(const SwordFM());
      await tester.pump(const Duration(milliseconds: 200));

      // Sidebar tiles are rendered within the 160px drawer; no overflow
      // exception thrown.
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Places'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('details view rows fit a 200px-wide browser without overflow',
        (tester) async {
      usePhoneViewport(tester);
      final tmp = Directory.systemTemp.createTempSync('overflow_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // A directory triggers the folder-size cell (the previous overflow
      // source); the big file forces a non-trivial size string.
      Directory('${tmp.path}/beta_dir').createSync();
      File('${tmp.path}/alpha_folder')
          .writeAsBytesSync(List.filled(1024 * 200, 1));

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 200,
                child: FileBrowser(
                  initialPath: tmp.path,
                  onItemSelected: (_) {},
                  onSelectionChanged: (_) {},
                ),
              ),
            ),
          ),
        );
        // Let the async directory listing and folder-size futures finish.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Both rows rendered.
      expect(find.textContaining('alpha_folder'), findsOneWidget);
      expect(find.textContaining('beta_dir'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Switch to grid view — adaptive column count must render without
      // overflow in the 200px-wide pane.
      await tester.ensureVisible(find.byIcon(Icons.view_list));
      await tester.tap(find.byIcon(Icons.view_list));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('alpha_folder'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('LAN screen with running server (QR shown) does not overflow',
        (tester) async {
      usePhoneViewport(tester);
      // start() needs a WiFi IP from network_info_plus — provide one so the
      // real HttpServer binds and the QR column renders.
      const netInfo = MethodChannel('dev.fluttercommunity.plus/network_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(netInfo, (call) async {
        if (call.method == 'wifiIPAddress') return '192.168.1.50';
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(netInfo, null);
      });

      // Grab a free port (8080 may be occupied on the host) and inject a
      // server using it.
      late final int freePort;
      await tester.runAsync(() async {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        freePort = socket.port;
        await socket.close();
      });
      final server = WebShareServer(port: freePort);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LANSharingScreen(server: server)),
        );
        tester.tap(find.text('Start Server'));
        // Real socket bind + QR build complete on the event loop.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Server Running'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Stop the server so the socket is released before the test ends.
      await tester.runAsync(() async {
        tester.tap(find.text('Stop Server'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    });
  });
}
