import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/terminal_service.dart';
import '../theme/theme.dart';
import '../utils/constants.dart' show AppPaths;

/// Built-in terminal emulator (no Termux required).
///
/// Spawns a real pseudo-terminal via [Pty] (native JNI) running the system
/// shell, and renders it with the xterm widget. Falls back to Termux (via
/// [TerminalService]) only when no shell binary can be spawned.
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
  String? _spawnError;
  final FocusNode _terminalFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    // width = columns, height = rows; Pty.resize takes (rows, columns).
    _terminal.onResize = (width, height, _, __) {
      _pty?.resize(height, width);
    };
    _startShell();
  }

  Future<void> _startShell() async {
    // Prefer the requested directory; fall back to home, never '/' — root is
    // read-only/locked on Android and makes the shell unusable. Home is only
    // used when it is actually writable (needs "All files access"), otherwise
    // the shell lands in the app's own writable temp dir.
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
    // Prefer Termux's shell when installed — it ships a package manager
    // (pkg/apt), so `pkg install python` / `pkg install cmatrix` work. The
    // bare /system/bin/sh has no package manager at all.
    const termuxShell = '/data/data/com.termux/files/usr/bin/bash';
    final usingTermux = File(termuxShell).existsSync();
    final shell = usingTermux
        ? termuxShell
        : (File('/system/bin/sh').existsSync() ? '/system/bin/sh' : '/bin/sh');
    final shellPath = usingTermux
        ? '/data/data/com.termux/files/usr/bin:'
              '/data/data/com.termux/files/usr/bin/applets:'
              '/system/bin:/system/xbin:/product/bin:/vendor/bin'
        : '/system/bin:/system/xbin:/product/bin:/vendor/bin';

    try {
      final pty = Pty.start(
        shell,
        workingDirectory: cwd,
        environment: {
          'TERM': 'xterm-256color',
          'PATH': shellPath,
          'HOME': cwd,
          'LANG': 'en_US.UTF-8',
          'TMPDIR': Directory.systemTemp.path,
        },
      );

      // Shell output → terminal renderer.
      pty.output.listen((data) {
        _terminal.write(String.fromCharCodes(data));
      });
      pty.exitCode.then((code) {
        _terminal.write('\r\n\x1b[2m[Process exited with code $code]\x1b[0m\r\n');
        if (mounted) setState(() => _pty = null);
      });

      // Keyboard/IME input → shell.
      _terminal.onOutput = (data) {
        _pty?.write(Uint8List.fromList(data.codeUnits));
      };

      if (mounted) setState(() => _pty = pty);
    } catch (e) {
      if (mounted) setState(() => _spawnError = e.toString());
    }
  }

  /// Quick probe: can we create a file here? Scoped-storage dirs that only
  /// allow media writes reject plain file creation.
  static bool _canWrite(String dirPath) {
    try {
      final probe = File(
        '$dirPath/.swordfm_write_probe_${DateTime.now().millisecondsSinceEpoch}',
      );
      probe.createSync();
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
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
          'Terminal — ${widget.startPath}',
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
                      final url = Uri.parse('https://play.google.com/store/apps/details?id=com.termux');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
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
                      style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
                    ),
                  ),
                ],
              ),
            )
          : _pty == null
          ? Center(
              child: CircularProgressIndicator(color: OneDarkColors.cyan),
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
                        _quickKey('↑', '\u001b[A'),
                        _quickKey('↓', '\u001b[B'),
                        _quickKey('Esc', '\u001b'),
                        _quickKey('Tab', '\t'),
                        _quickKey('Ctrl+C', '\u0003'),
                        _quickKey('Ctrl+D', '\u0004'),
                        _quickKey('Ctrl+L', '\u000c'),
                        const Spacer(),
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
                          onPressed: () => FocusScope.of(context).unfocus(),
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
      onPressed: () =>
          _pty?.write(Uint8List.fromList(sequence.codeUnits)),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// Reads the system clipboard and types it into the shell (Android's IME
  /// paste menu doesn't reach the hidden xterm input field).
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _pty?.write(Uint8List.fromList(text.codeUnits));
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
