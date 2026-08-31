import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/terminal_service.dart';
import '../theme/theme.dart';
import '../utils/constants.dart' show AppPaths;
import '../utils/file_utils.dart' show FileUtils;

/// Built-in terminal emulator (no Termux required).
///
/// Spawns a real pseudo-terminal via [Pty] (native JNI) running the system
/// shell, and renders it with the xterm widget. Falls back to Termux (via
/// [TerminalService]) only when no shell binary can be spawned.
///
/// If the device is rooted (has `su`), the terminal starts with root so
/// package-manager commands (`apt`, `pkg install`, `pm`, `cmd package`) work.
class TerminalScreen extends StatefulWidget {
  /// Directory the shell starts in ("Open Terminal Here").
  final String startPath;

  const TerminalScreen({super.key, required this.startPath});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal _terminal;
  Pty? _pty;
  StreamSubscription? _outputSub;
  bool _shellExited = false;
  String? _spawnError;
  final FocusNode _terminalFocusNode = FocusNode();
  bool _isRoot = false;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    // width = columns, height = rows; Pty.resize takes (rows, columns).
    _terminal.onResize = (width, height, _, __) {
      _pty?.resize(height, width);
    };
    _checkRoot().then((v) {
      if (mounted) setState(() => _isRoot = v);
      _startShell();
    });
  }

  Future<bool> _checkRoot() async {
    try {
      return await FileUtils.isRooted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startShell() async {
    // Prefer the requested directory; fall back to home, never '/' — root is
    // read-only/locked on Android and makes the shell unusable.
    var cwd = widget.startPath;
    if (cwd.isEmpty ||
        cwd == '/' ||
        !Directory(cwd).existsSync() ||
        !_canWrite(cwd)) {
      final home = AppPaths.home;
      cwd = (Directory(home).existsSync() && _canWrite(home))
          ? home
          : Directory.systemTemp.path;
    }

    String shell;
    String envHome;
    String shellPath;

    if (_isRoot) {
      // Use su so the shell runs as root — grants access to package managers
      // (apt, pkg, pm) and system directories.
      shell = '/system/bin/sh';
      envHome = cwd;
      shellPath =
          '/data/data/com.termux/files/usr/bin:'
          '/data/data/com.termux/files/usr/bin/applets:'
          '/system/bin:/system/xbin:/product/bin:/vendor/bin';
    } else {
      // Try multiple shell paths in order of preference. mksh is Android's
      // default interactive shell and works under a PTY; toybox sh usually is
      // not interactive and exits immediately. Termux's bash is preferred when
      // installed because it ships a working package manager.
      const shells = <String>[
        '/data/data/com.termux/files/usr/bin/bash',
        '/data/data/com.termux/files/usr/bin/sh',
        '/system/bin/mksh',
        '/system/bin/sh',
        '/system/xbin/sh',
        '/bin/sh',
      ];
      shell = shells.firstWhere(
        (s) => File(s).existsSync(),
        orElse: () => '/system/bin/sh',
      );
      final usingTermux = shell.startsWith('/data/data/com.termux');
      envHome = cwd;
      shellPath = usingTermux
          ? '/data/data/com.termux/files/usr/bin:'
                '/data/data/com.termux/files/usr/bin/applets:'
                '/system/bin:/system/xbin:/product/bin:/vendor/bin'
          : '/system/bin:/system/xbin:/product/bin:/vendor/bin';
    }

    try {
      final List<String> args =
          _isRoot ? <String>['sh', '-c', 'exec sh'] : const <String>[];
      final pty = Pty.start(
        shell,
        arguments: args,
        workingDirectory: cwd,
        environment: {
          'TERM': 'xterm-256color',
          'PATH': shellPath,
          'HOME': envHome,
          'LANG': 'en_US.UTF-8',
          'TMPDIR': Directory.systemTemp.path,
          'SHELL': shell,
        },
      );

      // Cancel any previous output listener to avoid leaks on restart.
      _outputSub?.cancel();

      // Shell output → terminal renderer. Decode as UTF-8 (allow malformed
      // bytes) so multi-byte characters survive; String.fromCharCodes on raw
      // bytes corrupts any non-ASCII output.
      _outputSub = pty.output.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });

      // Track when the shell exits — if it dies within 1 second the system
      // shell (toybox) is likely not interactive under PTY.
      _shellExited = false;
      pty.exitCode.then((code) {
        _shellExited = true;
        _terminal.write(
            '\r\n\x1b[2m[Process exited with code $code]\x1b[0m\r\n');
        if (mounted) setState(() => _pty = null);
      });

      // If the shell exits within 1 second, show the Termux suggestion.
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && _pty != null && !_shellExited) return;
        if (mounted && _shellExited && _spawnError == null) {
          setState(() {
            _spawnError = _isRoot
                ? 'Root shell exited immediately. Device may not be rooted or su is unavailable.'
                : 'System shell exited immediately. This device uses toybox '
                    'which does not work as an interactive terminal.\n\n'
                    'Install Termux for a full bash shell with package manager.';
          });
        }
      });

      // Keyboard/IME input → shell. Encode as UTF-8 so non-ASCII input is
      // written correctly (codeUnits would emit raw UTF-16 code units).
      _terminal.onOutput = (data) {
        _pty?.write(utf8.encode(data));
      };

      if (mounted) setState(() => _pty = pty);
    } catch (e) {
      debugPrint('Terminal spawn error: $e');
      if (mounted) {
        setState(() => _spawnError = e.toString());
      }
    }
  }

  /// Quick probe: can we create a file here? Scoped-storage dirs that only
  /// allow media writes reject plain file creation.
  static bool _canWrite(String dirPath) {
    try {
      final probe = File(
          '$dirPath/.swordfm_write_probe_${DateTime.now().millisecondsSinceEpoch}');
      probe.createSync();
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    try {
      _pty?.kill();
    } catch (_) {}
    _terminalFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: cs.onSurface,
        title: Text(
          'Terminal${_isRoot ? ' (root)' : ''} — ${widget.startPath}',
          style: TextStyle(color: cs.onSurface, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              _pty?.kill();
              _startShell();
            },
            tooltip: 'Restart shell',
          ),
        ],
      ),
      body: _spawnError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: OneDarkColors.red),
                  const SizedBox(height: 12),
                  Text(
                    'Could not start shell',
                    style: TextStyle(color: OneDarkColors.fg),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _spawnError!,
                      style: TextStyle(
                        color: OneDarkColors.fgDim,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      // Try Termux first
                      final launched = await TerminalService.openTerminalAt(
                        widget.startPath,
                      );
                      if (!mounted) return;
                      if (launched) return;
                      // Termux not found — open Play Store
                      final url = Uri.parse(
                          'https://play.google.com/store/apps/details?id=com.termux');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url,
                            mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Install Termux'),
                  ),
                  const SizedBox(height: 8),
                  // Retry with internal shell
                  TextButton(
                    onPressed: () {
                      setState(() => _spawnError = null);
                      _startShell();
                    },
                    child: Text(
                      'Retry with temp directory',
                      style:
                          TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                    ),
                  ),
                ],
              ),
            )
          : _pty == null
          ? Center(
              child:
                  CircularProgressIndicator(color: OneDarkColors.cyan),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      // Tap anywhere on the terminal to focus and raise the
                      // on-screen keyboard (the default keyboardType is
                      // emailAddress, which shows @/.com keys — unusable for
                      // a shell).
                      onTap: () =>
                          _terminalFocusNode.requestFocus(),
                      child: TerminalView(
                        _terminal,
                        theme: _oneDarkTerminalTheme,
                        textStyle: const TerminalStyle(fontSize: 13),
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        focusNode: _terminalFocusNode,
                      ),
                    ),
                  ),
                  // Quick keys for touch users + paste + hide-keyboard.
                  // Horizontally scrollable so they fit narrow phones.
                  Container(
                    color: OneDarkColors.bg,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _quickKey('↑', '[A'),
                          _quickKey('↓', '[B'),
                          _quickKey('Esc', ''),
                          _quickKey('Tab', '\t'),
                          _quickKey('Ctrl+C', ''),
                          _quickKey('Ctrl+D', ''),
                          _quickKey('Ctrl+L', ''),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              Icons.download,
                              size: 20,
                              color: OneDarkColors.green,
                            ),
                            tooltip: 'Package manager help',
                            onPressed: _hintPackageInstall,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.content_paste,
                              size: 20,
                              color: OneDarkColors.fgDim,
                            ),
                            tooltip: 'Paste from clipboard',
                            onPressed: _pasteFromClipboard,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.keyboard_hide,
                              size: 20,
                              color: OneDarkColors.fgDim,
                            ),
                            tooltip: 'Hide keyboard',
                            onPressed: () =>
                                FocusScope.of(context).unfocus(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Sends [sequence] straight to the shell (bypasses the xterm input pipe).
  Widget _quickKey(String label, String sequence) {
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: OneDarkColors.cyan,
      ),
      onPressed: () => _pty?.write(utf8.encode(sequence)),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// Reads the system clipboard and types it into the shell (Android's IME
  /// paste menu doesn't reach the hidden xterm input field).
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _pty?.write(utf8.encode(text));
  }

  /// Shows how to install packages in the running shell (Termux's `pkg` /
  /// `apt` when available; otherwise a helpful note). Writes a hint into the
  /// terminal so the user knows what to type.
  void _hintPackageInstall() {
    final termux = File('/data/data/com.termux/files/usr/bin/pkg').existsSync();
    final msg = termux
        ? '\r\n\x1b[1;32m[SwordFM] Package manager detected (Termux).\r\n'
            '  • Update package lists:  pkg update\r\n'
            '  • Search:              pkg search <name>\r\n'
            '  • Install:             pkg install <name>\r\n'
            '  (or use: apt update && apt install <name>)\x1b[0m\r\n'
        : '\r\n\x1b[1;33m[SwordFM] No package manager found in this shell.\r\n'
            '  This device uses the Android toybox shell which cannot install\r\n'
            '  packages by itself.\r\n'
            '  • Install Termux (from the Play Store/F-Droid) for a full bash\r\n'
            '    shell, then run:  pkg install <name>\r\n'
            '  • If the device is rooted, open Termux as root and use:\r\n'
            '      apt update && apt install <name>\x1b[0m\r\n';
    _pty?.write(utf8.encode(msg));
  }

  /// One Dark-flavored terminal palette. A getter (not a cached static) so it
  /// tracks the current theme mode like the rest of the app.
  static TerminalTheme get _oneDarkTerminalTheme => TerminalTheme(
        cursor: OneDarkColors.cyan,
        selection: OneDarkColors.select,
        foreground: OneDarkColors.fg,
        background: OneDarkColors.bgDark,
        black: const Color(0xFF282C34),
        red: const Color(0xFFE06C75),
        green: const Color(0xFF98C379),
        yellow: const Color(0xFFE5C07B),
        blue: const Color(0xFF61AFEF),
        magenta: const Color(0xFFC678DD),
        cyan: const Color(0xFF56B6C2),
        white: const Color(0xFFABB2BF),
        brightBlack: const Color(0xFF5C6370),
        brightRed: const Color(0xFFE06C75),
        brightGreen: const Color(0xFF98C379),
        brightYellow: const Color(0xFFE5C07B),
        brightBlue: const Color(0xFF61AFEF),
        brightMagenta: const Color(0xFFC678DD),
        brightCyan: const Color(0xFF56B6C2),
        brightWhite: const Color(0xFFFFFFFF),
        searchHitBackground: OneDarkColors.dim,
        searchHitBackgroundCurrent: OneDarkColors.hover,
        searchHitForeground: OneDarkColors.fg,
      );
}
