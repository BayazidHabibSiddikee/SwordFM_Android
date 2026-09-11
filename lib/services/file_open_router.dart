import 'package:path/path.dart' as p;

import '../utils/file_utils.dart' show isSearchableText, kAudioExtensions, kVideoExtensions;

/// The application entry point that requested a file to be opened.
enum FileOpenSource {
  browse,
  preview,
  search,
  recent,
  externalIntent,
  archive,
}

/// In-app destination selected by [FileOpenRouter].
enum FileOpenTargetType {
  video,
  audio,
  pdf,
  docx,
  image,
  text,
  epub,
  comicBook,
  spreadsheet,
  pptxOutline,
  archive,
  external,
  unsupported,
}

/// A navigation-independent description of how a file should be opened.
class FileOpenTarget {
  final String path;
  final FileOpenSource source;
  final FileOpenTargetType type;
  final bool inApp;
  final bool supportsPlaylist;
  final String? reason;

  const FileOpenTarget({
    required this.path,
    required this.source,
    required this.type,
    required this.inApp,
    this.supportsPlaylist = false,
    this.reason,
  });

  bool get isFullScreen =>
      inApp &&
      const {
        FileOpenTargetType.video,
        FileOpenTargetType.audio,
        FileOpenTargetType.pdf,
        FileOpenTargetType.docx,
        FileOpenTargetType.image,
        FileOpenTargetType.text,
        FileOpenTargetType.epub,
        FileOpenTargetType.comicBook,
        FileOpenTargetType.spreadsheet,
        FileOpenTargetType.archive,
      }.contains(type);
}

/// Resolves file extensions into application-level open targets.
///
/// This class deliberately does not navigate or inspect the filesystem. UI
/// adapters can use the returned target to choose a screen and provide any
/// contextual playlist or preview state available at the call site.
class FileOpenRouter {
  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.heic',
    '.ico',
    '.tif',
    '.tiff',
    '.avif',
    '.jxl',
    '.heif',
    '.raw',
    '.cr2',
    '.nef',
    '.arw',
    '.dng',
    '.psd',
    '.xcf',
    '.tga',
    '.dds',
    '.exr',
    '.hdr',
    '.ktx',
    '.pkm',
    '.pvr',
    '.s3tc',
  };

  static const _spreadsheetExtensions = {
    '.xlsx',
    '.xls',
    '.ods',
    '.csv',
    '.numbers',
  };

  static const _supportedArchiveExtensions = {
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.tar.gz',
    '.xz',
    '.txz',
    '.tar.xz',
    '.bz2',
    '.tbz2',
    '.tar.bz2',
  };

  static const _unsupportedArchiveExtensions = {
    '.7z',
    '.rar',
    '.zst',
    '.tar.zst',
    '.lz',
    '.lzma',
  };

  static const _codeExtensions = {
    '.dart',
    '.py',
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
  };

  /// Resolves [path] without touching the filesystem.
  static FileOpenTarget resolve(
    String path, {
    FileOpenSource source = FileOpenSource.browse,
  }) {
    final lowerPath = path.toLowerCase();
    final ext = p.extension(lowerPath);

    if (kVideoExtensions.contains(ext)) {
      return _target(path, source, FileOpenTargetType.video, playlist: true);
    }
    if (kAudioExtensions.contains(ext)) {
      return _target(path, source, FileOpenTargetType.audio, playlist: true);
    }
    if (ext == '.pdf') {
      return _target(path, source, FileOpenTargetType.pdf);
    }
    if (ext == '.docx') {
      return _target(path, source, FileOpenTargetType.docx);
    }
    if (_imageExtensions.contains(ext)) {
      return _target(path, source, FileOpenTargetType.image);
    }
    if (ext == '.epub') {
      return _target(path, source, FileOpenTargetType.epub);
    }
    if (ext == '.cbz') {
      return _target(path, source, FileOpenTargetType.comicBook);
    }
    if (ext == '.cbr') {
      return _target(
        path,
        source,
        FileOpenTargetType.unsupported,
        inApp: false,
        reason: 'CBR/RAR archives are not supported.',
      );
    }
    if (_spreadsheetExtensions.contains(ext)) {
      return _target(path, source, FileOpenTargetType.spreadsheet);
    }
    if (ext == '.pptx') {
      return _target(
        path,
        source,
        FileOpenTargetType.pptxOutline,
        reason: 'PPTX is supported as an outline preview; full slide rendering is unavailable.',
      );
    }
    if (_supportedArchiveExtensions.contains(ext) ||
        lowerPath.endsWith('.tar.gz') ||
        lowerPath.endsWith('.tar.xz') ||
        lowerPath.endsWith('.tar.bz2')) {
      return _target(path, source, FileOpenTargetType.archive);
    }
    if (_unsupportedArchiveExtensions.contains(ext) ||
        lowerPath.endsWith('.tar.zst')) {
      return _target(
        path,
        source,
        FileOpenTargetType.unsupported,
        inApp: false,
        reason: 'This archive format is not supported.',
      );
    }
    if (isSearchableText(path) || _codeExtensions.contains(ext)) {
      return _target(path, source, FileOpenTargetType.text);
    }

    return _target(
      path,
      source,
      FileOpenTargetType.external,
      inApp: false,
      reason: 'No built-in viewer is available for this file type.',
    );
  }

  static FileOpenTarget _target(
    String path,
    FileOpenSource source,
    FileOpenTargetType type, {
    bool inApp = true,
    bool playlist = false,
    String? reason,
  }) {
    return FileOpenTarget(
      path: path,
      source: source,
      type: type,
      inApp: inApp,
      supportsPlaylist: playlist,
      reason: reason,
    );
  }
}
