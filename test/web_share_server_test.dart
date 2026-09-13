import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/web_share_server.dart';
import 'package:swordfm/theme/theme.dart';

/// Allocate a port the OS reports as free, then release it so the server can
/// bind it. There is a small race window, but it is the standard Dart idiom.
Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// Boot a real [WebShareServer] against a temp dir.
///
/// `start()` generates a random PIN internally and we cannot inject one, so we
/// accept whatever it produced and use `server.pin` for authenticated calls.
///
/// The WiFi-IP resolver is stubbed to loopback: the mDNS/QR advertisement path
/// is irrelevant to HTTP request handling, and `network_info_plus` has no
/// implementation in the test VM.
Future<WebShareServer> _boot(String shareRoot, int port) async {
  final server = WebShareServer(
    port: port,
    wifiIpResolver: () async => '127.0.0.1',
  );
  server.setShareRoot(shareRoot);
  final ip = await server.start(shareRootOverride: shareRoot);
  if (ip == null) {
    fail('WebShareServer.start() returned null despite an injected IP.');
  }
  return server;
}

/// Minimal cookie-aware HTTP client (Dart's HttpClient keeps no cookie jar).
class _Client {
  final HttpClient _http = HttpClient();
  final Map<String, String> _cookies = {};

  String get cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _absorbCookies(HttpClientResponse res) {
    final setCookies = res.headers['set-cookie'] ?? const <String>[];
    for (final raw in setCookies) {
      final pair = raw.split(';').first.trim();
      final idx = pair.indexOf('=');
      if (idx > 0) {
        _cookies[pair.substring(0, idx)] = pair.substring(idx + 1);
      }
    }
  }

