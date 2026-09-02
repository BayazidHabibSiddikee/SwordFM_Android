import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, PlatformException, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// High-fidelity document conversion via the bundled Termux Python engine
/// (`assets/conv/swordconv.py`, a trimmed port of the original SwordFM
/// `tools/swordconv`).
///
/// Strategy:
///   * On Android, prefer Termux's python at
///     `/data/data/com.termux/files/usr/bin/python3`. If Termux is not
///     installed (or python deps are missing), the public API still returns
///     null so the caller can transparently fall back to the pure-Dart
///     `DocConverter`.
///   * On other platforms (Linux desktop test, etc.) we look for system
///     `python3` and use the same script.
///   * The python script is shipped as a Flutter asset and unpacked into the
///     app cache on first use.
///
/// Deliberately no LibreOffice/pandoc and no pdf2docx/opencv (see plan.md
/// Phase 10). PDF→DOCX is a text re-layout into a real editable Word doc.
class ConversionToolService {
  static const _pythonTermux =
      '/data/data/com.termux/files/usr/bin/python3';
  static const _scriptAsset = 'assets/conv/swordconv.py';
  // Same channel the existing TerminalService uses; routed in MainActivity.kt
  // and lets us dispatch a one-shot RUN_COMMAND intent.
  static const MethodChannel _channel = MethodChannel('com.swordfm/terminal');

  /// Cached script path inside the app cache, so we only extract once.
  String? _scriptPath;

  /// True if the bundled engine is ready to run. Re-checks every call so a
  /// Termux install that lands mid-session is picked up immediately.
  Future<bool> isAvailable() async {
    final py = _pythonPath();
    if (py == null) return false;
    if (!await File(py).exists()) return false;
    final script = await _ensureScript();
    return script != null;
  }

