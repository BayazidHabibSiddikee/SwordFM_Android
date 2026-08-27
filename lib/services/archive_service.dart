import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Pure-Dart archive operations built on the `archive` package.
///
/// Supports:
///   - Extracting archives to a target directory (ZIP, TAR, TAR.GZ,
///     TAR.XZ, TAR.BZ2)
///   - Creating ZIP/TAR archives from files or directories (recursive),
///     optionally wrapped in GZip / XZ / BZip2 compression
///
/// Formats that require native/FFI bindings (7z, RAR, tar.zst) are not
/// covered by the Dart `archive` package and remain unsupported here.
import 'package:crypto/crypto.dart';

class ArchiveService {
  /// Compute SHA-256 hex digest of a file. Returns null on error.
  static Future<String?> sha256OfFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return sha256.convert(bytes).toString();
    } catch (_) {
      return null;
    }
  }

  /// Find potential duplicates in [paths] by SHA-256 hash.
  /// Returns map: hash -> list of paths with that hash.
  static Future<Map<String, List<String>>> findDuplicates(
    List<String> paths,
  ) async {
    final Map<String, List<String>> groups = {};
    for (final p in paths) {
      final h = await sha256OfFile(p);
      if (h != null) {
        groups.putIfAbsent(h, () => []).add(p);
      }
    }
    // Only keep groups with more than one entry
    return {
      for (final e in groups.entries)
        if (e.value.length > 1) e.key: e.value,
    };
  }

  /// Supported extensions mapped to their operation type.
  /// Note: `p.extension('a.tar.gz')` returns `.gz`, so multi-part suffixes are
  /// matched by their outermost compression extension (`.gz` / `.xz` / `.bz2`).
  ///
  /// Formats marked `(native)` are detected but require platform-specific
  /// extraction (7z, rar, zst are not supported by the pure-Dart archive pkg).
  static const Set<String> supportedExts = {
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.tar.gz',
    '.xz',
    '.txz',
    '.bz2',
    '.tbz2',
    '.7z',   // (native) detected, extraction requires native binding
    '.rar',  // (native) detected, extraction requires native binding
    '.zst',  // (native) detected, extraction requires native binding
    '.lz',
    '.lzma',
  };

  /// Returns true if [path] looks like a supported archive file.
  static bool isArchive(String path) {
    final name = p.basename(path).toLowerCase();
    // Check multi-part extensions first (e.g. .tar.gz, .tar.xz, .tar.bz2)
    if (name.endsWith('.tar.gz') || name.endsWith('.tar.bz2') || name.endsWith('.tar.xz') || name.endsWith('.tar.zst')) {
      return true;
    }
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
  static Future<List<String>> extract(
    String archivePath,
    String destDir,
  ) async {
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
      case '.xz':
      case '.txz':
      case '.tar.xz':
        final xzDecoded = XZDecoder().decodeBytes(data);
        files = TarDecoder().decodeBytes(xzDecoded).files;
        break;
      case '.bz2':
      case '.tbz2':
      case '.tar.bz2':
        final bz2Decoded = BZip2Decoder().decodeBytes(data);
        files = TarDecoder().decodeBytes(bz2Decoded).files;
        break;
      case '.7z':
        throw Exception('unsupported:7z extraction requires native bindings — install p7zip on your device');
      case '.rar':
        throw Exception('unsupported:RAR extraction requires native bindings — install unrar on your device');
      case '.zst':
      case '.tar.zst':
        throw Exception('unsupported:Zstandard extraction requires native bindings — install zstd on your device');
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
      if (name.contains('..') || name.contains(String.fromCharCode(0)))
        continue;

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

  /// Creates a GZip-compressed TAR archive (`*.tar.gz`) at [outputPath]
  /// containing the given [sources].
  static Future<String> createTarGz({
    required String outputPath,
    required List<String> sources,
  }) async {
    final archive = Archive();
    for (final source in sources) {
      await _addPathsToArchive(source, archive, prefix: '');
    }

    final tarBytes = TarEncoder().encode(archive);
    final gzBytes = GZipEncoder().encode(tarBytes);
    await File(outputPath).writeAsBytes(gzBytes);
    return outputPath;
  }

  /// Creates an XZ-compressed TAR archive (`*.tar.xz`) at [outputPath].
  static Future<String> createTarXz({
    required String outputPath,
    required List<String> sources,
  }) async {
    final archive = Archive();
    for (final source in sources) {
      await _addPathsToArchive(source, archive, prefix: '');
    }

    final tarBytes = TarEncoder().encode(archive);
    final xzBytes = XZEncoder().encode(tarBytes);
    await File(outputPath).writeAsBytes(xzBytes);
    return outputPath;
  }

  /// Creates a BZip2-compressed TAR archive (`*.tar.bz2`) at [outputPath].
  static Future<String> createTarBz2({
    required String outputPath,
    required List<String> sources,
  }) async {
    final archive = Archive();
    for (final source in sources) {
      await _addPathsToArchive(source, archive, prefix: '');
    }

    final tarBytes = TarEncoder().encode(archive);
    final bz2Bytes = BZip2Encoder().encode(tarBytes);
    await File(outputPath).writeAsBytes(bz2Bytes);
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