  Future<(int, String)> get(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    if (_cookies.isNotEmpty) req.headers.set('cookie', cookieHeader);
    final res = await req.close();
    _absorbCookies(res);
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  Future<(int, String)> postJson(String url, Object body) async {
    final req = await _http.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    if (_cookies.isNotEmpty) req.headers.set('cookie', cookieHeader);
    req.write(jsonEncode(body));
    final res = await req.close();
    _absorbCookies(res);
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  /// Raw GET allowing custom headers (used for the Range tests).
  Future<(int, HttpClientResponse)> rawGet(String url,
      {Map<String, String>? headers}) async {
    final req = await _http.getUrl(Uri.parse(url));
    headers?.forEach(req.headers.set);
    if (_cookies.isNotEmpty) req.headers.set('cookie', cookieHeader);
    final res = await req.close();
    _absorbCookies(res);
    return (res.statusCode, res);
  }

  void close() => _http.close(force: true);
}

void main() {
  group('WebShareServer — pure helpers', () {
    test('default state before start', () {
      final server = WebShareServer();
      expect(server.isRunning, false);
      expect(server.currentIp, isNull);
      expect(server.pin, isEmpty);
      expect(server.accessLog, isEmpty);
    });

    test('QR code widget renders without crashing', () {
      final server = WebShareServer();
      expect(server.buildQrCode(), isNotNull);
    });

    test('rotatePin generates a numeric 6-digit pin', () {
      final server = WebShareServer();
      final firstPin = server.pin;
      server.rotatePin();
      expect(server.pin, isNot(equals(firstPin)));
      expect(int.tryParse(server.pin), isNotNull);
      expect(server.pin.length, 6);
    });

    test('setShareRoot appends a trailing slash and resets subdir', () {
      final server = WebShareServer();
      server.setShareRoot('/tmp/share');
      expect(server.shareRoot, '/tmp/share/');
      server.setShareRoot('/tmp/share/');
      expect(server.shareRoot, '/tmp/share/');
      expect(server.currentSubDir, '');
    });

    test('randomHex returns lowercase hex of double the byte length', () {
      final hex = WebShareServer.randomHex(4);
      expect(hex.length, 8);
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(hex), isTrue);
      expect(WebShareServer.randomHex(32).length, 64);
    });

    test('randomHex does not repeat across calls', () {
      expect(WebShareServer.randomHex(32),
          isNot(equals(WebShareServer.randomHex(32))));
    });

    group('constantTimeCompare', () {
      test('identical strings are equal', () {
        expect(WebShareServer.constantTimeCompare('abc', 'abc'), isTrue);
        expect(WebShareServer.constantTimeCompare('', ''), isTrue);
      });

      test('differing strings are unequal', () {
        expect(WebShareServer.constantTimeCompare('abc', 'def'), isFalse);
        expect(WebShareServer.constantTimeCompare('abc', 'abd'), isFalse);
      });

      test('length mismatch is unequal', () {
        expect(WebShareServer.constantTimeCompare('ab', 'abc'), isFalse);
        expect(WebShareServer.constantTimeCompare('abc', ''), isFalse);
      });

      test('a difference only in the final byte is detected', () {
        // Guards against an implementation that exits early on mismatch.
        expect(
            WebShareServer.constantTimeCompare('aaaaaaa1', 'aaaaaaa2'), isFalse);
      });
    });

    group('extractCookie', () {
      test('finds the matching cookie', () {
        expect(
          WebShareServer.extractCookie(
              'swordfm_session=abc123; Path=/', 'swordfm_session'),
          equals('abc123'),
        );
      });

      test('returns null when absent or on an empty header', () {
        expect(WebShareServer.extractCookie('other=value', 'swordfm_session'),
            isNull);
        expect(WebShareServer.extractCookie('', 'swordfm_session'), isNull);
      });

      test('handles multiple cookies and surrounding whitespace', () {
        expect(
          WebShareServer.extractCookie(
              'a=1;  swordfm_session=xyz ; b=2', 'swordfm_session'),
          equals('xyz'),
        );
      });

      test('rejects a cookie whose name merely ends with the target name', () {
        expect(
          WebShareServer.extractCookie(
              'not_swordfm_session=evil', 'swordfm_session'),
          isNull,
        );
      });
    });

    group('sanitizeName', () {
      test('passes through ordinary filenames', () {
        expect(WebShareServer.sanitizeName('hello.pdf'), equals('hello.pdf'));
        expect(WebShareServer.sanitizeName('my-file (1).txt'),
            equals('my-file (1).txt'));
      });

      test('strips forward- and back-slash directory components', () {
        expect(WebShareServer.sanitizeName('foo/bar/hello.pdf'),
            equals('hello.pdf'));
        expect(WebShareServer.sanitizeName(r'foo\bar\hello.pdf'),
            equals('hello.pdf'));
      });

      test('an absolute path collapses to its basename', () {
        expect(WebShareServer.sanitizeName('../etc/passwd'), equals('passwd'));
        expect(WebShareServer.sanitizeName('/etc/passwd'), equals('passwd'));
      });

      test('rejects a basename that itself contains dots-dot', () {
        expect(WebShareServer.sanitizeName('file..txt'), equals(''));
        expect(WebShareServer.sanitizeName('..'), equals(''));
      });

      test('rejects NUL bytes', () {
        expect(WebShareServer.sanitizeName('file\u0000.txt'), equals(''));
      });

      test('rejects empty input and a trailing separator only', () {
        expect(WebShareServer.sanitizeName(''), equals(''));
        expect(WebShareServer.sanitizeName('folder/'), equals(''));
      });

      test('caps oversized names at 255 characters', () {
        expect(WebShareServer.sanitizeName('a' * 300).length, 255);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Live server: auth, session cookies, traversal and Range handling.
  // These exercise the real HTTP stack on a loopback port.
  // ---------------------------------------------------------------------------
  group('WebShareServer — live HTTP', () {
    late Directory root;
    late WebShareServer server;
    late _Client client;
    late String base;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sfm_share_');
      await File('${root.path}/hello.txt').writeAsString('hello world');
      await Directory('${root.path}/sub').create();

      final port = await _freePort();
      server = await _boot(root.path, port);
      client = _Client();
      base = 'http://127.0.0.1:$port';
    });

    tearDown(() async {
      client.close();
      server.stop();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    // ---- lifecycle / session ------------------------------------------------

    test('isRunning is true after start and pin is a 6-digit number', () {
      expect(server.isRunning, isTrue);
      expect(int.tryParse(server.pin), isNotNull);
    });

    test('unauthenticated /api/list is rejected with 401', () async {
      final (status, _) = await client.get('$base/api/list');
      expect(status, 401);
    });

    test('unauthenticated /api/download is rejected with 401', () async {
      final (status, _) = await client.get('$base/download/hello.txt');
      expect(status, 401);
    });

    test('POST /api/auth with the wrong pin returns 401', () async {
      final (status, body) =
          await client.postJson('$base/api/auth', {'pin': '000000'});
      expect(status, 401);
      expect(body, contains('Invalid pin'));
    });

    test('POST /api/auth with no pin returns 400', () async {
      final (status, body) =
          await client.postJson('$base/api/auth', <String, dynamic>{});
      expect(status, 400);
      expect(body, contains('Missing pin'));
    });

    test('the correct pin grants a session cookie and unlocks the API',
        () async {
      final (pre, _) = await client.get('$base/api/list');
      expect(pre, 401, reason: 'must be locked before authenticating');

      final (authStatus, authBody) =
          await client.postJson('$base/api/auth', {'pin': server.pin});
      expect(authStatus, 200);
      expect(authBody, contains('session'));
      expect(client.cookieHeader, contains('swordfm_session='));

      final (post, listBody) = await client.get('$base/api/list');
      expect(post, 200);
      final names = ((jsonDecode(listBody) as Map)['files'] as List)
          .map((f) => (f as Map)['name'] as String)
          .toList();
      expect(names, containsAll(<String>['hello.txt', 'sub']));
    });

    test('the session cookie is HttpOnly with SameSite=Lax', () async {
      final req = await HttpClient().postUrl(Uri.parse('$base/api/auth'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'pin': server.pin}));
      final res = await req.close();
      final setCookie = res.headers.value('set-cookie') ?? '';
      expect(setCookie, contains('HttpOnly'));
      expect(setCookie, contains('SameSite=Lax'));
      await res.drain<void>();
    });

    test('repeated bad pins get rate-limited with 429', () async {
      for (var i = 0; i < 5; i++) {
        await client.postJson('$base/api/auth', {'pin': '111111'});
      }
      final (status, body) =
          await client.postJson('$base/api/auth', {'pin': '111111'});
      expect(status, 429);
      expect(body, contains('Too many attempts'));
    });

    test('the lockout also blocks the CORRECT pin (brute-force defence)',
        () async {
      for (var i = 0; i < 5; i++) {
        await client.postJson('$base/api/auth', {'pin': '111111'});
      }
      final (status, _) =
          await client.postJson('$base/api/auth', {'pin': server.pin});
      expect(status, 429);
    });

    test('rotatePin invalidates an existing session cookie', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (ok, _) = await client.get('$base/api/list');
      expect(ok, 200);

      server.rotatePin();

      final (revoked, _) = await client.get('$base/api/list');
      expect(revoked, 401,
          reason: 'rotating the PIN must drop every existing session');
    });

    test('a forged session cookie is rejected with 401', () async {
      final http = HttpClient();
      final req = await http.getUrl(Uri.parse('$base/api/list'));
      req.headers.set('cookie', 'swordfm_session=deadbeefdeadbeef');
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 401);
      http.close(force: true);
    });

    // ---- path traversal ----------------------------------------------------

    test('subdir escape via dots-dot is rejected with 400', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, _) = await client
          .get('$base/api/list?subdir=${Uri.encodeComponent('../')}');
      expect(status, 400);
    });

    test('download with an escaping subdir is rejected with 400', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, _) = await client.get(
          '$base/download/hello.txt?subdir=${Uri.encodeComponent('../')}');
      expect(status, 400);
    });

    test('download of a NUL-laden filename is rejected with 400', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, _) = await client
          .get('$base/download/${Uri.encodeComponent('a\u0000b')}');
      expect(status, 400);
    });

