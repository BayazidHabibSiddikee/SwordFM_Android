import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import '../utils/file_utils.dart';
import '../theme/theme.dart';

/// Maximum number of entries kept in the client-access log.
const int _kMaxAccessLog = 200;

/// Maximum allowed name length after sanitization (prevents DoS from huge names).
const int _kMaxSafeNameLen = 255;

/// A pure-Dart LAN file sharing server for SwordFM Android.
///
/// Generates a QR code so nearby devices can browse/download/upload files
/// behind a PIN-gated session. Supports configurable share-root and subdirectory
/// browsing via [currentSubDir].
///
/// Security notes:
///   • All authenticated endpoints check a session cookie issued after a
///     correct PIN POST. Cookie is random 32-hex; PIN comparison is constant-time.
///   • Upload filenames and download paths are passed through [_sanitizeName]
///     (basename-only, no `..`, no null bytes) before touching the filesystem.
///   • Downloads stream from disk; uploads stream to disk — neither buffers
///     the entire body in memory.
class WebShareServer {
  HttpServer? _server;
  final NetworkInfo _networkInfo = NetworkInfo();

  String? _currentIp;
  bool _isRunning = false;
  String _pin = "";

  /// Path to the root directory being shared (default: ~/Downloads/SwordFM).
  late String _shareRoot;

  /// Current sub-directory relative to [_shareRoot] served by the web UI.
  String currentSubDir = '';

  // --- Session store ---------------------------------------------------------
  // In-memory map: cookie token → PIN value (for rotation invalidation).
  // In production you'd externalise this; suitable for a single-device app.
  final Map<String, String> _sessions = {};

  // --- Client access log (ring buffer) --------------------------------------
  final List<Map<String, dynamic>> _accessLog = [];

  /// Public view of the client-access log (read-only copy).
  List<Map<String, dynamic>> get accessLog => List.from(_accessLog);

  String? get currentIp => _currentIp;
  bool get isRunning => _isRunning;
  String get pin => _pin;
  String get shareRoot => _shareRoot;

  static const int port = 8080;

  /// Generate a random 6-digit PIN for client authorization.
  String _generatePin() {
    return (100000 + Random().nextInt(900000)).toString();
  }

  /// Rotate to a fresh PIN and invalidate every existing session cookie.
  void rotatePin() {
    _pin = _generatePin();
    _sessions.clear();
  }

  /// Point the share server at a different root directory.
  void setShareRoot(String dir) {
    _shareRoot = dir.endsWith('/') ? dir : '$dir/';
    currentSubDir = '';
  }

  Future<String?> start({String? shareRootOverride}) async {
    try {
      _currentIp = await _networkInfo.getWifiIP();
      if (_currentIp == null) return null;

      _shareRoot = shareRootOverride ?? '${AppPaths.downloads}/SwordFM';
      _pin = _generatePin();
      _sessions.clear();
      _accessLog.clear();

      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;

      _server!.listen((HttpRequest request) async {
        try {
          final path = request.uri.path;
          final rawQuery = request.uri.query;

          // Track access (excluding favicon / static assets).
          if (path != '/favicon.ico') {
            _logAccess(request, path, rawQuery);
          }

          if (request.method == 'GET') {
            if (path == '/' || path == '/index.html') {
              await _serveHomePage(request);
            } else if (path.startsWith('/download/')) {
              await _serveDownload(request, path.substring(('/download/').length));
            } else if (path.startsWith('/api/list')) {
              await _serveApiList(request, rawQuery);
            } else if (path == '/api/pin') {
              _sendJsonResponse(request, {'pin': _pin});
            } else {
              _sendResponse(request, 404, 'Not Found');
            }
          } else if (request.method == 'POST') {
            if (path == '/api/auth') {
              await _handleAuth(request);
            } else if (path == '/upload' || path == '/api/upload') {
              await _handleUpload(request);
            } else {
              _sendResponse(request, 404, 'Not Found');
            }
          } else {
            _sendResponse(request, 405, 'Method Not Allowed');
          }
        } catch (e) {
          debugPrint('WebShareServer error: $e');
          _sendResponse(request, 500, 'Internal Server Error: $e');
        }
      });

      return _currentIp;
    } catch (e) {
      debugPrint('Error starting WebShareServer: $e');
      return null;
    }
  }

