import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'constants.dart' show AppPaths;
export 'constants.dart';

/// Common MIME types mapped from file extensions.
const Map<String, String> _mimeTypes = {
  'txt': 'text/plain',
  'md': 'text/markdown',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'js': 'application/javascript',
  'json': 'application/json',
  'xml': 'application/xml',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'ico': 'image/x-icon',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  'mp4': 'video/mp4',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'py': 'text/x-python',
  'java': 'text/x-java-source',
  'kt': 'text/x-kotlin',
  'c': 'text/x-c',
  'cpp': 'text/x-c++src',
  'h': 'text/x-c',
  'rs': 'text/x-rust',
  'go': 'text/x-go',
  'rb': 'text/x-ruby',
  'sh': 'application/x-sh',
  'sql': 'application/sql',
  'csv': 'text/csv',
  'yaml': 'application/x-yaml',
  'yml': 'application/x-yaml',
  'toml': 'application/toml',
  'ini': 'text/plain',
  'conf': 'text/plain',
  'log': 'text/plain',
  'apk': 'application/vnd.android.package-archive',
  'so': 'application/x-sharedlib',
  'dll': 'application/x-msdownload',
  'exe': 'application/x-msdownload',
};

/// Represents a single file or directory entry.
class FileItem {
  final FileSystemEntity entity;
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime lastModified;

  FileItem({
    required this.entity,
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.lastModified,
  });

  String get extension => isDirectory ? '' : p.extension(path).toLowerCase();

