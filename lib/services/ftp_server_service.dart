import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;

/// Minimal FTP server for transferring files between the phone and a PC over
/// the local network. Chrooted to a share root; no real authentication
/// (any user/pass is accepted — the LAN is trusted, like the WebShareServer).
class FtpServerService {
  final int port;
  final NetworkInfo _networkInfo = NetworkInfo();

  ServerSocket? _server;
  String? currentIp;
  String shareRoot = '/storage/emulated/0';

  bool get isRunning => _server != null;

  /// PIN required to authenticate. Empty string = no auth (legacy).
  String sharePin = '';

  /// The actually-bound port (differs from [port] when 0 = ephemeral).
  int get boundPort => _server?.port ?? port;

  FtpServerService({this.port = 2121});

  /// Starts listening. [shareRootOverride] sets the browsable root.
  Future<void> start({String? shareRootOverride}) async {
    if (shareRootOverride != null) shareRoot = shareRootOverride;
    if (_server != null) return;
    currentIp = await _networkInfo.getWifiIP();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleConnection);
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  void _handleConnection(Socket socket) {
    unawaited(_serve(socket));
  }

  Future<void> _serve(Socket control) async {
    final session = _FtpSession(control, this);
    var buffer = '';
    control.timeout(const Duration(minutes: 10));
    try {
      control.add(utf8.encode('220 SwordFM FTP server ready.\r\n'));
      await for (final chunk in control) {
        buffer += String.fromCharCodes(chunk);
        while (buffer.contains('\r\n')) {
          final idx = buffer.indexOf('\r\n');
          final line = buffer.substring(0, idx);
          buffer = buffer.substring(idx + 2);
          final reply = await session.handle(line);
          if (reply == null) {
            // QUIT — close the session.
            return;
          }
          control.add(utf8.encode(reply));
        }
      }
    } catch (_) {
      // Client dropped / idle timeout.
    } finally {
      await session.dispose();
    }
  }
}

class _FtpSession {
  final Socket control;
  final FtpServerService service;
  String cwd = '/';
  bool binary = true;
  ServerSocket? passive;
  Future<Socket>? dataFuture;
  String? rnfrPath;

  _FtpSession(this.control, this.service);

  Future<void> dispose() async {
    await passive?.close();
  }

  String get _root => service.shareRoot;

  /// Resolves an FTP path (absolute or relative to cwd) to a physical path,
  /// returning null when it escapes the share root.
  String? resolve(String arg) {
    final raw = arg.startsWith('/') ? arg : p.posix.join(cwd, arg);
    final normalized = p.posix.normalize(raw);
    if (normalized.contains('\u0000')) return null;
    // p.join resets the base on absolute segments, so strip the leading '/'
    // to keep every path anchored under the share root (chroot).
    final rel = normalized.startsWith('/')
        ? normalized.substring(1)
        : normalized;
    final physical = p.join(_root, rel);
    if (p.isWithin(_root, physical) || physical == _root) return physical;
    return null;
  }