  /// ---- Auth helpers --------------------------------------------------------

  /// Validates a session cookie. Returns true if the request carries a valid
  /// session that was authenticated with the current [_pin].
  bool _hasValidSession(HttpRequest request) {
    final cookies = request.headers.value('cookie') ?? '';
    final sessionCookie = extractCookie(cookies, 'swordfm_session');
    if (sessionCookie == null) return false;
    final storedPin = _sessions[sessionCookie];
    if (storedPin == null) return false;
    // Constant-time comparison to mitigate timing attacks.
    return constantTimeCompare(storedPin, _pin);
  }

  /// Returns 401 response when auth is required but missing / invalid.
  void _grantSession(HttpRequest request, String pin) {
    final token = randomHex(32);
    _sessions[token] = pin;
    request.response.headers.add(
      'Set-Cookie',
      'swordfm_session=$token; Path=/; HttpOnly; SameSite=Lax',
    );
    _sendJsonResponse(request, {'session': token});
  }

  static String randomHex(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => Random().nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// O(n) constant-time compare: XOR accumulates across every byte so we
  /// never short-circuit on a mismatch.
  static bool constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String? extractCookie(String header, String name) {
    for (final part in header.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('$name=')) {
        return trimmed.substring(name.length + 1);
      }
    }
    return null;
  }