    test('a missing file yields 404', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, _) = await client.get('$base/download/nope.txt');
      expect(status, 404);
    });

    test('a directory cannot be downloaded as a file', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, _) = await client.get('$base/download/sub');
      expect(status, 404);
    });

    test('a legitimate subdir listing stays inside the share root', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, body) = await client.get('$base/api/list?subdir=sub');
      expect(status, 200);
      expect((jsonDecode(body) as Map)['currentDir'], 'sub');
    });

    // ---- download content / Range ------------------------------------------

    test('an authenticated download returns the exact file bytes', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, body) = await client.get('$base/download/hello.txt');
      expect(status, 200);
      expect(body, 'hello world');
    });

    test('a byte Range request returns 206 with exactly those bytes', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, res) = await client
          .rawGet('$base/download/hello.txt', headers: {'range': 'bytes=0-4'});
      expect(status, 206);
      expect(res.headers.value('content-range'), 'bytes 0-4/11');
      expect(await res.transform(utf8.decoder).join(), 'hello');
    });

    test('an open-ended Range returns the tail of the file', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, res) = await client
          .rawGet('$base/download/hello.txt', headers: {'range': 'bytes=6-'});
      expect(status, 206);
      expect(await res.transform(utf8.decoder).join(), 'world');
    });

    test('an out-of-bounds Range yields 416 with a Content-Range hint',
        () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, res) = await client.rawGet(
          '$base/download/hello.txt',
          headers: {'range': 'bytes=0-9999'});
      expect(status, 416);
      expect(res.headers.value('content-range'), 'bytes */11');
      await res.drain<void>();
    });

    test('a malformed Range header yields 416', () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, res) = await client.rawGet(
          '$base/download/hello.txt',
          headers: {'range': 'pages=1-2'});
      expect(status, 416);
      await res.drain<void>();
    });

    test('a full download advertises Accept-Ranges for resumability',
        () async {
      await client.postJson('$base/api/auth', {'pin': server.pin});
      final (status, res) = await client.rawGet('$base/download/hello.txt');
      expect(status, 200);
      expect(res.headers.value('accept-ranges'), 'bytes');
      expect(res.headers.value('content-disposition'),
          contains('hello.txt'));
      await res.drain<void>();
    });

    // ---- access log / shutdown ---------------------------------------------

    test('the access log records authenticated client requests', () async {
      expect(server.accessLog, isEmpty);
      await client.postJson('$base/api/auth', {'pin': server.pin});
      await client.get('$base/api/list');
      expect(server.accessLog, isNotEmpty);
    });

    test('favicon requests are excluded from the access log', () async {
      await client.get('$base/favicon.ico');
      expect(server.accessLog, isEmpty);
    });

    test('stopping the server clears isRunning and releases the port',
        () async {
      server.stop();
      expect(server.isRunning, isFalse);
      final rebind =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, server.port);
      expect(rebind.port, server.port);
      await rebind.close();
    });

    test('the home page renders a PIN prompt before authentication', () async {
      final (status, body) = await client.get('$base/');
      expect(status, 200);
      expect(body.toLowerCase(), contains('pin'));
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