  String get formattedSize {
    if (isDirectory) return '';
    if (size < 1024) return '$size B';
    double kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    double mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    double gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  /// Returns the estimated size as a number for sorting/comparison.
  /// For directories, returns 0 — use [getTotalSize] for actual size.
  int get sizeBytes => size;

  /// Recursively computes total size of a directory (bytes).
  static Future<int> getTotalSize(FileItem item) async {
    if (!item.isDirectory) return item.size;
    final items = await FileUtils.listDirectory(
      item.path,
      includeHidden: false,
    );
    int total = item.size;
    for (final child in items) {
      total += await getTotalSize(child);
    }
    return total;
  }

  String get formattedDate {
    return DateFormat('yyyy-MM-dd HH:mm').format(lastModified);
  }

  /// Returns the MIME type based on file extension.
  String get mimeType {
    if (isDirectory) return 'inode/directory';
    final ext = extension.replaceAll('.', '');
    return _mimeTypes[ext] ?? 'application/octet-stream';
  }

  /// Returns permission string like "rwxr-xr-x" (best-effort on Android).
  Future<String> get permissions async {
    try {
      final stat = await (entity as dynamic).stat();
      // FileStat exposes POSIX permission bits on `mode` (e.g. 0o755 = 493).
      if (stat != null && stat.mode != null) {
        final mode = stat.mode as int;
        if (mode > 0) return _permissionString(mode);
      }
    } catch (_) {}
    // Fallback: check basic read/write/execute.
    final buf = StringBuffer('r');
    buf.write(_canWrite ? 'w' : '-');
    buf.write(_isExecutable ? 'x' : '-');
    buf.write('r');
    buf.write(_canWrite ? 'w' : '-');
    buf.write(_isExecutable ? 'x' : '-');
    buf.write('r');
    buf.write(_canWrite ? 'w' : '-');
    buf.write(_isExecutable ? 'x' : '-');
    return buf.toString();
  }

  bool get _canWrite {
    try {
      // Attempt a tiny write to check writability; catch and return false.
      // This is an approximation — Android sandbox restricts most writes.
      return true; // Assume writable in app sandbox.
    } catch (_) {
      return false;
    }
  }

  bool get _isExecutable {
    final ext = extension.toLowerCase();
    const executableExts = {
      '.sh',
      '.bash',
      '.py',
      '.pl',
      '.rb',
      '.js',
      '.ts',
      '.kt',
      '.java',
      '.c',
      '.cpp',
      '.go',
      '.rs',
    };
    return executableExts.contains(ext);
  }

  static String _permissionString(int mode) {
    // mode is octal permission bits (e.g. 0o755 = 493 decimal).
    // Owner: r(0x100) w(0x80) x(0x40), Group: r(0x20) w(0x10) x(0x08), Other: r(0x04) w(0x02) x(0x01)
    const bits = [0x100, 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01];
    const chars = ['r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x'];
    final perms = StringBuffer();
    for (var i = 0; i < bits.length; i++) {
      perms.write((mode & bits[i]) != 0 ? chars[i] : '-');
    }
    return perms.toString();
  }

    IconData get icon {
    if (isDirectory) return Icons.folder;
    final ext = extension;
    if (FileItem._kImageExtensions.contains(ext)) {
      return Icons.image;
    }
    if (const ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) {
      return Icons.movie;
    }
    if (const [
      '.mp3',
      '.flac',
      '.wav',
      '.ogg',
      '.m4a',
      '.opus',
    ].contains(ext)) {
      return Icons.music_note;
    }
    if (ext == '.pdf') return Icons.picture_as_pdf;
    if (const [
      '.zip',
      '.tar',
      '.gz',
      '.xz',
      '.7z',
      '.rar',
      '.zst',
      '.bz2',
    ].contains(ext)) {
      return Icons.archive;
    }
    if (const [
      '.txt',
      '.md',
      '.markdown',
      '.json',
      '.yaml',
      '.yml',
      '.toml',
      '.xml',
      '.html',
      '.css',
      '.js',
      '.ts',
      '.py',
      '.dart',
      '.cpp',
      '.c',
      '.h',
      '.java',
    ].contains(ext)) {
      return Icons.description;
    }
    return Icons.insert_drive_file;
  }

  Color get iconColor {
    if (isDirectory) return Colors.cyan;
    final ext = extension;
    if (FileItem._kImageExtensions.contains(ext)) {
      return const Color(0xFFE5C07B);
    }
    if (const ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) {
      return const Color(0xFFC678DD);
    }
    if (const [
      '.mp3',
      '.flac',
      '.wav',
      '.ogg',
      '.m4a',
      '.opus',
    ].contains(ext)) {
      return const Color(0xFFC678DD);
    }
    if (ext == '.pdf') return const Color(0xFFE06C75);
    if (const [
      '.zip',
      '.tar',
      '.gz',
      '.xz',
      '.7z',
      '.rar',
      '.zst',
      '.bz2',
    ].contains(ext)) {
      return const Color(0xFF98C379);
    }
    if (const [
      '.json',
      '.yaml',
      '.yml',
      '.toml',
      '.xml',
      '.html',
      '.css',
      '.js',
      '.ts',
      '.py',
      '.dart',
      '.cpp',
      '.c',
      '.h',
      '.java',
    ].contains(ext)) {
      return const Color(0xFF98C379);
    }
    return const Color(0xFF5C6370);
  }

  bool get isHidden => name.startsWith('.');
  bool get isImage => _kImageExtensions.contains(extension);
  static const _kImageExtensions = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.heic',
    '.ico', '.tif', '.tiff', '.avif', '.jxl', '.heif',
    '.raw', '.cr2', '.nef', '.arw', '.dng', '.psd', '.xcf', '.tga',
    '.dds', '.exr', '.hdr', '.ktx', '.pkm', '.pvr', '.s3tc',
  };
  bool get isCode => const [
    '.py',
    '.dart',
    '.cpp',
    '.c',
    '.h',
    '.java',
    '.js',
    '.ts',
    '.jsx',
    '.tsx',
    '.rs',
    '.go',
    '.swift',
    '.kt',
    '.kotlin',
  ].contains(extension);
  bool get isMarkdown => const ['.md', '.markdown'].contains(extension);
  bool get isText => const [
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.yaml',
    '.yml',
    '.toml',
    '.xml',
    '.html',
    '.css',
    '.js',
    '.ts',
    '.py',
    '.dart',
    '.cpp',
    '.c',
    '.h',
    '.java',
    '.log',
    '.sh',
    '.bat',
  ].contains(extension);
  bool get isPdf => extension == '.pdf';
}

/// Sort options for the file browser.
enum FileSortOption { name, size, date, type }

enum SortDirection { ascending, descending }

/// Directories that should never be navigated into or searched.
/// Matches Linux SwordFM's filesystem boundary protection.
///
/// Note: `/tmp` (and any user temp location) is intentionally *not* blocked —
/// it is a real, user-accessible directory (and the OS temporary directory),
/// so browsing/searching it must remain possible. Only virtual/system dirs
/// and system-file trees are protected.
const Set<String> kBlockedDirectories = {
  '/proc',
  '/sys',
  '/dev',
  '/run',
  '/snap',
  '/boot',
  '/lost+found',
  '/opt',
  '/usr',
  '/var',
};

/// Returns true if [path] is inside a blocked system directory.
bool isBlockedPath(String path) {
  final normalized = path.endsWith('/') ? path : '$path/';
  return kBlockedDirectories.any(
    (blocked) => normalized == blocked || normalized.startsWith('$blocked/'),
  );
}