  /// Sends [code] with [message], then accepts the passive data connection.
  Future<Socket?> openData(String code, String message) async {
    if (dataFuture == null) return null;
    control.add(utf8.encode('$code $message\r\n'));
    try {
      final data = await dataFuture!.timeout(const Duration(seconds: 15));
      dataFuture = null;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<String?> handle(String line) async {
    final space = line.indexOf(' ');
    final cmd = (space < 0 ? line : line.substring(0, space)).toUpperCase();
    final arg = space < 0 ? '' : line.substring(space + 1).trim();
    switch (cmd) {
      case 'USER':
        return '331 Password required.\r\n';
      case 'PASS':
        if (sharePin.isNotEmpty && arg != sharePin) {
          return '530 Login incorrect.\r\n';
        }
        return '230 Logged in.\r\n';
      case 'SYST':
        return '215 UNIX Type: L8\r\n';
      case 'FEAT':
        return '211-Features:\r\n SIZE\r\n MDTM\r\n MLST type*;size*;modify*;\r\n UTF8\r\n PASV\r\n EPSV\r\n211 End\r\n';
      case 'OPTS':
        return '200 OK\r\n';
      case 'TYPE':
        binary = arg.toUpperCase() == 'I';
        return '200 Type set.\r\n';
      case 'PWD':
      case 'XPWD':
        return '257 "$cwd"\r\n';
      case 'CWD':
        final path = resolve(arg);
        if (path == null) return '550 Invalid path.\r\n';
        if (!Directory(path).existsSync()) return '550 No such directory.\r\n';
        cwd = p.posix.normalize(
          arg.startsWith('/') ? arg : p.posix.join(cwd, arg),
        );
        return '250 Directory changed.\r\n';
      case 'CDUP':
        cwd = p.posix.dirname(cwd);
        return '250 Directory changed.\r\n';
      case 'PASV':
        await passive?.close();
        final srv = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
        passive = srv;
        dataFuture = srv.first;
        final ip = control.address.address.replaceAll('.', ',').replaceAll(':', ',');
        final port = srv.port;
        return '227 Entering Passive Mode ($ip,${port >> 8},${port & 255})\r\n';
      case 'EPSV':
        await passive?.close();
        final srv = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
        passive = srv;
        dataFuture = srv.first;
        return '229 Entering Extended Passive Mode (|||${srv.port}|)\r\n';
      case 'LIST':
      case 'NLST':
      case 'MLSD':
        return _list(cmd, arg);
      case 'RETR':
        return _retr(arg);
      case 'STOR':
        return _stor(arg);
      case 'DELE':
        return _dele(arg);
      case 'MKD':
        final path = resolve(arg);
        if (path == null) return '550 Invalid path.\r\n';
        try {
          Directory(path).createSync(recursive: true);
          return '257 Directory created.\r\n';
        } catch (_) {
          return '550 Could not create.\r\n';
        }
      case 'RMD':
        final path = resolve(arg);
        if (path == null) return '550 Invalid path.\r\n';
        try {
          Directory(path).deleteSync(recursive: true);
          return '250 Directory removed.\r\n';
        } catch (_) {
          return '550 Could not remove.\r\n';
        }
      case 'RNFR':
        rnfrPath = resolve(arg);
        return rnfrPath == null ? '550 Invalid path.\r\n' : '350 Ready for RNTO.\r\n';
      case 'RNTO':
        if (rnfrPath == null) return '503 Bad sequence.\r\n';
        final dst = resolve(arg);
        if (dst == null) return '550 Invalid path.\r\n';
        try {
          File(rnfrPath!).renameSync(dst);
          rnfrPath = null;
          return '250 Rename successful.\r\n';
        } catch (_) {
          return '550 Rename failed.\r\n';
        }
      case 'SIZE':
        final path = resolve(arg);
        if (path == null || !File(path).existsSync()) return '550 Not found.\r\n';
        return '213 ${File(path).lengthSync()}\r\n';
      case 'MDTM':
        final path = resolve(arg);
        if (path == null || !File(path).existsSync()) return '550 Not found.\r\n';
        final t = File(path).lastModifiedSync().toUtc();
        String two(int v) => v.toString().padLeft(2, '0');
        return '213 ${t.year}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}\r\n';
      case 'ABOR':
        await passive?.close();
        passive = null;
        dataFuture = null;
        return '226 Abort successful.\r\n';
      case 'NOOP':
        return '200 OK\r\n';
      case 'QUIT':
        return '221 Goodbye.\r\n';
      default:
        return '500 Command not understood.\r\n';
    }
  }

  Future<String?> _list(String cmd, String arg) async {
    final path = arg.isEmpty
        ? resolve(cwd)
        : resolve(arg.startsWith('/') ? arg : p.posix.join(cwd, arg));
    if (path == null) return '550 Invalid path.\r\n';
    final dir = Directory(path);
    if (!dir.existsSync()) return '550 No such directory.\r\n';

    final data = await openData('150', 'Opening data connection.');
    if (data == null) return '425 Can\'t open data connection.\r\n';

    try {
      final entities = dir.listSync();
      final sb = StringBuffer();
      for (final e in entities) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        final isDir = e is Directory;
        final stat = e.statSync();
        final t = stat.modified.toUtc();
        String two(int v) => v.toString().padLeft(2, '0');
        final mod = '${t.year}${two(t.month)}${two(t.day)}'
            '${two(t.hour)}${two(t.minute)}${two(t.second)}';
        if (cmd == 'MLSD') {
          sb.writeln(
            'type=${isDir ? 'dir' : 'file'};size=${stat.size};'
            'modify=$mod; $name',
          );
        } else if (cmd == 'NLST') {
          sb.writeln(name);
        } else {
          // Traditional LIST: -rw-r--r-- owner group size MMM DD HH:MM name
          const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul',
            'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
          final perms = isDir ? 'drwxr-xr-x' : '-rw-r--r--';
          final size = stat.size.toString().padLeft(12);
          sb.writeln(
            '$perms 1 owner group $size ${months[t.month - 1]} '
            '${two(t.day)} ${two(t.hour)}:${two(t.minute)} $name',
          );
        }
      }
      data.add(utf8.encode(sb.toString()));
      await data.flush();
      await data.close();
      return '226 Transfer complete.\r\n';
    } catch (_) {
      try {
        await data.close();
      } catch (_) {}
      return '426 Transfer aborted.\r\n';
    }
  }

  Future<String?> _retr(String arg) async {
    final path = resolve(arg);
    if (path == null) return '550 Invalid path.\r\n';
    final file = File(path);
    if (!file.existsSync()) return '550 No such file.\r\n';

    final data = await openData('150', 'Opening data connection.');
    if (data == null) return '425 Can\'t open data connection.\r\n';

    try {
      final raf = file.openSync();
      try {
        final chunk = List<int>.filled(65536, 0);
        int n;
        while ((n = raf.readIntoSync(chunk)) > 0) {
          data.add(chunk.sublist(0, n));
        }
      } finally {
        raf.closeSync();
      }
      await data.flush();
      await data.close();
      return '226 Transfer complete.\r\n';
    } catch (_) {
      try {
        await data.close();
      } catch (_) {}
      return '426 Transfer aborted.\r\n';
    }
  }

  Future<String?> _stor(String arg) async {
    final path = resolve(arg);
    if (path == null) return '550 Invalid path.\r\n';

    final data = await openData('150', 'Opening data connection.');
    if (data == null) return '425 Can\'t open data connection.\r\n';

    try {
      final file = File(path);
      await file.create(recursive: true);
      final sink = file.openWrite();
      await for (final chunk in data) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      return '226 Transfer complete.\r\n';
    } catch (_) {
      try {
        await data.close();
      } catch (_) {}
      return '426 Transfer aborted.\r\n';
    }
  }

  Future<String?> _dele(String arg) async {
    final path = resolve(arg);
    if (path == null) return '550 Invalid path.\r\n';
    try {
      File(path).deleteSync();
      return '250 File deleted.\r\n';
    } catch (_) {
      return '550 Could not delete.\r\n';
    }
  }
}