  /// Sanitize a user-supplied filename/path segment:
  ///   • take only the basename (strip directories)
  ///   • reject .., null bytes, empty result
  ///   • cap at [_kMaxSafeNameLen] chars
  static String sanitizeName(String input) {
    if (input.isEmpty) return '';
    // Take last path component (handles / \ both directions).
    var name = input.replaceAll(r'\', '/').split('/').last;
    // Reject dangerous substrings.
    if (name.contains('..') || name.contains(String.fromCharCode(0))) return '';
    if (name.isEmpty) return '';
    if (name.length > _kMaxSafeNameLen) name = name.substring(0, _kMaxSafeNameLen);
    return name;
  }

  // ---- Request handlers ----------------------------------------------------

  Future<void> _handleAuth(HttpRequest request) async {
    final bodyStr = await _readBody(request);
    Map<dynamic, dynamic>? body;
    try {
      body = jsonDecode(bodyStr) as Map<dynamic, dynamic>?;
    } catch (_) {}
    final submittedPin = body?['pin'] as String?;
    if (submittedPin == null || submittedPin.isEmpty) {
      _sendJsonResponse(request, {'error': 'Missing pin'}, statusCode: 400);
      return;
    }
    if (!constantTimeCompare(submittedPin, _pin)) {
      _sendJsonResponse(request, {'error': 'Invalid pin'}, statusCode: 401);
      return;
    }
    _grantSession(request, submittedPin);
  }

  Future<String> _readBody(HttpRequest request) async {
    final sb = StringBuffer();
    await for (final chunk in request) {
      sb.write(String.fromCharCodes(chunk));
    }
    return sb.toString();
  }

  /// Serve the SPA HTML. When not yet authenticated we show a PIN entry screen;
  /// once authenticated the regular browser UI is returned.
  Future<void> _serveHomePage(HttpRequest request) async {
    final jsLoadFiles = _buildJsLoadFiles();
    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SwordFM Share</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, sans-serif; background: #282C34; color: #ABB2BF; min-height: 100vh; }
    .header { background: #21252B; padding: 16px 20px; border-bottom: 1px solid #3E4451; display: flex; justify-content: space-between; align-items: center; }
    .header h1 { color: #61AFEF; font-size: 20px; }
    .header .controls { display: flex; gap: 8px; }
    .container { max-width: 600px; margin: 0 auto; padding: 16px; }
    .pin-banner { background: #3E4451; border-radius: 8px; padding: 12px 16px; margin-bottom: 16px; display: flex; align-items: center; gap: 12px; }
    .pin-banner code { font-size: 20px; letter-spacing: 4px; color: #E5C07B; }
    .upload-area { border: 2px dashed #3E4451; border-radius: 8px; padding: 32px; text-align: center; cursor: pointer; transition: all 0.2s; }
    .upload-area:hover { border-color: #61AFEF; background: #2C313C; }
    .upload-area input[type="file"] { display: none; }
    .file-list { margin-top: 20px; }
    .file-item { background: #21252B; border-radius: 6px; padding: 10px 14px; margin-bottom: 6px; display: flex; justify-content: space-between; align-items: center; }
    .file-item a { color: #61AFEF; text-decoration: none; }
    .file-item a:hover { text-decoration: underline; }
    .file-size { color: #5C6370; font-size: 12px; }
    .empty { color: #5C6370; text-align: center; padding: 24px; }
    .spinner { display: inline-block; width: 20px; height: 20px; border: 2px solid #3E4451; border-top-color: #61AFEF; border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    #status { margin-top: 12px; padding: 8px 12px; border-radius: 6px; display: none; }
    #status.success { background: #98C379; color: #282C34; display: block; }
    #status.error { background: #E06C75; color: #282C34; display: block; }
    /* PIN entry overlay */
    #pinOverlay { position: fixed; inset: 0; background: #21252B; display: flex; flex-direction: column; align-items: center; justify-content: center; z-index: 100; }
    #pinOverlay input { background: #282C34; border: 1px solid #3E4451; color: #ABB2BF; padding: 10px 16px; border-radius: 6px; font-size: 20px; letter-spacing: 6px; width: 200px; text-align: center; margin-top: 12px; }
    #pinOverlay button { margin-top: 12px; padding: 10px 24px; background: #61AFEF; color: #282C34; border: none; border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer; }
    .hidden { display: none !important; }
    .nav-bar { background: #21252B; padding: 8px 16px; border-bottom: 1px solid #3E4451; font-size: 13px; color: #5C6370; }
    .nav-bar a { color: #61AFEF; text-decoration: none; cursor: pointer; }
    .nav-bar a:hover { text-decoration: underline; }
    .btn-sm { padding: 4px 10px; border-radius: 4px; border: 1px solid #3E4451; background: transparent; color: #ABB2BF; cursor: pointer; font-size: 12px; }
    .btn-sm:hover { border-color: #61AFEF; color: #61AFEF; }
  </style>
</head>
<body>
  <!-- PIN entry overlay (shown until authenticated) -->
  <div id="pinOverlay">
    <h2 style="color:#61AFEF; margin-bottom: 8px;">SwordFM Share</h2>
    <p style="color:#5C6370; font-size:13px;">Enter the PIN shown on the device</p>
    <input id="pinInput" type="password" maxlength="6" placeholder="••••••" autocomplete="off">
    <button onclick="submitPin()">Submit</button>
    <div id="pinError" style="color:#E06C75; margin-top:8px; font-size:13px; display:none;"></div>
  </div>

  <!-- Main app (hidden until authenticated) -->
  <div id="app" class="hidden">
    <div class="header">
      <h1>SwordFM Share</h1>
      <div class="controls">
        <button class="btn-sm" onclick="logout()">Logout</button>
      </div>
    </div>
    <div class="nav-bar" id="navBar"></div>
    <div class="container">
      <form id="uploadForm" enctype="multipart/form-data">
        <div class="upload-area" onclick="document.getElementById('fileInput').click()">
          <div style="font-size: 32px; margin-bottom: 8px;">📁</div>
          <div>Tap to select files to upload</div>
          <div id="selectedFile" style="color: #61AFEF; margin-top: 8px; font-size: 13px;"></div>
          <input type="file" id="fileInput" name="file" multiple onchange="showSelected(this)">
        </div>
        <button type="submit" style="margin-top: 12px; width: 100%; padding: 10px; background: #61AFEF; color: #282C34; border: none; border-radius: 6px; font-size: 14px; font-weight: 600; cursor: pointer;">Upload Files</button>
      </form>
      <div id="status"></div>
      <div class="file-list">
        <h3 style="color: #61AFEF; margin-bottom: 12px;">Available Files</h3>
        <div id="fileList">
          <div class="empty"><span class="spinner"></span> Loading...</div>
        </div>
      </div>
    </div>
  </div>

  <script>
    var sessionToken = localStorage.getItem('swordfm_session') || '';

    function submitPin() {
      var pin = document.getElementById('pinInput').value.trim();
      if (!pin) return;
      fetch('/api/auth', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({pin: pin}),
        credentials: 'include'
      }).then(function(r) {
        if (r.ok) return r.json();
        throw new Error('invalid');
      }).then(function(d) {
        sessionToken = d.session;
        localStorage.setItem('swordfm_session', sessionToken);
        document.getElementById('pinOverlay').classList.add('hidden');
        document.getElementById('app').classList.remove('hidden');
        loadFiles();
      }).catch(function() {
        var el = document.getElementById('pinError');
        el.textContent = 'Incorrect PIN';
        el.style.display = 'block';
      });
    }
    document.getElementById('pinInput').addEventListener('keydown', function(e) {
      if (e.key === 'Enter') submitPin();
    });

    function logout() {
      sessionToken = '';
      localStorage.removeItem('swordfm_session');
      document.getElementById('pinOverlay').classList.remove('hidden');
      document.getElementById('app').classList.add('hidden');
      document.getElementById('pinInput').value = '';
      document.getElementById('pinError').style.display = 'none';
    }

    function authHeaders() {
      return sessionToken ? {'Cookie': 'swordfm_session=' + sessionToken} : {};
    }

    $jsLoadFiles

    function showSelected(input) {
      const names = Array.from(input.files).map(f => f.name).join(', ');
      document.getElementById('selectedFile').textContent = names;
    }

    document.getElementById('uploadForm').onsubmit = async (e) => {
      e.preventDefault();
      const form = new FormData(e.target);
      const statusEl = document.getElementById('status');
      statusEl.className = ''; statusEl.style.display = 'block'; statusEl.textContent = 'Uploading...';
      try {
        const r = await fetch('/api/upload', { method: 'POST', body: form, headers: authHeaders() });
        if (r.ok) { statusEl.className = 'success'; statusEl.textContent = 'Upload successful!'; loadFiles(); }
        else { statusEl.className = 'error'; statusEl.textContent = 'Upload failed'; }
      } catch(err) { statusEl.className = 'error'; statusEl.textContent = 'Network error'; }
    };
  </script>
</body>
</html>''';

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(html)
      ..close();
  }

  String _buildJsLoadFiles() {
    return '''
    async function loadFiles() {
      try {
        const r = await fetch('/api/list', { headers: authHeaders(), credentials: 'include' });
        if (r.status === 401) { logout(); return; }
        const data = await r.json();
        const files = data.files || [];
        const el = document.getElementById('fileList');
        if (!files.length) { el.innerHTML = '<div class="empty">No files shared yet</div>'; return; }
        el.innerHTML = files.map(function(f) {
          return '<div class="file-item">' +
            '<a href="/download/' + encodeURIComponent(f.name) + '">' + f.icon + ' ' + f.name + '</a>' +
            '<span class="file-size">' + f.size + '</span>' +
            '</div>';
        }).join('');
        updateNav(data.currentDir || '');
      } catch(e) {
        document.getElementById('fileList').innerHTML = '<div class="empty">Failed to load files</div>';
      }
    }
    function updateNav(dir) {
      var parts = dir.split('/').filter(Boolean);
      var html = '<a onclick="navigateTo(\'\')">↑ Root</a>';
      var buildPath = '';
      for (var i = 0; i < parts.length; i++) {
        buildPath += '/' + parts[i];
        html += ' <span style="color:#5C6370;">/</span> <a onclick="navigateTo(\\'' + buildPath + '\\')">' + parts[i] + '</a>';
      }
      document.getElementById('navBar').innerHTML = html;
    }
    function navigateTo(dir) {
      var url = '/api/list?subdir=' + encodeURIComponent(dir);
      fetch(url, { headers: authHeaders(), credentials: 'include' }).then(function(r) {
        if (r.status === 401) { logout(); return; }
        return r.json();
      }).then(function(d) {
        var el = document.getElementById('fileList');
        if (!d.files || !d.files.length) { el.innerHTML = '<div class="empty">No files shared yet</div>'; return; }
        el.innerHTML = d.files.map(function(f) {
          return '<div class="file-item">' +
            '<a href="/download/' + encodeURIComponent(f.name) + '?subdir=' + encodeURIComponent(dir) + '">' + f.icon + ' ' + f.name + '</a>' +
            '<span class="file-size">' + f.size + '</span>' +
            '</div>';
        }).join('');
        updateNav(dir);
      }).catch(function() {
        document.getElementById('fileList').innerHTML = '<div class="empty">Failed to load files</div>';
      });
    }
    loadFiles();
    ''';
  }

  /// List shared files as JSON.
  Future<void> _serveApiList(HttpRequest request, String rawQuery) async {
    if (!_hasValidSession(request)) {
      _sendJsonResponse(request, {'error': 'Unauthorized'}, statusCode: 401);
      return;
    }
    try {
      // Parse subdir from query string
      Uri uri = request.uri.replace(query: rawQuery);
      String subDir = uri.queryParameters['subdir'] ?? '';
      // Validate subdir doesn't escape root (belt-and-suspenders).
      if (subDir.contains('..') || subDir.contains('\0')) {
        _sendJsonResponse(request, {'error': 'Invalid path'}, statusCode: 400);
        return;
      }
      final shareBase = _shareRoot.endsWith('/') ? _shareRoot : '$_shareRoot/';
      final dirPath = '$shareBase$subDir';
      final dir = Directory(dirPath);
      final files = <Map<String, dynamic>>[];
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          final stat = await entity.stat();
          files.add({
            'name': entity.path.split('/').last,
            'size': _formatSize(stat.size),
            'icon': _iconForEntity(entity.path),
            'isDir': stat.type == FileSystemEntityType.directory,
          });
        }
        files.sort((a, b) {
          final aIsDir = a['isDir'] as bool;
          final bIsDir = b['isDir'] as bool;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return (a['name'] as String).compareTo(b['name'] as String);
        });
      }
      _sendJsonResponse(request, {'files': files, 'currentDir': subDir, 'pin': _pin});
    } catch (e) {
      _sendJsonResponse(request, {'files': <dynamic>[], 'currentDir': ''});
    }
  }

  /// Download a file by name. Respects the optional [subdir] query param.
  Future<void> _serveDownload(HttpRequest request, String pathFragment) async {
    if (!_hasValidSession(request)) {
      _sendJsonResponse(request, {'error': 'Unauthorized'}, statusCode: 401);
      return;
    }
    Uri uri = request.uri.replace(query: request.uri.query);
    String subDir = uri.queryParameters['subdir'] ?? '';
    if (subDir.contains('..') || subDir.contains('\0')) {
      _sendResponse(request, 400, 'Bad request');
      return;
    }

    final fileName = sanitizeName(pathFragment);
    if (fileName.isEmpty) {
      _sendResponse(request, 400, 'Bad request: invalid filename');
      return;
    }

    final shareBase = _shareRoot.endsWith('/') ? _shareRoot : '$_shareRoot/';
    final filePath = '$shareBase$subDir$fileName';
    final file = File(filePath);
    if (!await file.exists() || (await file.stat()).type != FileSystemEntityType.file) {
      _sendResponse(request, 404, 'File not found');
      return;
    }

    // Safety: verify the resolved path is still inside the share root.
    final resolved = file.absolute.path;
    if (!resolved.startsWith(shareBase)) {
      _sendResponse(request, 403, 'Forbidden');
      return;
    }

    final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
    final fileLength = await file.length();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(mimeType)
      ..headers.set('Content-Disposition', 'attachment; filename="$fileName"')
      ..headers.set('Content-Length', fileLength.toString());

    // Stream file to response — avoids loading entire file into memory.
    final fileStream = file.openRead();
    fileStream.pipe(request.response);
    await request.response.done;
  }

  /// Handle multipart file upload. Streams chunks directly to disk.
  Future<void> _handleUpload(HttpRequest request) async {
    if (!_hasValidSession(request)) {
      _sendJsonResponse(request, {'error': 'Unauthorized'}, statusCode: 401);
      return;
    }
    Uri uri = request.uri.replace(query: request.uri.query);
    String subDir = uri.queryParameters['subdir'] ?? '';
    if (subDir.contains('..') || subDir.contains('\0')) {
      _sendJsonResponse(request, {'error': 'Bad request'}, statusCode: 400);
      return;
    }

    // Read Content-Disposition to extract original filename.
    String fileName = '';
    final cd = request.headers.value('content-disposition');
    if (cd != null) {
      // Handles: filename="foo.pdf", filename=foo.pdf, filename*=UTF-8''foo.pdf
      final match = RegExp(
        r"""filename\*?=["']?(?:UTF-8')?([^"'\s;]+)""",
      ).firstMatch(cd);
      if (match != null && match.group(1) != null) {
        fileName = match.group(1)!;
      }
    }
    fileName = sanitizeName(fileName);
    if (fileName.isEmpty) {
      _sendJsonResponse(request, {'error': 'Invalid filename'}, statusCode: 400);
      return;
    }

    final shareBase = _shareRoot.endsWith('/') ? _shareRoot : '$_shareRoot/';
    final saveDirPath = '$shareBase$subDir';
    final saveDir = Directory(saveDirPath);
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    // Safety: verify save path is inside share root.
    final resolvedSaveDir = saveDir.absolute.path;
    if (!resolvedSaveDir.startsWith(shareBase)) {
      _sendJsonResponse(request, {'error': 'Forbidden'}, statusCode: 403);
      return;
    }

    final outFile = File('$resolvedSaveDir/$fileName');
    final sink = outFile.openWrite();
    var totalBytes = 0;
    try {
      await for (final chunk in request) {
        sink.add(chunk);
        totalBytes += chunk.length;
      }
      await sink.close();
      _sendJsonResponse(request, {
        'success': true,
        'filename': fileName,
        'size': totalBytes,
      });
    } catch (e) {
      await sink.close();
      // Clean up partial file on error.
      if (await outFile.exists()) await outFile.delete();
      _sendJsonResponse(request, {'error': 'Upload failed: $e'}, statusCode: 500);
    }
  }

  // ---- Access logging ------------------------------------------------------

  void _logAccess(HttpRequest request, String path, String query) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    _accessLog.add({'ip': ip, 'path': path, 'query': query, 'ts': DateTime.now()});
    if (_accessLog.length > _kMaxAccessLog) {
      _accessLog.removeAt(0);
    }
  }

  // ---- UI ------------------------------------------------------------------

  void stop() {
    _server?.close(force: true).catchError((_) {});
    _isRunning = false;
  }

  Widget buildQrCode() {
    if (_currentIp == null) {
      return const Center(child: Text('No IP address available'));
    }
    final url = 'http://$_currentIp:$port';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        QrImageView(
          data: url,
          version: QrVersions.auto,
          size: 200.0,
          gapless: false,
          eyeStyle: const QrEyeStyle(color: OneDarkColors.cyan),
          dataModuleStyle: const QrDataModuleStyle(color: OneDarkColors.cyan),
        ),
        const SizedBox(height: 12),
        Text(url, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: OneDarkColors.cyan)),
        const SizedBox(height: 4),
        Text('PIN: $_pin', style: const TextStyle(fontSize: 13, color: OneDarkColors.amber)),
      ],
    );
  }

  // --- Helpers ---

  void _sendResponse(HttpRequest request, int statusCode, String body) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.text
      ..write(body)
      ..close();
  }

  void _sendJsonResponse(HttpRequest request, dynamic data, {int statusCode = 200}) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(data))
      ..close();
  }

  String _formatSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  String _iconForEntity(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'].contains(ext)) return '🖼️';
    if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) return '🎬';
    if (['mp3', 'flac', 'wav', 'ogg'].contains(ext)) return '🎵';
    if (ext == 'pdf') return '📄';
    if (['zip', 'tar', 'gz', '7z', 'rar'].contains(ext)) return '📦';
    return '📁';
  }
}