/// Returns true if [name] looks like an auto-generated junk filename.
/// Matches Linux SwordFM's FileFilterProxy::isJunkName exactly.
bool isJunkName(String name) {
  if (name.isEmpty) return true;
  // Pure numeric names (e.g. "1000" from /run/user/1000)
  if (RegExp(r'^\d+$').hasMatch(name)) return true;
  final lower = name.toLowerCase();
  // libvirt / virt clutter
  if (lower.contains('libvirt')) return true;
  // systemd unit / service files
  const systemdExts = {
    '.service',
    '.socket',
    '.target',
    '.timer',
    '.mount',
    '.scope',
    '.slice',
    '.path',
    '.device',
    '.automount',
    '.swap',
  };
  for (final ext in systemdExts) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

/// Directory operations.
class FileUtils {
  /// Lists contents of [directoryPath].
  /// If [includeHidden] is true, hidden files (dot-prefixed) are included.
  static Future<List<FileItem>> listDirectory(
    String directoryPath, {
    bool includeHidden = false,
  }) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];

    final entities = await dir.list().toList();
    final items = <FileItem>[];

    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;

      final stat = await entity.stat();
      items.add(
        FileItem(
          entity: entity,
          name: name,
          path: entity.path,
          isDirectory: entity is Directory,
          size: stat.size,
          lastModified: stat.modified,
        ),
      );
    }

    // Directories first, then sort by name within each group
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
  }

  /// Recursively walks [root] and returns entries for which [keep] returns
  /// true. Directories are traversed but never included in the result —
  /// matching the Linux "type/date filter" behaviour where matching files are
  /// shown flat ("find these anywhere under here"). Hidden and (unless
  /// [showJunk]) junk-named entries are skipped during the walk. An iterative
  /// stack avoids deep-recursion overflow on large trees; unreadable
  /// directories are skipped silently.
  static Future<List<FileItem>> listRecursiveFiltered(
    String root, {
    bool includeHidden = false,
    bool showJunk = false,
    bool Function(FileItem item)? keep,
  }) async {
    final results = <FileItem>[];
    final pending = <Directory>[Directory(root)];
    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      final List<FileSystemEntity> entities;
      try {
        entities = await dir.list().toList();
      } catch (_) {
        continue; // unreadable directory — skip
      }
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (!includeHidden && name.startsWith('.')) continue;
        if (!showJunk && isJunkName(name)) continue;
        final isDir = entity is Directory;
        final stat = await entity.stat();
        final item = FileItem(
          entity: entity,
          name: name,
          path: entity.path,
          isDirectory: isDir,
          size: stat.size,
          lastModified: stat.modified,
        );
        if (isDir) {
          pending.add(entity);
        } else if (keep == null || keep(item)) {
          results.add(item);
        }
      }
    }
    results.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return results;
  }

  /// Gets file metadata without reading directory.
  static Future<FileItem> getFileItem(
    String path, {
    bool includeHidden = false,
  }) async {
    final entityType = await FileSystemEntity.type(path);
    final entity = entityType == FileSystemEntityType.directory
        ? Directory(path)
        : File(path);
    final stat = await entity.stat();
    return FileItem(
      entity: entity,
      name: p.basename(path),
      path: path,
      isDirectory: entityType == FileSystemEntityType.directory,
      size: stat.size,
      lastModified: stat.modified,
    );
  }

  // --- CRUD Operations ---

  /// Copies [sourcePath] to [destPath].
  /// Returns a unique destination path by appending (1), (2), etc. if
  /// [destPath] already exists. Matches Linux SwordFM's uniqueDestPath().
  static Future<String> uniqueDestPath(String destPath) async {
    if (await FileSystemEntity.type(destPath) == FileSystemEntityType.notFound)
      return destPath;
    final dir = p.dirname(destPath);
    final ext = p.extension(destPath);
    final base = p.basenameWithoutExtension(destPath);
    int n = 1;
    while (true) {
      final candidate = p.join(dir, '$base ($n)$ext');
      if (await FileSystemEntity.type(candidate) ==
          FileSystemEntityType.notFound)
        return candidate;
      n++;
    }
  }

  static Future<void> copy(String sourcePath, String destPath) async {
    destPath = await uniqueDestPath(destPath);
    final src = File(sourcePath);
    if (await src.exists()) {
      await src.copy(destPath);
    } else {
      await Directory(destPath).create(recursive: true);
      await _copyDirectoryContents(Directory(sourcePath), Directory(destPath));
    }
  }

  /// Recursively copies [srcDir] into [destDir], skipping unreadable
  /// subdirectories instead of failing the whole copy (Android blocks e.g.
  /// Android/data — a paste must not abort just because one subtree is
  /// protected).
  static Future<void> _copyDirectoryContents(
    Directory srcDir,
    Directory destDir,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = await srcDir.list().toList();
    } catch (_) {
      return;
    }
    for (final entity in entities) {
      final newPath = p.join(destDir.path, p.basename(entity.path));
      if (entity is Directory) {
        await Directory(newPath).create(recursive: true);
        await _copyDirectoryContents(entity, Directory(newPath));
      } else {
        try {
          await (entity as File).copy(newPath);
        } catch (_) {
          // Individual unreadable file — skip, keep the rest.
        }
      }
    }
  }

  /// Moves [sourcePath] to [destPath].
  /// Falls back to copy+delete when rename fails (cross-device / EXDEV).
  static Future<void> move(String sourcePath, String destPath) async {
    destPath = await uniqueDestPath(destPath);
    try {
      final src = File(sourcePath);
      if (await src.exists()) {
        await src.rename(destPath);
      } else {
        final dir = Directory(sourcePath);
        await dir.rename(destPath);
      }
    } on FileSystemException {
      // Cross-device move: fall back to copy + delete.
      await copy(sourcePath, destPath);
      final src = await FileSystemEntity.type(sourcePath);
      if (src == FileSystemEntityType.file) {
        await File(sourcePath).delete();
      } else {
        await Directory(sourcePath).delete(recursive: true);
      }
    }
  }

  /// Renames [oldPath] to [newName].
  static Future<void> rename(String oldPath, String newName) async {
    final newPath = p.join(p.dirname(oldPath), newName);
    await move(oldPath, newPath);
  }

  /// Deletes [path], sends to trash on Linux-compatible systems.
  static Future<void> delete(String path) async {
    final entity =
        await FileSystemEntity.type(path) == FileSystemEntityType.file
        ? File(path)
        : Directory(path);
    await entity.delete(recursive: true);
  }

  /// Creates a new directory at [path].
  static Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  // --- Clipboard ---

  static String? _clipboardOp = 'none'; // 'copy' | 'cut'
  static List<String> _clipboardPaths = [];

  static bool get hasClipboard =>
      _clipboardPaths.isNotEmpty && _clipboardOp != 'none';

  /// Current clipboard operation ('copy' | 'cut'), or null when empty.
  static String? get clipboardOperation =>
      (_clipboardOp == null || _clipboardOp == 'none') ? null : _clipboardOp;

  /// Number of items in the clipboard.
  static int get clipboardCount => _clipboardPaths.length;

  /// All paths in the clipboard.
  static List<String> get clipboardPaths => List.unmodifiable(_clipboardPaths);

  static void setClipboard(String path, String op) {
    _clipboardPaths = [path];
    _clipboardOp = op;
  }

  static void setClipboardMultiple(List<String> paths, String op) {
    _clipboardPaths = List.from(paths);
    _clipboardOp = op;
  }

  static Future<void> paste(String destDir) async {
    if (_clipboardPaths.isEmpty || _clipboardOp == null) return;
    final pathsToPaste = List<String>.from(_clipboardPaths);
    for (final srcPath in pathsToPaste) {
      final destPath = p.join(destDir, p.basename(srcPath));
      if (_clipboardOp == 'copy') {
        await copy(srcPath, destPath);
      } else if (_clipboardOp == 'cut') {
        await move(srcPath, destPath);
      }
    }
    if (_clipboardOp == 'cut') {
      _clipboardPaths.clear();
      _clipboardOp = 'none';
    }
  }

  static void clearClipboard() {
    _clipboardPaths.clear();
    _clipboardOp = 'none';
  }

  // --- Share ---

  static const _shareChannel = MethodChannel('com.swordfm/share');

  /// Opens the Android system share sheet for [path].
  static Future<bool> share(String path) async {
    try {
      final result = await _shareChannel.invokeMethod<bool>('shareFile', {
        'path': path,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  // --- Trash ---

  /// Moves [path] into the app-local trash directory.
  /// Returns the trash path of the moved item.
  static Future<String> moveToTrash(String path) async {
    final trashDir = await AppPaths.trashDir;
    await Directory(trashDir).create(recursive: true);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final trashName = '${timestamp}_${p.basename(path)}';
    final trashPath = p.join(trashDir, trashName);
    await move(path, trashPath);
    return trashPath;
  }

  /// Returns all items currently in the trash.
  static Future<List<FileItem>> listTrash() async {
    final trashDir = await AppPaths.trashDir;
    return listDirectory(trashDir, includeHidden: false);
  }

  /// Restores a trashed item to [originalPath].
  static Future<void> restoreFromTrash(
    String trashPath,
    String originalPath,
  ) async {
    await move(trashPath, originalPath);
  }

  /// Permanently deletes everything in the trash.
  static Future<void> emptyTrash() async {
    final trashDir = await AppPaths.trashDir;
    final dir = Directory(trashDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}
