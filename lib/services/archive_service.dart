import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Pure-Dart archive operations for ZIP, TAR, and GZip formats.
///
/// Supports:
///   - Extracting archives to a target directory (ZIP, TAR, TARGZ)
///   - Creating ZIP/TAR archives from files or directories (recursive)
///
/// Unsupported formats: 7z, RAR, and bzip2 require native/FFI bindings.
class ArchiveService {
  /// Supported extensions mapped to their operation type.
  static const Set<String> supportedExts = {
    '.zip', '.tar', '.gz', '.tgz', '.tar.gz',
  };

  /// Returns true if [path] looks like a supported archive file.
  static bool isArchive(String path) {
    final ext = p.extension(path).toLowerCase();
    return supportedExts.contains(ext);
  }

  // -----------------------------------------------------------------------
  // Extract
  // -----------------------------------------------------------------------

  /// Extracts an archive at [archivePath] into [destDir].
  ///
  /// Supported formats (auto-detected by extension):
  ///   - `.zip`       — ZIP archive
  ///   - `.tar`       — uncompressed TAR
  ///   - `.gz` / `.tgz` — GZip-wrapped TAR
  ///   - `.tar.gz`    — same as above (canonical form)
  ///
  /// Returns a list of extracted file paths. Throws [Exception] on failure
  /// with a prefix: `unsupported:`, `invalid:`, or `io:`.
  static Future<List<String>> extract(String archivePath, String destDir) async {
    final ext = p.extension(archivePath).toLowerCase();
    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      throw Exception('archive not found: $archivePath');
    }
    await Directory(destDir).create(recursive: true);

    List<int> data;
    try {
      data = await archiveFile.readAsBytes();
    } catch (e) {
      throw Exception('io:failed to read archive: $e');
    }

    List<ArchiveFile> files;
    switch (ext) {
      case '.zip':
        files = ZipDecoder().decodeBytes(data).files;
        break;
      case '.tar':
        files = TarDecoder().decodeBytes(data).files;
        break;
      case '.gz':
      case '.tgz':
      case '.tar.gz':
        final gzipDecoded = GZipDecoder().decodeBytes(data);
        files = TarDecoder().decodeBytes(gzipDecoded).files;
        break;
      default:
        throw Exception('unsupported:unknown archive format $ext');
    }

    if (files.isEmpty) {
      throw Exception('invalid:archive contains no files');
    }

    final extractedPaths = <String>[];
    for (final af in files) {
      final name = af.name;
      // Safety: reject path traversal in archive entries
      if (name.contains('..') || name.contains(String.fromCharCode(0))) continue;

      final destPath = p.join(destDir, name);

      if (af.isDirectory) {
        await Directory(destPath).create(recursive: true);
      } else {
        final parentDir = Directory(p.dirname(destPath));
        await parentDir.create(recursive: true);
        final outStream = File(destPath).openWrite();
        final content = af.content as List<int>;
        outStream.add(content);
        await outStream.close();
      }
      extractedPaths.add(destPath);
    }

    return extractedPaths;
  }

  // -----------------------------------------------------------------------
  // Create ZIP
  // -----------------------------------------------------------------------

  /// Creates a ZIP archive at [outputPath] containing the given [sources].
  /// Each source can be a file or directory (directories are recursed).
  static Future<String> createZip({
    required String outputPath,
    required List<String> sources,
  }) async {
    final archive = Archive();
    for (final source in sources) {
      await _addPathsToArchive(source, archive, prefix: '');
    }

    final bytes = ZipEncoder().encode(archive);
    await File(outputPath).writeAsBytes(bytes);
    return outputPath;
  }

  /// Creates a TAR archive at [outputPath] containing the given [sources].
  static Future<String> createTar({
    required String outputPath,
    required List<String> sources,
  }) async {
    final archive = Archive();
    for (final source in sources) {
      await _addPathsToArchive(source, archive, prefix: '');
    }

    final bytes = TarEncoder().encode(archive);
    await File(outputPath).writeAsBytes(bytes);
    return outputPath;
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  static Future<void> _addPathsToArchive(
    String path,
    Archive archive, {
    required String prefix,
  }) async {
    final entityType = await FileSystemEntity.type(path);
    final baseName = p.basename(path);
    final arcName = prefix.isEmpty ? baseName : '$prefix/$baseName';

    if (entityType == FileSystemEntityType.file) {
      final data = await File(path).readAsBytes();
      archive.addFile(ArchiveFile(arcName, data.length, data));
    } else if (entityType == FileSystemEntityType.directory) {
      final entities = await Directory(path).list().toList();
      for (final entity in entities) {
        await _addPathsToArchive(entity.path, archive, prefix: arcName);
      }
    }
  }
}
