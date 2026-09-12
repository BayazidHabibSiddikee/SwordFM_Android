import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
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

// ---------------------------------------------------------------------------
// mDNS / LAN discovery beacon
// ---------------------------------------------------------------------------

/// Advertises the SwordFM web share service on the local network via two
/// complementary mechanisms:
///
/// 1. **mDNS PTR record** (primary) — sends a minimal DNS response packet to
///    the multicast group `224.0.0.251:5353` every 30 s so that standard
///    mDNS-aware clients (Bonjour, Avahi, Android NSD) can discover the
///    service under `SwordFM._http._tcp.local`.
///
/// 2. **JSON UDP broadcast** (fallback) — sends a plain JSON datagram to the
///    directed broadcast address `255.255.255.255:5350` every 30 s so that
///    custom SwordFM clients on the same LAN can discover the server without
///    requiring multicast routing.
///
/// Both announcements are sent together; if either socket fails to bind (e.g.
/// permission denied on the emulator) it is silently ignored so the other
/// mechanism still operates.
class _MdnsBeacon {
  static const _mdnsAddress = '224.0.0.251';
  static const _mdnsPort = 5353;
  static const _discoveryPort = 5350;
  static const _serviceName = 'SwordFM';
  static const _interval = Duration(seconds: 30);

  Timer? _timer;
  RawDatagramSocket? _mdnsSocket;
  RawDatagramSocket? _broadcastSocket;

  /// Start periodic announcements with server metadata.
  Future<void> startWithInfo(String pin, String ip, int serverPort) async {
    _serverIp = ip;
    _serverPort = serverPort;
    await start(pin);
  }

  String? _serverIp;
  int _serverPort = 8080;

  /// Start periodic announcements.  [pin] is included in the JSON broadcast
  /// so clients know a PIN is required (the PIN itself is not sent).
  Future<void> start(String pin) async {
    await stop(); // clean up any previous run

    // --- (1) mDNS multicast socket ----------------------------------------
    try {
      _mdnsSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0, // ephemeral source port — we only send, never receive
        reuseAddress: true,
        reusePort: false,
      );
      _mdnsSocket!.multicastLoopback = false;
      // Join the multicast group so the OS picks an interface for outgoing
      // multicast packets (not strictly required for *sending* but good practice).
      _mdnsSocket!.joinMulticast(InternetAddress(_mdnsAddress));
    } catch (e) {
      debugPrint('[MdnsBeacon] mDNS socket init failed (non-fatal): $e');
      _mdnsSocket?.close();
      _mdnsSocket = null;
    }

