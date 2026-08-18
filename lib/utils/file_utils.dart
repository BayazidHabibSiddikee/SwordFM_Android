import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
export 'constants.dart';

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
    final items = await listDirectory(item.path, includeHidden: false);
    int total = item.size;
    for (final child in items) {
      total += await getTotalSize(child);
    }
    return total;
  }

  String get formattedDate {
    return DateFormat('yyyy-MM-dd HH:mm').format(lastModified);
  }

  IconData get icon {
    if (isDirectory) return Icons.folder;
    final ext = extension;
    if (const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.heic'].contains(ext)) {
      return Icons.image;
    }
    if (const ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) {
      return Icons.movie;
    }
    if (const ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.opus'].contains(ext)) {
      return Icons.music_note;
    }
    if (ext == '.pdf') return Icons.picture_as_pdf;
    if (const ['.zip', '.tar', '.gz', '.xz', '.7z', '.rar', '.zst', '.bz2'].contains(ext)) {
      return Icons.archive;
    }
    if (const ['.txt', '.md', '.markdown', '.json', '.yaml', '.yml', '.toml', '.xml', '.html', '.css', '.js', '.ts', '.py', '.dart', '.cpp', '.c', '.h', '.java'].contains(ext)) {
      return Icons.description;
    }
    return Icons.insert_drive_file;
  }

  Color get iconColor {
    if (isDirectory) return Colors.cyan;
    final ext = extension;
    if (const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.heic'].contains(ext)) {
      return const Color(0xFFE5C07B);
    }
    if (const ['.mp4', '.mkv', '.mov', '.avi', '.webm'].contains(ext)) {
      return const Color(0xFFC678DD);
    }
    if (const ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.opus'].contains(ext)) {
      return const Color(0xFFC678DD);
    }
    if (ext == '.pdf') return const Color(0xFFE06C75);
    if (const ['.zip', '.tar', '.gz', '.xz', '.7z', '.rar', '.zst', '.bz2'].contains(ext)) {
      return const Color(0xFF98C379);
    }
    if (const ['.json', '.yaml', '.yml', '.toml', '.xml', '.html', '.css', '.js', '.ts', '.py', '.dart', '.cpp', '.c', '.h', '.java'].contains(ext)) {
      return const Color(0xFF98C379);
    }
    return const Color(0xFF5C6370);
  }

  bool get isHidden => name.startsWith('.');
  bool get isImage => const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.heic'].contains(extension);
  bool get isCode => const ['.py', '.dart', '.cpp', '.c', '.h', '.java', '.js', '.ts', '.jsx', '.tsx', '.rs', '.go', '.swift', '.kt', '.kotlin'].contains(extension);
  bool get isMarkdown => const ['.md', '.markdown'].contains(extension);
  bool get isText => const ['.txt', '.md', '.markdown', '.json', '.yaml', '.yml', '.toml', '.xml', '.html', '.css', '.js', '.ts', '.py', '.dart', '.cpp', '.c', '.h', '.java', '.log', '.sh', '.bat'].contains(extension);
  bool get isPdf => extension == '.pdf';
}

/// Sort options for the file browser.
enum FileSortOption { name, size, date, type }
enum SortDirection { ascending, descending }

/// Directory operations.
class FileUtils {
  /// Lists contents of [directoryPath].
  /// If [includeHidden] is true, hidden files (dot-prefixed) are included.
  static Future<List<FileItem>> listDirectory(String directoryPath, {bool includeHidden = false}) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return [];

    final entities = await dir.list().toList();
    final items = <FileItem>[];

    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (!includeHidden && name.startsWith('.')) continue;

      final stat = await entity.stat();
      items.add(FileItem(
        entity: entity,
        name: name,
        path: entity.path,
        isDirectory: entity is Directory,
        size: stat.size,
        lastModified: stat.modified,
      ));
    }

    // Directories first, then sort by name within each group
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
  }

  /// Gets file metadata without reading directory.
  static Future<FileItem> getFileItem(String path, {bool includeHidden = false}) async {
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
  static Future<void> copy(String sourcePath, String destPath) async {
    final src = File(sourcePath);
    if (await src.exists()) {
      await src.copy(destPath);
    } else {
      final dir = Directory(sourcePath);
      await dir.create(recursive: true);
      final entities = await dir.list(recursive: true).toList();
      for (final entity in entities) {
        final relative = p.relative(entity.path, from: sourcePath);
        final newPath = p.join(destPath, relative);
        if (entity is Directory) {
          await Directory(newPath).create(recursive: true);
        } else {
          await (entity as File).copy(newPath);
        }
      }
    }
  }

  /// Moves [sourcePath] to [destPath].
  static Future<void> move(String sourcePath, String destPath) async {
    final src = File(sourcePath);
    if (await src.exists()) {
      await src.rename(destPath);
    } else {
      final dir = Directory(sourcePath);
      await dir.rename(destPath);
    }
  }

  /// Renames [oldPath] to [newName].
  static Future<void> rename(String oldPath, String newName) async {
    final newPath = p.join(p.dirname(oldPath), newName);
    await move(oldPath, newPath);
  }

  /// Deletes [path], sends to trash on Linux-compatible systems.
  static Future<void> delete(String path) async {
    final entity = await FileSystemEntity.type(path) == FileSystemEntityType.file
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
  static String? _clipboardPath;

  static void setClipboard(String path, String op) {
    _clipboardPath = path;
    _clipboardOp = op;
  }

  static Future<void> paste(String destDir) async {
    if (_clipboardPath == null || _clipboardOp == null) return;
    final destPath = p.join(destDir, p.basename(_clipboardPath!));
    if (_clipboardOp == 'copy') {
      await copy(_clipboardPath!, destPath);
    } else if (_clipboardOp == 'cut') {
      await move(_clipboardPath!, destPath);
      _clipboardPath = null;
      _clipboardOp = 'none';
    }
  }

  static void clearClipboard() {
    _clipboardPath = null;
    _clipboardOp = 'none';
  }
}
