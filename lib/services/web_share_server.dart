import 'dart:convert';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import '../utils/file_utils.dart';
import '../theme/theme.dart';

/// A pure-Dart LAN file sharing server for SwordFM Android.
/// Generates a QR code so nearby devices can browse/download/upload files.
class WebShareServer {
  HttpServer? _server;
  final NetworkInfo _networkInfo = NetworkInfo();

  String? _currentIp;
  bool _isRunning = false;
  late String _pin;

  String? get currentIp => _currentIp;
  bool get isRunning => _isRunning;
  String get pin => _pin;

  static const int port = 8080;

  /// Generate a random 6-digit PIN for client authorization.
  String _generatePin() {
    return (100000 + DateTime.now().millisecondsSinceEpoch % 900000).toString();
  }

  Future<String?> start() async {
    try {
      _currentIp = await _networkInfo.getWifiIP();
      if (_currentIp == null) return null;

      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;
      _pin = _generatePin();

      _server!.listen((HttpRequest request) async {
        try {
          final path = request.uri.path;

          if (request.method == 'GET') {
            if (path == '/' || path == '/index.html') {
              await _serveHomePage(request);
            } else if (path.startsWith('/download/')) {
              await _serveDownload(request, path.substring(('/download/').length));
            } else if (path.startsWith('/api/list')) {
              await _serveApiList(request);
            } else if (path == '/api/pin') {
              _sendJsonResponse(request, {'pin': _pin});
            } else {
              _sendResponse(request, 404, 'Not Found');
            }
          } else if (request.method == 'POST') {
            if (path == '/upload' || path == '/api/upload') {
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

  Future<void> _serveHomePage(HttpRequest request) async {
    // Build JS dynamically to avoid Dart/$$conflicts with embedded JS template literals
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
    .header { background: #21252B; padding: 16px 20px; border-bottom: 1px solid #3E4451; }
    .header h1 { color: #61AFEF; font-size: 20px; }
    .header p { color: #5C6370; font-size: 12px; margin-top: 4px; }
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
  </style>
</head>
<body>
  <div class="header">
    <h1>SwordFM Share</h1>
    <p>Browse, download, and upload files on your local network</p>
  </div>
  <div class="container">
    <div class="pin-banner">
      <span>Authorization PIN:</span>
      <code id="pin">—</code>
    </div>

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

  <script>
    // Fetch PIN
    fetch('/api/pin').then(r => r.json()).then(d => document.getElementById('pin').textContent = d.pin);

    $jsLoadFiles

    // Show selected file name
    function showSelected(input) {
      const names = Array.from(input.files).map(f => f.name).join(', ');
      document.getElementById('selectedFile').textContent = names;
    }

    // Handle upload
    document.getElementById('uploadForm').onsubmit = async (e) => {
      e.preventDefault();
      const form = new FormData(e.target);
      const statusEl = document.getElementById('status');
      statusEl.className = ''; statusEl.style.display = 'block'; statusEl.textContent = 'Uploading...';
      try {
        const r = await fetch('/api/upload', { method: 'POST', body: form });
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

  /// Builds the loadFiles() JS function without using ${} inside a Dart string
  /// that would trigger Dart interpolation.
  String _buildJsLoadFiles() {
    return '''
    async function loadFiles() {
      try {
        const r = await fetch('/api/list');
        const files = await r.json();
        const el = document.getElementById('fileList');
        if (!files.length) { el.innerHTML = '<div class="empty">No files shared yet</div>'; return; }
        el.innerHTML = files.map(function(f) {
          return '<div class="file-item">' +
            '<a href="/download/' + encodeURIComponent(f.name) + '">' + f.icon + ' ' + f.name + '</a>' +
            '<span class="file-size">' + f.size + '</span>' +
            '</div>';
        }).join('');
      } catch(e) {
        document.getElementById('fileList').innerHTML = '<div class="empty">Failed to load files</div>';
      }
    }
    loadFiles();
    ''';
  }

  /// List shared files as JSON.
  Future<void> _serveApiList(HttpRequest request) async {
    try {
      final dir = Directory('${AppPaths.downloads}/SwordFM');
      final files = <Map<String, dynamic>>[];
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          final stat = await entity.stat();
          files.add({
            'name': entity.path.split('/').last,
            'size': _formatSize(stat.size),
            'icon': _iconForEntity(entity.path),
          });
        }
      }
      _sendJsonResponse(request, files);
    } catch (e) {
      _sendJsonResponse(request, <dynamic>[]);
    }
  }

  /// Download a file by name.
  Future<void> _serveDownload(HttpRequest request, String fileName) async {
    final filePath = '${AppPaths.downloads}/SwordFM/$fileName';
    final file = File(filePath);
    if (!await file.exists()) {
      _sendResponse(request, 404, 'File not found');
      return;
    }
    final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
    final bytes = await file.readAsBytes();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(mimeType)
      ..headers.set('Content-Disposition', 'attachment; filename="$fileName"')
      ..add(bytes)
      ..close();
  }

  /// Handle multipart file upload.
  Future<void> _handleUpload(HttpRequest request) async {
    try {
      final bytes = await request.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      if (bytes.isEmpty) {
        _sendResponse(request, 400, 'No data received');
        return;
      }

      String fileName = 'uploaded_${DateTime.now().millisecondsSinceEpoch}.bin';
      final cd = request.headers.value('content-disposition');
      if (cd != null) {
        final match = RegExp(r'filename="([^"]+)"').firstMatch(cd);
        if (match != null) fileName = match.group(1)!;
      }

      final saveDir = Directory('${AppPaths.downloads}/SwordFM');
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final outFile = File('${saveDir.path}/$fileName');
      await outFile.writeAsBytes(bytes);

      _sendJsonResponse(request, {'success': true, 'filename': fileName, 'size': bytes.length});
    } catch (e) {
      _sendResponse(request, 500, 'Upload failed: $e');
    }
  }

  void stop() {
    _server?.close();
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

  void _sendJsonResponse(HttpRequest request, dynamic data) {
    request.response
      ..statusCode = HttpStatus.ok
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
    if (['png','jpg','jpeg','gif','webp','bmp','svg'].contains(ext)) return '🖼️';
    if (['mp4','mkv','mov','avi'].contains(ext)) return '🎬';
    if (['mp3','flac','wav','ogg'].contains(ext)) return '🎵';
    if (ext == 'pdf') return '📄';
    if (['zip','tar','gz','7z','rar'].contains(ext)) return '📦';
    return '📁';
  }
}
