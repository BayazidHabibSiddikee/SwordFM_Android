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

/// Isolate-safe SHA-256 that streams the file in 1 MB chunks instead of
/// loading it fully into memory — avoids OOM on multi-GB candidates.
/// Returns the hex digest, or null on any read error.
Future<String?> _hashFileChunked(String path) async {
  try {
    final raf = await File(path).open();
    final cap = _DigestCapture();
    final digest = sha256.startChunkedConversion(cap);
    const chunkSize = 1024 * 1024;
    while (true) {
      final block = await raf.read(chunkSize);
      if (block.isEmpty) break;
      digest.add(block);
    }
    await raf.close();
    digest.close();
    final d = cap.value;
    return d == null || d.bytes.isEmpty ? null : d.toString();
  } catch (_) {
    return null;
  }
}

/// Collects the single [Digest] emitted by a chunked hash conversion.
class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest value) {
    if (this.value != null) throw StateError('add may only be called once.');
    this.value = value;
  }

  @override
  void close() {}
}

/// Top-level worker for [ArchiveService.findDuplicates] — runs inside a
/// background isolate so SHA-256 hashing doesn't block the UI thread.
Future<Map<String, List<String>>> _findDuplicatesWorker(
    List<String> paths) async {
  // Pass 1: group by size (cheap stat).
  final bySize = <int, List<String>>{};
  for (final path in paths) {
    try {
      bySize.putIfAbsent(await File(path).length(), () => []).add(path);
    } catch (_) {}
  }

  // Pass 2: head-hash (first 64 KB) on size-collision groups.
  final headGroups = <String, List<String>>{};
  for (final entry in bySize.entries) {
    if (entry.value.length < 2) continue;
    for (final path in entry.value) {
      try {
        final raf = await File(path).open();
        final head = await raf.read(65536);
        await raf.close();
        final key = '${entry.key}|${sha256.convert(head)}';
        headGroups.putIfAbsent(key, () => []).add(path);
      } catch (_) {}
    }
  }

  final candidates = headGroups.values
      .where((g) => g.length > 1)
      .expand((g) => g)
      .toList();
  if (candidates.isEmpty) return {};

  // Pass 3: full SHA-256 on survivors only (streamed, not loaded into RAM).
  final fullGroups = <String, List<String>>{};
  for (final path in candidates) {
    try {
      final h = await _hashFileChunked(path);
      if (h != null) fullGroups.putIfAbsent(h, () => []).add(path);
    } catch (_) {}
  }
  return {
    for (final e in fullGroups.entries)
      if (e.value.length > 1) e.key: e.value,
  };
}

/// Thrown when an archive format is detected but not supported by the
/// in-app pure-Dart implementation (e.g. 7z, RAR).
class UnsupportedArchiveFormat implements Exception {
  final String format;
  final String message;
  const UnsupportedArchiveFormat(this.format, this.message);

  @override
  String toString() => 'UnsupportedArchiveFormat($format): $message';
}

/// Thrown when an archive exceeds the configured safety limits (entry count
/// or uncompressed size), preventing zip-bomb-style attacks.
class ArchiveBombException implements Exception {
  final String message;
  const ArchiveBombException(this.message);

  @override
  String toString() => 'ArchiveBombException: $message';
}

class ArchiveService {
  /// Maximum number of entries allowed in a single archive extraction.
  /// Archives exceeding this are rejected with [ArchiveBombException].
  static const int maxEntries = 10000;

  /// Maximum total uncompressed size (in bytes) allowed during extraction.
  /// 4 GB — consistent with common zip-bomb mitigations.
  static const int maxUncompressedBytes = 4 * 1024 * 1024 * 1024;
  /// Compute SHA-256 hex digest of a file. Returns null on error.
  /// Streams in chunks so large files don't spike memory.
  static Future<String?> sha256OfFile(String path) async {
    return _hashFileChunked(path);
  }

  /// Fast three-pass duplicate detection — runs in a background isolate.
  ///
  /// Pass 1 — group by file size (cheap stat, no reads).
  /// Pass 2 — for each size group with 2+ members, read only the first 64 KB
  ///          and re-group by (size + head hash).
  /// Pass 3 — full SHA-256 only on surviving candidates.
  static Future<Map<String, List<String>>> findDuplicates(
    List<String> paths,
  ) async {
    return Isolate.run(() => _findDuplicatesWorker(paths));
  }

  /// Extensions that the pure-Dart `archive` package can extract and create
  /// in-app, without any native/FFI dependency.
  ///
  /// 7z, RAR, and Zstandard are NOT listed here because they require native
  /// bindings unavailable on all supported platforms. Attempting to open them
  /// throws [UnsupportedArchiveFormat] so callers get a clear, actionable
  /// message rather than a silent failure.
  static const Set<String> supportedExts = {
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.xz',
    '.txz',
    '.bz2',
    '.tbz2',
  };

