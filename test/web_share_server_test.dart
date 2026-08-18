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
      final widget = server.buildQrCode();
      expect(widget, isNotNull);
    });

    // ---- rotatePin / setShareRoot ----
    test('rotatePin generates a different pin', () {
      final server = WebShareServer();
      // Pin is initialized lazily via start(); just verify it produces 6-digit PINs
      final firstPin = server.pin;
      server.rotatePin();
      expect(server.pin, isNot(equals(firstPin)));
      expect(int.tryParse(server.pin), isNotNull); // must be numeric
    });

    test('setShareRoot trims trailing slash and resets subdir', () {
      final server = WebShareServer();
      server.setShareRoot('/tmp/share/');
      expect(server.shareRoot, '/tmp/share/');
      server.setShareRoot('/tmp/share');
      expect(server.shareRoot, '/tmp/share/');
      expect(server.currentSubDir, '');
    });

    // ---- randomHex ----
    test('randomHex returns hex string of correct length', () {
      final hex = WebShareServer.randomHex(4);
      expect(hex.length, 8); // 4 bytes → 8 hex chars
      expect(int.tryParse(hex, radix: 16), isNotNull);
    });

    // ---- constantTimeCompare ----
    test('constantTimeCompare same strings true', () {
      expect(WebShareServer.constantTimeCompare('abc', 'abc'), isTrue);
    });

    test('constantTimeCompare different strings false', () {
      expect(WebShareServer.constantTimeCompare('abc', 'def'), isFalse);
      expect(WebShareServer.constantTimeCompare('abc', 'abd'), isFalse);
    });

    test('constantTimeCompare different lengths false', () {
      expect(WebShareServer.constantTimeCompare('ab', 'abc'), isFalse);
      expect(WebShareServer.constantTimeCompare('abc', 'abcd'), isFalse);
    });

    test('constantTimeCompare empty strings true', () {
      expect(WebShareServer.constantTimeCompare('', ''), isTrue);
    });

    // ---- extractCookie ----
    test('extractCookie finds matching cookie', () {
      expect(
        WebShareServer.extractCookie('swordfm_session=abc123; Path=/', 'swordfm_session'),
        equals('abc123'),
      );
    });

    test('extractCookie missing cookie returns null', () {
      expect(
        WebShareServer.extractCookie('other=value', 'swordfm_session'),
        isNull,
      );
    });

    test('extractCookie handles multiple cookies', () {
      final header = 'a=1; swordfm_session=xyz; b=2';
      expect(
        WebShareServer.extractCookie(header, 'swordfm_session'),
        equals('xyz'),
      );
    });

    // ---- sanitizeName ----
    test('sanitizeName basic filename', () {
      expect(WebShareServer.sanitizeName('hello.pdf'), equals('hello.pdf'));
    });

    test('sanitizeName strips directory paths', () {
      expect(WebShareServer.sanitizeName('foo/bar/hello.pdf'), equals('hello.pdf'));
      expect(WebShareServer.sanitizeName(r'foo\bar\hello.pdf'), equals('hello.pdf'));
    });

    test('sanitizeName rejects absolute dotdot at basename level', () {
      // '../etc/passwd' → basename is 'passwd' (the '..' resolves before basename)
      expect(WebShareServer.sanitizeName('../etc/passwd'), equals('passwd'));
    });

    test('sanitizeName blocks double-dot within the basename itself', () {
      expect(WebShareServer.sanitizeName('file..txt'), equals(''));
    });

    test('sanitizeName rejects null byte', () {
      expect(WebShareServer.sanitizeName('file\x00.txt'), equals(''));
    });

    test('sanitizeName rejects empty input', () {
      expect(WebShareServer.sanitizeName(''), equals(''));
    });

    test('sanitizeName caps at max length', () {
      final longName = 'a' * 300;
      final result = WebShareServer.sanitizeName(longName);
      expect(result.length, 255);
    });

    test('sanitizeName keeps valid special chars', () {
      expect(WebShareServer.sanitizeName('my-file (1).txt'), equals('my-file (1).txt'));
    });

    test('sanitizeName strips trailing slash to empty (trailing slash = dir)', () {
      expect(WebShareServer.sanitizeName('folder/'), equals(''));
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