    // --- (2) Broadcast socket for JSON discovery --------------------------
    try {
      _broadcastSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: false,
      );
      _broadcastSocket!.broadcastEnabled = true;
    } catch (e) {
      debugPrint('[MdnsBeacon] Broadcast socket init failed (non-fatal): $e');
      _broadcastSocket?.close();
      _broadcastSocket = null;
    }

    // Send immediately, then every 30 s.
    _announce(pin);
    _timer = Timer.periodic(_interval, (_) => _announce(pin));
  }

  /// Stop announcements and release sockets.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      _mdnsSocket?.close();
    } catch (_) {}
    _mdnsSocket = null;
    try {
      _broadcastSocket?.close();
    } catch (_) {}
    _broadcastSocket = null;
  }

  // --------------------------------------------------------------------------

  void _announce(String pin) {
    _sendMdnsAnnouncement();
    _sendJsonBroadcast(pin);
  }

  /// Send a minimal mDNS response containing one PTR record:
  ///   _http._tcp.local  PTR  SwordFM._http._tcp.local
  ///
  /// Packet layout (all big-endian):
  ///   Header (12 bytes): ID=0, flags=0x8400, QDCount=0, ANCount=1,
  ///                      NSCount=0, ARCount=0
  ///   PTR record:
  ///     NAME  : encoded label sequence for "_http._tcp.local"
  ///     TYPE  : 0x000C  (PTR)
  ///     CLASS : 0x0001  (IN)
  ///     TTL   : 120
  ///     RDATA : encoded label sequence for "SwordFM._http._tcp.local"
  void _sendMdnsAnnouncement() {
    if (_mdnsSocket == null) return;
    try {
      final packet = _buildMdnsPacket();
      _mdnsSocket!.send(
        packet,
        InternetAddress(_mdnsAddress),
        _mdnsPort,
      );
    } catch (e) {
      debugPrint('[MdnsBeacon] mDNS send error (non-fatal): $e');
    }
  }

  /// Encode a dot-separated DNS name as a sequence of length-prefixed labels
  /// terminated by a zero byte, e.g. "_http._tcp.local" →
  ///   [5, '_','h','t','t','p', 4, '_','t','c','p', 5, 'l','o','c','a','l', 0]
  static Uint8List _encodeName(String name) {
    final out = BytesBuilder();
    for (final label in name.split('.')) {
      final bytes = utf8.encode(label);
      out.addByte(bytes.length);
      out.add(bytes);
    }
    out.addByte(0); // root label
    return out.toBytes();
  }

  static Uint8List _buildMdnsPacket() {
    final serviceDomain = '_http._tcp.local';
    final serviceInstance = '$_serviceName._http._tcp.local';

    final nameBytes = _encodeName(serviceDomain);
    final rdataBytes = _encodeName(serviceInstance);

    final buf = BytesBuilder();

    // --- DNS header (12 bytes) ---
    // ID = 0
    buf.addByte(0x00);
    buf.addByte(0x00);
    // Flags = 0x8400 (QR=1 response, AA=1 authoritative)
    buf.addByte(0x84);
    buf.addByte(0x00);
    // QDCount = 0
    buf.addByte(0x00);
    buf.addByte(0x00);
    // ANCount = 1
    buf.addByte(0x00);
    buf.addByte(0x01);
    // NSCount = 0
    buf.addByte(0x00);
    buf.addByte(0x00);
    // ARCount = 0
    buf.addByte(0x00);
    buf.addByte(0x00);

    // --- PTR answer record ---
    // NAME: encoded _http._tcp.local
    buf.add(nameBytes);
    // TYPE = 12 (PTR)
    buf.addByte(0x00);
    buf.addByte(0x0C);
    // CLASS = 1 (IN)
    buf.addByte(0x00);
    buf.addByte(0x01);
    // TTL = 120 seconds (0x00000078)
    buf.addByte(0x00);
    buf.addByte(0x00);
    buf.addByte(0x00);
    buf.addByte(0x78);
    // RDLENGTH = length of rdataBytes
    final rdLen = rdataBytes.length;
    buf.addByte((rdLen >> 8) & 0xFF);
    buf.addByte(rdLen & 0xFF);
    // RDATA: encoded SwordFM._http._tcp.local
    buf.add(rdataBytes);

    return buf.toBytes();
  }

  /// Send a JSON UDP broadcast so custom SwordFM clients can auto-discover
  /// without needing mDNS support.
  ///
  /// Payload: {"name":"SwordFM","port":8080,"pin_required":true}
  void _sendJsonBroadcast(String pin) {
    if (_broadcastSocket == null) return;
    try {
      final payload = jsonEncode({
        'app': 'SwordFM',
        'name': _serviceName,
        'ip': _serverIp,
        'port': _serverPort,
        'pin_required': pin.isNotEmpty,
      });
      final data = utf8.encode(payload);
      _broadcastSocket!.send(
        data,
        InternetAddress('255.255.255.255'),
        _discoveryPort,
      );
    } catch (e) {
      debugPrint('[MdnsBeacon] JSON broadcast send error (non-fatal): $e');
    }
  }
}

