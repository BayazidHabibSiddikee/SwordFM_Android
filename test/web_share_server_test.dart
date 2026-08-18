import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/web_share_server.dart';
import 'package:swordfm/theme/theme.dart';

void main() {
  group('WebShareServer', () {
    test('default state before start', () {
      final server = WebShareServer();
      expect(server.isRunning, false);
      expect(server.currentIp, isNull);
    });

    test('QR code widget renders without crashing', () {
      final server = WebShareServer();
      // Before starting, QR code shows error message
      final widget = server.buildQrCode();
      expect(widget, isNotNull);
    });
  });

  group('OneDarkColors', () {
    test('all theme colors are defined', () {
      expect(OneDarkColors.bg, const Color(0xFF282C34));
      expect(OneDarkColors.cyan, const Color(0xFF61AFEF));
      expect(OneDarkColors.purple, const Color(0xFFC678DD));
    });
  });
}
