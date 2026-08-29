import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
import '../services/terminal_service.dart';
import '../theme/theme.dart';

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
    final cwd = Directory(widget.startPath).existsSync()
        ? widget.startPath
        : '/';
    // /system/bin/sh always exists on Android; try the fuller shells first.
    final candidates = ['/system/bin/sh', '/bin/sh'];
    final shell = candidates.firstWhere(
      (c) => File(c).existsSync(),
      orElse: () => candidates.first,
    );

    try {
      final pty = Pty.start(
        shell,
        workingDirectory: cwd,
        environment: {
          'TERM': 'xterm-256color',
          'PATH': '/system/bin:/system/xbin:/product/bin:/vendor/bin',
          'HOME': widget.startPath,
          'LANG': 'en_US.UTF-8',
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

  @override
  void dispose() {
    try {
      _pty?.kill();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bgDark,
      appBar: AppBar(
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        title: Text(
          'Terminal — ${widget.startPath}',
          style: TextStyle(color: OneDarkColors.fg, fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
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
                      final launched = await TerminalService.openTerminalAt(
                        widget.startPath,
                      );
                      if (!mounted || launched) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('Termux is not installed'),
                          backgroundColor: OneDarkColors.amber,
                        ),
                      );
                    },
                    icon: const Icon(Icons.terminal, size: 16),
                    label: const Text('Try Termux instead'),
                  ),
                ],
              ),
            )
          : _pty == null
          ? Center(
              child: CircularProgressIndicator(color: OneDarkColors.cyan),
            )
          : SafeArea(
              child: TerminalView(
                _terminal,
                theme: _oneDarkTerminalTheme,
                textStyle: const TerminalStyle(fontSize: 13),
              ),
            ),
    );
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