  /// Runs the conversion: `<target> <input> <output>`. Returns the output
  /// path on success, or null on any failure (so callers can fall back).
  /// [target] is one of: pdf, docx, md, txt, html (case-insensitive).
  /// [onProgress] receives a status string for UI feedback; safe to ignore.
  Future<String?> convert({
    required String target,
    required String inputPath,
    required String outputPath,
    void Function(String)? onProgress,
  }) async {
    final py = _pythonPath();
    if (py == null) return null;
    if (!await File(py).exists()) {
      onProgress?.call('Termux python not found');
      return null;
    }
    final script = await _ensureScript();
    if (script == null) {
      onProgress?.call('Could not unpack conversion script');
      return null;
    }
    if (!await File(inputPath).exists()) {
      onProgress?.call('Input file not found');
      return null;
    }
    // Make sure the output dir exists — the script does not create parents.
    try {
      await Directory(p.dirname(outputPath)).create(recursive: true);
    } catch (_) {}

    onProgress?.call('Running python converter…');
    try {
      final result = await Process.run(
        py,
        [script, target, inputPath, outputPath],
        // Match Termux home; on other platforms harmless.
        environment: {
          'PYTHONIOENCODING': 'utf-8',
          'LANG': 'C.UTF-8',
        },
      );
      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        debugPrint('swordconv failed (code ${result.exitCode}): $stderr');
        onProgress?.call(stderr.isNotEmpty ? stderr : 'Conversion failed');
        return null;
      }
      if (!await File(outputPath).exists()) {
        onProgress?.call('Converter wrote no output');
        return null;
      }
      return outputPath;
    } on ProcessException catch (e) {
      debugPrint('swordconv ProcessException: $e');
      onProgress?.call(e.message);
      return null;
    }
  }

  /// One-shot module check used by the install/upgrade dialog. Returns the
  /// list of missing module names (empty list == everything is good). The
  /// caller can show the appropriate `pip install` hint via [installHintFor].
  Future<List<String>> missingModules() async {
    const modules = ['fitz', 'docx', 'mammoth', 'bs4', 'markdown'];
    final py = _pythonPath();
    if (py == null || !await File(py).exists()) return const [];
    final missing = <String>[];
    for (final m in modules) {
      try {
        final r = await Process.run(py,
            ['-c', 'import importlib; importlib.import_module("$m")']);
        if (r.exitCode != 0) missing.add(m);
      } catch (_) {
        missing.add(m);
      }
    }
    return missing;
  }

  /// Maps the missing-module name to the matching `pip install` package.
  /// `bs4` is the import name; `beautifulsoup4` is the pip package.
  static String pipNameFor(String module) {
    switch (module) {
      case 'bs4':
        return 'beautifulsoup4';
      case 'fitz':
        return 'pymupdf';
      case 'docx':
        return 'python-docx';
      default:
        return module;
    }
  }

  /// Hint string for the install dialog. Always mentions Termux first because
  /// the script lives there.
  static String installHintFor(List<String> modules) {
    if (modules.isEmpty) return '';
    final pkgs = modules.map(pipNameFor).toSet().toList()..sort();
    return 'pkg install python && pip install ${pkgs.join(' ')}';
  }

  // -------------------------------------------------------------------------
  // internals
  // -------------------------------------------------------------------------

  String? _pythonPath() {
    if (Platform.isAndroid) return _pythonTermux;
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return 'python3';
    }
    return null;
  }

  Future<String?> _ensureScript() async {
    if (_scriptPath != null && await File(_scriptPath!).exists()) {
      return _scriptPath;
    }
    try {
      final cache = await getTemporaryDirectory();
      final dir = Directory(p.join(cache.path, 'swordfm_conv'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final outFile = File(p.join(dir.path, 'swordconv.py'));
      // Unpack from assets every cold start — the script is ~13KB, cheap.
      final data = await rootBundle.load(_scriptAsset);
      await outFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      _scriptPath = outFile.path;
      return _scriptPath;
    } catch (e) {
      debugPrint('Could not extract swordconv.py: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Install / bootstrap
  //
  // The dialog exposes an "install converter" button when the toolchain is
  // not ready. The possible states are:
  //   * Termux app not installed        -> user must install from Play Store
  //   * Termux installed, no python     -> run "pkg install python" in Termux
  //   * python present, modules missing -> run "pip install ..." in Termux
  //   * everything ready                -> nothing to do
  // -------------------------------------------------------------------------

  /// Coarse-grained status for the install button.
  Future<ToolchainStatus> status() async {
    if (!Platform.isAndroid) {
      // Non-Android: treat as ready when system python exists; otherwise
      // "noTermux" so the UI can show the install hint.
      final py = _pythonPath();
      if (py != null && await File(py).exists()) {
        return const ToolchainStatus(ToolchainState.ready, '');
      }
      return const ToolchainStatus(
          ToolchainState.termuxMissing, 'System python3 not found');
    }
    final installed = await _termuxInstalled();
    if (!installed) {
      return const ToolchainStatus(
          ToolchainState.termuxMissing, 'Install Termux from the Play Store');
    }
    if (!await File(_pythonTermux).exists()) {
      return const ToolchainStatus(
          ToolchainState.pythonMissing, 'Install python in Termux');
    }
    final missing = await missingModules();
    if (missing.isNotEmpty) {
      return ToolchainStatus(
          ToolchainState.modulesMissing,
          'Install python modules: '
          '${missing.map(pipNameFor).toSet().join(' ')}');
    }
    return const ToolchainStatus(ToolchainState.ready, '');
  }

  /// Runs [command] inside Termux via the existing `com.swordfm/terminal`
  /// channel. Returns true when the intent was dispatched; false if Termux
  /// is missing or the platform doesn't support it.
  Future<bool> _runInTermux(String command) async {
    try {
      final ok = await _channel.invokeMethod<bool>('runInTermux', {
        'command': command,
      });
      return ok == true;
    } on PlatformException {
      return false;
    }
  }

  /// Asks the native side whether the Termux app is installed. Falls back
  /// to the filesystem probe so a non-Android host (or missing plugin) still
  /// works for unit tests.
  Future<bool> _termuxInstalled() async {
    try {
      final v = await _channel.invokeMethod<bool>('isTermuxInstalled');
      if (v != null) return v;
    } on PlatformException {
      // fall through
    } catch (_) {
      // fall through
    }
    return File(_pythonTermux).existsSync();
  }

  /// The user-facing install action: dispatches the right command based on
  /// the current [ToolchainState]. The native side runs the command in
  /// Termux asynchronously (BACKGROUND=true), so this returns as soon as
  /// the intent is dispatched. Callers should re-check [status] after a
  /// short delay (or after the user comes back) to confirm the install
  /// actually completed.
  ///
  /// Returns a human-readable status string suitable for a SnackBar.
  Future<String> installMissing() async {
    final s = await status();
    switch (s.state) {
      case ToolchainState.ready:
        return 'Converter is already ready.';
      case ToolchainState.termuxMissing:
        return 'Please install Termux from the Play Store, then return here.';
      case ToolchainState.pythonMissing:
        final ok = await _runInTermux('pkg install -y python');
        return ok
            ? 'Installing python in Termux… return here in a minute and try again.\n\n'
                'If the install never started, open Termux → Settings → Security → '
                'enable "Allow external apps".'
            : 'Could not start the install. Open Termux and run: '
                'pkg install python\n\n'
                'Tip: in Termux settings, enable "Allow external apps" so '
                'SwordFM can run commands there.';
      case ToolchainState.modulesMissing:
        final modules = await missingModules();
        final pkgs = modules.map(pipNameFor).toSet().toList()..sort();
        final cmd = 'pip install ${pkgs.join(' ')}';
        final ok = await _runInTermux(cmd);
        return ok
            ? 'Installing ${pkgs.join(', ')} in Termux… '
                'return here in a minute and try again.\n\n'
                'If the install never started, open Termux → Settings → Security → '
                'enable "Allow external apps".'
            : 'Could not start the install. Open Termux and run: $cmd\n\n'
                'Tip: in Termux settings, enable "Allow external apps" so '
                'SwordFM can run commands there.';
    }
  }
}

/// State of the conversion toolchain — drives the install button label.
enum ToolchainState {
  ready,
  termuxMissing,
  pythonMissing,
  modulesMissing,
}

class ToolchainStatus {
  final ToolchainState state;
  final String hint;
  const ToolchainStatus(this.state, this.hint);
}