// ---------------------------------------------------------------------------

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
  /// TCP port the web server listens on. Defaults to 8080 (matching the
  /// Linux SwordFM share); tests inject a free port.
  final int port;

  WebShareServer({this.port = 8080});

  HttpServer? _server;
  final NetworkInfo _networkInfo = NetworkInfo();
  final _MdnsBeacon _beacon = _MdnsBeacon();

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

  // --- Auth rate-limit state (per client IP) --------------------------------
  final Map<String, int> _authFailures = {};
  final Map<String, DateTime> _authBlockedUntil = {};

  // --- Client access log (ring buffer) --------------------------------------
  final List<Map<String, dynamic>> _accessLog = [];

  /// Public view of the client-access log (read-only copy).
  List<Map<String, dynamic>> get accessLog => List.from(_accessLog);

  String? get currentIp => _currentIp;
  bool get isRunning => _isRunning;
  String get pin => _pin;
  String get shareRoot => _shareRoot;

  /// Generate a random 6-digit PIN for client authorization (CSPRNG).
  String _generatePin() {
    final r = Random.secure();
    return (100000 + r.nextInt(900000)).toString();
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
      // Fallback: scan network interfaces if WiFi IP is null (e.g. hotspot, USB)
      if (_currentIp == null) {
        _currentIp = await _getLocalIp();
      }
      if (_currentIp == null) return null;

      _shareRoot = shareRootOverride ?? '${AppPaths.downloads}/SwordFM';
      _pin = _generatePin();
      _sessions.clear();
      _accessLog.clear();

      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;
      unawaited(_beacon.startWithInfo(_pin, _currentIp!, port));

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
              await _serveDownload(
                request,
                path.substring(('/download/').length),
              );
            } else if (path.startsWith('/api/list')) {
              await _serveApiList(request, rawQuery);
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
          _sendResponse(request, 500, 'Internal Server Error');
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
    final r = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => r.nextInt(256));
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
    if (name.length > _kMaxSafeNameLen)
      name = name.substring(0, _kMaxSafeNameLen);
    return name;
  }

  // ---- Request handlers ----------------------------------------------------

  Future<void> _handleAuth(HttpRequest request) async {
    // Rate-limit PIN guesses per client IP: 5 failures → 30s lockout.
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final now = DateTime.now();
    final blockedUntil = _authBlockedUntil[ip];
    if (blockedUntil != null && now.isBefore(blockedUntil)) {
      _sendJsonResponse(request, {'error': 'Too many attempts, try later'},
          statusCode: 429);
      return;
    }
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
      final fails = (_authFailures[ip] ?? 0) + 1;
      _authFailures[ip] = fails;
      if (fails >= 5) {
        _authBlockedUntil[ip] = now.add(const Duration(seconds: 30));
        _authFailures[ip] = 0;
      }
      _sendJsonResponse(request, {'error': 'Invalid pin'}, statusCode: 401);
      return;
    }
    _authFailures.remove(ip);
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
    final html =
        '''<!DOCTYPE html>
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
    // HTML-escape all user-controlled strings before inserting into innerHTML.
    // Prevents stored XSS from filenames, icons, sizes, or directory parts.
    function esc(s) {
      return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#x27;');
    }
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
            '<a href="/download/' + encodeURIComponent(f.name) + '">' + esc(f.icon) + ' ' + esc(f.name) + '</a>' +
            '<span class="file-size">' + esc(f.size) + '</span>' +
            '</div>';
        }).join('');
        updateNav(data.currentDir || '');
      } catch(e) {
        document.getElementById('fileList').innerHTML = '<div class="empty">Failed to load files</div>';
      }
    }
    function updateNav(dir) {
      var parts = dir.split('/').filter(Boolean);
      var html = '<a onclick="navigateTo(\\'\\')">&#x2191; Root</a>';
      var buildPath = '';
      for (var i = 0; i < parts.length; i++) {
        buildPath += '/' + parts[i];
        var safePath = encodeURIComponent(buildPath);
        html += ' <span style="color:#5C6370;">/</span> <a onclick="navigateTo(decodeURIComponent(' + JSON.stringify(buildPath) + '))">' + esc(parts[i]) + '</a>';
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
            '<a href="/download/' + encodeURIComponent(f.name) + '?subdir=' + encodeURIComponent(dir) + '">' + esc(f.icon) + ' ' + esc(f.name) + '</a>' +
            '<span class="file-size">' + esc(f.size) + '</span>' +
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
      if (subDir.contains('..') || subDir.contains(String.fromCharCode(0))) {
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
      _sendJsonResponse(request, {
        'files': files,
        'currentDir': subDir,
      });
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
    if (subDir.contains('..') || subDir.contains(String.fromCharCode(0))) {
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
    if (!await file.exists() ||
        (await file.stat()).type != FileSystemEntityType.file) {
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
    if (subDir.contains('..') || subDir.contains(String.fromCharCode(0))) {
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
      _sendJsonResponse(request, {
        'error': 'Invalid filename',
      }, statusCode: 400);
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
      debugPrint('WebShareServer upload failed: $e');
      _sendJsonResponse(request, {
        'error': 'Upload failed',
      }, statusCode: 500);
    }
  }

  // ---- Access logging ------------------------------------------------------

  void _logAccess(HttpRequest request, String path, String query) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    // Never log the query string: it can carry PINs/tokens. Keep path only.
    _accessLog.add({
      'ip': ip,
      'path': path,
      'query': '',
      'ts': DateTime.now(),
    });
    if (_accessLog.length > _kMaxAccessLog) {
      _accessLog.removeAt(0);
    }
  }

  // ---- UI ------------------------------------------------------------------

  /// Fallback IP detection when NetworkInfo.getWifiIP() returns null
  /// (hotspot, USB tethering, non-WiFi networks).
  static Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback &&
              (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
      // Last resort: any non-loopback IPv4
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void stop() {
    _server?.close(force: true).catchError((_) {});
    _isRunning = false;
    _beacon.stop();
  }

  Widget buildQrCode() {
    if (_currentIp == null) {
      return const Center(child: Text('No IP address available'));
    }
    final url = 'http://$_currentIp:$port';
    // Just the QR — the URL and PIN are already shown in the status card
    // above the code, so duplicating them here only crowds the layout.
    return QrImageView(
      data: url,
      version: QrVersions.auto,
      size: 200.0,
      gapless: false,
      eyeStyle: QrEyeStyle(color: OneDarkColors.cyan),
      dataModuleStyle: QrDataModuleStyle(color: OneDarkColors.cyan),
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

  void _sendJsonResponse(
    HttpRequest request,
    dynamic data, {
    int statusCode = 200,
  }) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(data))
      ..close();
  }

  String _formatSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024)
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  String _iconForEntity(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'].contains(ext))
      return '🖼️';
    if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) return '🎬';
    if (['mp3', 'flac', 'wav', 'ogg'].contains(ext)) return '🎵';
    if (ext == 'pdf') return '📄';
    if (['zip', 'tar', 'gz', '7z', 'rar'].contains(ext)) return '📦';
    return '📁';
  }
}