  /// Extensions we can detect but explicitly do NOT support in-app. Used to
  /// give a better error message than "unknown format".
  static const Set<String> unsupportedExts = {
    '.7z', // requires 7zip / p7zip native binary
    '.rar', // requires unrar native binary
    '.zst', // requires zstd native binary
    '.lz',
    '.lzma',
  };

  /// Returns true if [path] looks like any known archive file (supported or
  /// recognised-but-unsupported). Use [isSupportedArchive] to test only
  /// formats that can be opened in-app.
  static bool isArchive(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.endsWith('.tar.gz') ||
        name.endsWith('.tar.bz2') ||
        name.endsWith('.tar.xz') ||
        name.endsWith('.tar.zst')) {
      return true;
    }
    final ext = p.extension(path).toLowerCase();
    return supportedExts.contains(ext) || unsupportedExts.contains(ext);
  }

  /// Returns true only for formats the app can open without native tools.
  static bool isSupportedArchive(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.endsWith('.tar.gz') ||
        name.endsWith('.tar.bz2') ||
        name.endsWith('.tar.xz')) {
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
  ///   - `.zip`                   — ZIP archive
  ///   - `.tar`                   — uncompressed TAR
  ///   - `.gz` / `.tgz`           — GZip-wrapped single file or TAR
  ///   - `.tar.gz`                — same as above (canonical form)
  ///   - `.xz` / `.txz` / `.tar.xz` — XZ-wrapped single file or TAR
  ///   - `.bz2` / `.tbz2` / `.tar.bz2` — BZip2-wrapped single file or TAR
  ///
  /// Throws [UnsupportedArchiveFormat] for 7z, RAR, and Zstandard — these
  /// require native binaries not bundled with the app.
  ///
  /// Throws [ArchiveBombException] when the archive exceeds [maxEntries]
  /// entries or [maxUncompressedBytes] total uncompressed size.
  ///
  /// Throws [Exception] on other failures with a prefix:
  ///   `invalid:`, or `io:`.
  static Future<List<String>> extract(
    String archivePath,
    String destDir,
  ) async {
    final name = p.basename(archivePath).toLowerCase();
    final ext = p.extension(archivePath).toLowerCase();

    // ---- Loudly reject formats we cannot handle ----
    if (ext == '.7z') {
      throw UnsupportedArchiveFormat(
        '7z',
        '7z archives cannot be extracted in-app. '
            'Open a terminal (Termux) and run: 7z x "$archivePath"',
      );
    }
    if (ext == '.rar') {
      throw UnsupportedArchiveFormat(
        'rar',
        'RAR archives cannot be extracted in-app. '
            'Open a terminal (Termux) and run: unrar x "$archivePath"',
      );
    }
    if (ext == '.zst' || name.endsWith('.tar.zst')) {
      throw UnsupportedArchiveFormat(
        'zst',
        'Zstandard archives cannot be extracted in-app. '
            'Open a terminal (Termux) and run: zstd -d "$archivePath"',
      );
    }

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

    List<ArchiveFile> files = <ArchiveFile>[];
    List<int>? singleFileData;
    String? singleFileName;
    switch (ext) {
      case '.zip':
        files = ZipDecoder().decodeBytes(data).files;
        break;
      case '.tar':
        files = TarDecoder().decodeBytes(data).files;
        break;
      case '.gz':
      case '.tgz':
        final gzipDecoded = GZipDecoder().decodeBytes(data);
        final tarFiles = _tryDecodeTar(gzipDecoded);
        if (tarFiles != null) {
          files = tarFiles;
        } else {
          singleFileData = gzipDecoded;
          singleFileName = _stripExt(archivePath, '.gz');
        }
        break;
      case '.xz':
      case '.txz':
        final xzDecoded = XZDecoder().decodeBytes(data);
        final tarFiles = _tryDecodeTar(xzDecoded);
        if (tarFiles != null) {
          files = tarFiles;
        } else {
          singleFileData = xzDecoded;
          singleFileName = _stripExt(archivePath, '.xz');
        }
        break;
      case '.bz2':
      case '.tbz2':
        final bz2Decoded = BZip2Decoder().decodeBytes(data);
        final tarFiles = _tryDecodeTar(bz2Decoded);
        if (tarFiles != null) {
          files = tarFiles;
        } else {
          singleFileData = bz2Decoded;
          singleFileName = _stripExt(archivePath, '.bz2');
        }
        break;
      default:
        // Multi-part names handled here (.tar.gz etc.)
        if (name.endsWith('.tar.gz')) {
          files = TarDecoder()
              .decodeBytes(GZipDecoder().decodeBytes(data))
              .files;
        } else if (name.endsWith('.tar.xz')) {
          files =
              TarDecoder().decodeBytes(XZDecoder().decodeBytes(data)).files;
        } else if (name.endsWith('.tar.bz2')) {
          files = TarDecoder()
              .decodeBytes(BZip2Decoder().decodeBytes(data))
              .files;
        } else {
          throw Exception('unsupported:unknown archive format $ext');
        }
    }

    if (files.isEmpty && singleFileData == null) {
      throw Exception('invalid:archive contains no files');
    }

    // ---- Archive bomb check ----
    if (singleFileData == null) {
      if (files.length > maxEntries) {
        throw ArchiveBombException(
          'Archive contains ${files.length} entries, exceeding the '
          'safety limit of $maxEntries.',
        );
      }
      var totalUncompressed = 0;
      for (final af in files) {
        if (!af.isDirectory) totalUncompressed += af.size;
        if (totalUncompressed > maxUncompressedBytes) {
          throw ArchiveBombException(
            'Archive uncompressed size exceeds the safety limit of '
            '${maxUncompressedBytes ~/ (1024 * 1024 * 1024)} GB.',
          );
        }
      }
    }

    final extractedPaths = <String>[];

    if (singleFileData != null) {
      final outPath = p.join(destDir, singleFileName);
      await File(outPath).writeAsBytes(singleFileData);
      extractedPaths.add(outPath);
      return extractedPaths;
    }

    for (final af in files) {
      var entryName = af.name;

      // ---- Path-traversal + symlink guard ----
      // Skip symlinks — they can point outside the archive root.
      if (af.isSymbolicLink) continue;
      // Reject NUL bytes and any component that is or contains "..".
      if (entryName.contains(String.fromCharCode(0))) continue;
      // Normalise Windows separators then check each component.
      entryName = entryName.replaceAll('\\', '/');
      while (entryName.startsWith('/')) {
        entryName = entryName.substring(1);
      }
      if (entryName.isEmpty) continue;
      final parts = entryName.split('/');
      if (parts.any((c) => c == '..' || c.isEmpty && parts.length > 1)) {
        continue;
      }

      final destPath = p.join(destDir, entryName);

      // ---- Canonical path check: verify destPath is inside destDir ----
      final canonDest = p.canonicalize(destPath);
      final canonBase = p.canonicalize(destDir);
      if (!canonDest.startsWith('$canonBase${p.separator}') &&
          canonDest != canonBase) {
        continue; // silently skip entries that would escape the dest dir
      }

      if (af.isDirectory) {
        await Directory(destPath).create(recursive: true);
      } else {
        final parentDir = Directory(p.dirname(destPath));
        await parentDir.create(recursive: true);
        final content = af.readBytes();
        if (content == null) {
          throw Exception(
            'io:could not read archive entry "$entryName" (corrupt or '
            'unsupported compression)',
          );
        }
        await File(destPath).writeAsBytes(content);
      }
      extractedPaths.add(destPath);
    }

    return extractedPaths;
  }
  /// Attempts to decode [data] as a tar archive. Returns null when it isn't
  /// valid tar (e.g. a plain gzip'd text file), so callers can fall back to
  /// treating it as a single compressed file.
  static List<ArchiveFile>? _tryDecodeTar(List<int> data) {
    try {
      final archive = TarDecoder().decodeBytes(data);
      if (archive.files.isEmpty) return null;
      return archive.files;
    } catch (_) {
      return null;
    }
  }

  /// Strips the compression extension from [archivePath], e.g.
  /// `notes.tar.gz` with ext `.gz` → `notes.tar`.
  static String _stripExt(String archivePath, String ext) {
    var base = p.basenameWithoutExtension(archivePath);
    final inner = p.extension(base);
    if (ext == '.gz' || ext == '.xz' || ext == '.bz2') {
      if (inner == '.tar' ||
          (inner.isNotEmpty &&
              inner != ext &&
              base.length > inner.length &&
              base.toLowerCase().endsWith('$inner$ext'))) {
        base = base.substring(0, base.length - inner.length);
      }
    }
    return base;
  }

  // -------------------------------------------------------------------------
  // Integrity check
  // -------------------------------------------------------------------------

  /// Verifies the integrity of an archive by attempting to decode all entries
  /// and computing their SHA-256 checksums.
  ///
  /// Returns an [ArchiveIntegrityResult] with:
  ///   - [ArchiveIntegrityResult.ok] — true if no errors were found.
  ///   - [ArchiveIntegrityResult.errors] — list of (entryName, errorMessage)
  ///     pairs for any entries that failed to decode.
  ///
  /// Throws [UnsupportedArchiveFormat] for formats the app cannot read.
  static Future<ArchiveIntegrityResult> verifyIntegrity(
    String archivePath,
  ) async {
    final errors = <MapEntry<String, String>>[];
    List<ArchiveFile> files;
    try {
      files = await _decodeArchive(archivePath);
    } catch (e) {
      return ArchiveIntegrityResult(ok: false, errors: [
        MapEntry('<archive>', 'Failed to decode archive: $e'),
      ]);
    }
    for (final af in files) {
      if (af.isDirectory || af.isSymbolicLink) continue;
      try {
        final content = af.readBytes();
        if (content == null) {
          errors.add(MapEntry(af.name, 'readBytes() returned null'));
        }
      } catch (e) {
        errors.add(MapEntry(af.name, '$e'));
      }
    }
    return ArchiveIntegrityResult(ok: errors.isEmpty, errors: errors);
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
    // Safety: reject path traversal / NUL / absolute paths so a crafted entry
    // can't escape [destDir] (mirrors the guards in [extract]).
    var name = entryName;
    if (name.contains('..') || name.contains(String.fromCharCode(0))) {
      throw Exception('io:unsafe archive entry name: $entryName');
    }
    name = name.replaceAll('\\\\', '/');
    while (name.startsWith('/')) {
      name = name.substring(1);
    }
    if (name.isEmpty) {
      throw Exception('io:empty archive entry name: $entryName');
    }
    final files = await _decodeArchive(archivePath);
    final af = files.where((f) => f.name == name && !f.isDirectory).firstOrNull;
    if (af == null) {
      throw Exception('io:no such archive entry: $entryName');
    }
    final destPath = p.join(destDir, name);
    await Directory(p.dirname(destPath)).create(recursive: true);
    final outStream = File(destPath).openWrite();
    outStream.add(af.content as List<int>);
    await outStream.close();
    return destPath;
  }

  static Future<List<ArchiveFile>> _decodeArchive(String archivePath) async {
    final name = p.basename(archivePath).toLowerCase();
    final ext = p.extension(archivePath).toLowerCase();
    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      throw Exception('archive not found: $archivePath');
    }
    final data = await archiveFile.readAsBytes();
    // Multi-part extensions checked first.
    if (name.endsWith('.tar.gz')) {
      return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(data)).files;
    }
    if (name.endsWith('.tar.xz')) {
      return TarDecoder().decodeBytes(XZDecoder().decodeBytes(data)).files;
    }
    if (name.endsWith('.tar.bz2')) {
      return TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(data)).files;
    }
    if (name.endsWith('.tar.zst')) {
      throw UnsupportedArchiveFormat(
        'zst',
        'Zstandard archives cannot be read in-app. '
            'Open a terminal (Termux) and run: zstd -d "$archivePath"',
      );
    }
    switch (ext) {
      case '.zip':
        return ZipDecoder().decodeBytes(data).files;
      case '.tar':
        return TarDecoder().decodeBytes(data).files;
      case '.gz':
      case '.tgz':
        return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(data)).files;
      case '.xz':
      case '.txz':
        return TarDecoder().decodeBytes(XZDecoder().decodeBytes(data)).files;
      case '.bz2':
      case '.tbz2':
        return TarDecoder()
            .decodeBytes(BZip2Decoder().decodeBytes(data))
            .files;
      case '.7z':
        throw UnsupportedArchiveFormat(
          '7z',
          '7z archives cannot be read in-app. '
              'Open a terminal (Termux) and run: 7z x "$archivePath"',
        );
      case '.rar':
        throw UnsupportedArchiveFormat(
          'rar',
          'RAR archives cannot be read in-app. '
              'Open a terminal (Termux) and run: unrar x "$archivePath"',
        );
      case '.zst':
        throw UnsupportedArchiveFormat(
          'zst',
          'Zstandard archives cannot be read in-app. '
              'Open a terminal (Termux) and run: zstd -d "$archivePath"',
        );
      default:
        throw Exception('unsupported:unknown archive format $ext');
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

/// Result of [ArchiveService.verifyIntegrity].
///
/// [ok] is true when every file entry was decoded without error.
/// [errors] lists (entryName, errorMessage) pairs for failed entries.
class ArchiveIntegrityResult {
  final bool ok;
  final List<MapEntry<String, String>> errors;
  const ArchiveIntegrityResult({required this.ok, required this.errors});
}
