import 'dart:io';
import 'dart:isolate';
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

  /// Fast three-pass duplicate detection.
  ///
  /// Pass 1 — group by file size (cheap stat, no reads).
  /// Pass 2 — for each size group with 2+ members, read only the first 64 KB
  ///          and re-group by (size + head hash).  Eliminates most false
  ///          positive size collisions without reading full files.
  /// Pass 3 — full SHA-256 only on surviving candidates.
  static Future<Map<String, List<String>>> findDuplicates(
    List<String> paths,
  ) async {
    // Pass 1: size -> paths (cheap stat).
    final bySize = <int, List<String>>{};
    for (final path in paths) {
      try {
        final size = await File(path).length();
        bySize.putIfAbsent(size, () => []).add(path);
      } catch (_) {}
    }

    // Pass 2: head-hash on size-collision groups.
    final Map<String, List<String>> headGroups = {};
    for (final entry in bySize.entries) {
      if (entry.value.length < 2) continue;
      for (final path in entry.value) {
        try {
          final head = await _readHead(File(path), 65536); // 64 KB
          final key = '${entry.key}|${sha256.convert(head)}';
          headGroups.putIfAbsent(key, () => []).add(path);
        } catch (_) {}
      }
    }

    // Only head-groups with 2+ candidates need full hashing.
    final candidates = headGroups.values
        .where((g) => g.length > 1)
        .expand((g) => g)
        .toList();
    if (candidates.isEmpty) return {};

    // Pass 3: full SHA-256 on candidates only.
    final Map<String, List<String>> fullGroups = {};
    for (final path in candidates) {
      final h = await sha256OfFile(path);
      if (h != null) {
        fullGroups.putIfAbsent(h, () => []).add(path);
      }
    }
    return {
      for (final e in fullGroups.entries)
        if (e.value.length > 1) e.key: e.value,
    };
  }

  /// Reads the first [n] bytes of [file].
  static Future<List<int>> _readHead(File file, int n) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      return await raf.read(n);
    } finally {
      await raf.close();
    }
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
    '.7z', // (native) detected, extraction requires native binding
    '.rar', // (native) detected, extraction requires native binding
    '.zst', // (native) detected, extraction requires native binding
    '.lz',
    '.lzma',
  };

  /// Returns true if [path] looks like a supported archive file.
  static bool isArchive(String path) {
    final name = p.basename(path).toLowerCase();
    // Check multi-part extensions first (e.g. .tar.gz, .tar.xz, .tar.bz2)
    if (name.endsWith('.tar.gz') ||
        name.endsWith('.tar.bz2') ||
        name.endsWith('.tar.xz') ||
        name.endsWith('.tar.zst')) {
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
        return _extractWithTool(
          archivePath,
          destDir,
          tool: '7z',
          toolArgs: ['x', '-y'],
          hint: 'Install "p7zip" in Termux to extract 7z archives',
        );
      case '.rar':
        return _extractWithTool(
          archivePath,
          destDir,
          tool: 'unrar',
          toolArgs: ['x', '-y'],
          hint: 'Install "unrar" in Termux to extract RAR archives',
        );
      case '.zst':
      case '.tar.zst':
        return _extractWithTool(
          archivePath,
          destDir,
          tool: 'zstd',
          toolArgs: ['-d', '-o'],
          hint: 'Install "zstd" in Termux to extract Zstandard archives',
        );
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

  /// Extracts a format that the pure-Dart decoders can't handle (7z/rar/zst)
  /// by shelling out to the matching binary installed in Termux. Throws an
  /// actionable message when the tool is missing.
  static Future<List<String>> _extractWithTool(
    String archivePath,
    String destDir, {
    required String tool,
    required List<String> toolArgs,
    required String hint,
  }) async {
    const termuxBin = '/data/data/com.termux/files/usr/bin';
    final binary = '$termuxBin/$tool';
    if (!File(binary).existsSync()) {
      throw Exception('unsupported:$hint');
    }
    await Directory(destDir).create(recursive: true);
    if (tool == 'zstd') {
      // zstd -d file.tar.zst → file.tar in the working dir; then TAR-decode.
      final result = await Process.run(binary, [
        '-d',
        archivePath,
      ], workingDirectory: destDir);
      if (result.exitCode != 0) {
        throw Exception('io:zstd failed: ${result.stderr}');
      }
      final name = p.basename(archivePath);
      final tarName = name.endsWith('.zst')
          ? name.substring(0, name.length - 4)
          : name;
      final tarPath = p.join(destDir, tarName);
      if (File(tarPath).existsSync()) {
        final inner = TarDecoder().decodeBytes(File(tarPath).readAsBytesSync());
        for (final af in inner.files) {
          if (af.isDirectory) continue;
          final outPath = p.join(destDir, af.name);
          await Directory(p.dirname(outPath)).create(recursive: true);
          await File(outPath).writeAsBytes(af.content as List<int>);
        }
      }
      return [destDir];
    }
    final outFlag = tool == '7z' ? '-o$destDir' : '$destDir${p.separator}';
    final result = await Process.run(binary, [
      ...toolArgs,
      archivePath,
      outFlag,
    ]);
    if (result.exitCode != 0) {
      throw Exception('io:${tool} failed: ${result.stderr}');
    }
    return [destDir];
  }

  /// Decodes the archive and returns its entries (name / size / isDirectory),
  /// without writing anything. Used by the archive-browser screen.
  static Future<List<ArchiveEntryInfo>> listArchiveContents(
    String archivePath,
  ) async {
    final files = await _decodeArchive(archivePath);
    return files
        .where(
          (af) =>
              !af.name.contains('..') &&
              !af.name.contains(String.fromCharCode(0)),
        )
        .map(
          (af) => ArchiveEntryInfo(
            name: af.name,
            size: af.isDirectory ? 0 : af.size,
            isDirectory: af.isDirectory,
          ),
        )
        .toList();
  }

  /// Extracts a single entry (by name) from [archivePath] into [destDir],
  /// creating parent folders as needed. Returns the written path.
  static Future<String> extractEntry(
    String archivePath,
    String entryName,
    String destDir,
  ) async {
    final files = await _decodeArchive(archivePath);
    final af = files.where((f) => f.name == entryName && !f.isDirectory).first;
    final destPath = p.join(destDir, entryName);
    await Directory(p.dirname(destPath)).create(recursive: true);
    final outStream = File(destPath).openWrite();
    outStream.add(af.content as List<int>);
    await outStream.close();
    return destPath;
  }

  static Future<List<ArchiveFile>> _decodeArchive(String archivePath) async {
    final ext = p.extension(archivePath).toLowerCase();
    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      throw Exception('archive not found: $archivePath');
    }
    final data = await archiveFile.readAsBytes();
    switch (ext) {
      case '.zip':
        return ZipDecoder().decodeBytes(data).files;
      case '.tar':
        return TarDecoder().decodeBytes(data).files;
      case '.gz':
      case '.tgz':
      case '.tar.gz':
        return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(data)).files;
      case '.xz':
      case '.txz':
      case '.tar.xz':
        return TarDecoder().decodeBytes(XZDecoder().decodeBytes(data)).files;
      case '.bz2':
      case '.tbz2':
      case '.tar.bz2':
        return TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(data)).files;
      default:
        throw Exception('unsupported:${ext} — 7z/rar/zst need native tools');
    }
  }

  // -----------------------------------------------------------------------
  // Create ZIP
  // -----------------------------------------------------------------------

  /// Creates a ZIP archive at [outputPath] containing the given [sources].
  /// Each source can be a file or directory (directories are recursed).
  ///
  /// Runs in a background isolate so large archives don't freeze the UI.
  static Future<String> createZip({
    required String outputPath,
    required List<String> sources,
  }) {
    return Isolate.run(() {
      final archive = Archive();
      for (final source in sources) {
        _addPathSync(source, archive, '');
      }
      final bytes = ZipEncoder().encode(archive);
      File(outputPath).writeAsBytesSync(bytes);
      return outputPath;
    });
  }

  /// Creates a TAR archive at [outputPath] containing the given [sources].
  static Future<String> createTar({
    required String outputPath,
    required List<String> sources,
  }) {
    return Isolate.run(() {
      final archive = Archive();
      for (final source in sources) {
        _addPathSync(source, archive, '');
      }
      final bytes = TarEncoder().encode(archive);
      File(outputPath).writeAsBytesSync(bytes);
      return outputPath;
    });
  }

  /// Creates a GZip-compressed TAR archive (`*.tar.gz`) at [outputPath]
  /// containing the given [sources].
  static Future<String> createTarGz({
    required String outputPath,
    required List<String> sources,
  }) {
    return Isolate.run(() {
      final archive = Archive();
      for (final source in sources) {
        _addPathSync(source, archive, '');
      }
      final tarBytes = TarEncoder().encode(archive);
      final gzBytes = GZipEncoder().encode(tarBytes);
      File(outputPath).writeAsBytesSync(gzBytes);
      return outputPath;
    });
  }

  /// Creates an XZ-compressed TAR archive (`*.tar.xz`) at [outputPath].
  static Future<String> createTarXz({
    required String outputPath,
    required List<String> sources,
  }) {
    return Isolate.run(() {
      final archive = Archive();
      for (final source in sources) {
        _addPathSync(source, archive, '');
      }
      final tarBytes = TarEncoder().encode(archive);
      final xzBytes = XZEncoder().encode(tarBytes);
      File(outputPath).writeAsBytesSync(xzBytes);
      return outputPath;
    });
  }

  /// Creates a BZip2-compressed TAR archive (`*.tar.bz2`) at [outputPath].
  static Future<String> createTarBz2({
    required String outputPath,
    required List<String> sources,
  }) {
    return Isolate.run(() {
      final archive = Archive();
      for (final source in sources) {
        _addPathSync(source, archive, '');
      }
      final tarBytes = TarEncoder().encode(archive);
      final bz2Bytes = BZip2Encoder().encode(tarBytes);
      File(outputPath).writeAsBytesSync(bz2Bytes);
      return outputPath;
    });
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /// Isolate-safe (sync) recursive walker: reads files and walks directories
  /// synchronously so archive creation can run inside [Isolate.run].
  static void _addPathSync(String path, Archive archive, String prefix) {
    final type = FileSystemEntity.typeSync(path);
    final baseName = p.basename(path);
    final arcName = prefix.isEmpty ? baseName : '$prefix/$baseName';
    if (type == FileSystemEntityType.file) {
      final data = File(path).readAsBytesSync();
      archive.addFile(ArchiveFile(arcName, data.length, data));
    } else if (type == FileSystemEntityType.directory) {
      for (final entity in Directory(path).listSync()) {
        _addPathSync(entity.path, archive, arcName);
      }
    }
  }
}

/// Lightweight archive-entry descriptor used by the archive browser.
class ArchiveEntryInfo {
  final String name;
  final int size;
  final bool isDirectory;
  const ArchiveEntryInfo({
    required this.name,
    required this.size,
    required this.isDirectory,
  });
}
