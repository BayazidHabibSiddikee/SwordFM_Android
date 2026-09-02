import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';
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
  // Kept for potential diagnostics; no longer drives the error flow (the
  // spawn-time check in the exit handler replaced it).
  // ignore: unused_field
  String? _spawnError;
  /// True while an intentional restart is in flight so the old shell's exit
  /// doesn't trigger the auto-fallthrough logic.
  bool _restarting = false;
  final FocusNode _terminalFocusNode = FocusNode();
  bool _isRoot = false;
  // null = still probing; true/false once the Termux install check has run.
  // The body of the screen is gated on this so a missing Termux surfaces
  // the install-Termux panel *before* we try to spawn a shell (which would
  // always fail with the toybox mksh fallback on most devices).
  bool? _termuxInstalled;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    // width = columns, height = rows; Pty.resize takes (rows, columns).
    _terminal.onResize = (width, height, _, _) {
      _pty?.resize(height, width);
    };
    TerminalService.isInstalled().then((installed) {
      if (mounted) {
        setState(() {
          _termuxInstalled = installed;
          // If Termux is not installed, the embedded shell will not find a
          // usable bash, so the install-Termux panel will be shown by build().
        });
      }
      _checkRoot().then((v) {
        if (mounted) setState(() => _isRoot = v);
        _startShell();
      });
    });
  }

  Future<bool> _checkRoot() async {
    try {
      return await FileUtils.isRooted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startShell({int attempt = 0}) async {
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
    final spawnTime = DateTime.now();

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
      const candidates = <String>[
        '/data/data/com.termux/files/usr/bin/bash',
        '/data/data/com.termux/files/usr/bin/sh',
        '/system/bin/mksh',
        '/system/xbin/mksh',
        '/system/bin/sh',
        '/system/xbin/sh',
        '/bin/sh',
      ];
      final usable = candidates.where((s) => File(s).existsSync()).toList();
      if (attempt >= usable.length) {
        if (mounted) {
          setState(() {
            _spawnError = 'No interactive shell found on this device.\n\n'
                'Install Termux for a full bash shell with a package '
                'manager, or try "Restart shell" after installing it.';
          });
        }
        return;
      }
      shell = usable[attempt];
      final usingTermux = shell.startsWith('/data/data/com.termux');
      envHome = cwd;
      shellPath = usingTermux
          ? '/data/data/com.termux/files/usr/bin:'
                '/data/data/com.termux/files/usr/bin/applets:'
                '/system/bin:/system/xbin:/product/bin:/vendor/bin'
          : '/system/bin:/system/xbin:/product/bin:/vendor/bin';
    }

    if (mounted) setState(() => _spawnError = null);

    try {
      final String execShell = _isRoot ? 'su' : shell;
      final List<String> args = const <String>[];
      final pty = Pty.start(
        execShell,
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

      // Track when the shell exits. A shell that dies within 1.5s of spawn is
      // not usable as an interactive terminal — instead of dead-ending with an
      // error, automatically fall through to the next candidate shell (this is
      pty.exitCode.then((code) {
        if (_restarting) return; // intentional restart — handled separately
        _terminal.write(
            '\r\n\x1b[2m[Process exited with code $code]\x1b[0m\r\n');
        if (mounted) setState(() => _pty = null);
        final ranMs = DateTime.now().difference(spawnTime).inMilliseconds;
        if (ranMs < 1500 && mounted) {
          if (_isRoot) {
            if (mounted) {
              setState(() {
                _spawnError =
                    'Root shell exited immediately. Device may not be rooted '
                    'or su is unavailable.';
              });
            }
          } else {
            _startShell(attempt: attempt + 1);
          }
        }
      });

      // Keyboard/IME input → shell. Encode as UTF-8 so non-ASCII input is
      // written correctly (codeUnits would emit raw UTF-16 code units).
      _terminal.onOutput = (data) {
        _pty?.write(utf8.encode(data));
      };

      if (mounted) setState(() => _pty = pty);
    } catch (e) {
      debugPrint('Terminal spawn error ($shell): $e');
      // Spawn failure — fall through to the next candidate shell before
      // giving up (unless this was the root path).
      if (mounted && !_isRoot) {
        _startShell(attempt: attempt + 1);
      } else if (mounted) {
        setState(() => _spawnError = e.toString());
      }
    }
  }

  /// Quick probe: can we create a file here? Scoped-storage dirs that only
  /// allow media writes reject plain file creation.
  static bool _canWrite(String dirPath) {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return false;
      // Just check directory exists and is listable — probe files fail on
      // Android scoped storage even for writable dirs.
      dir.listSync();
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
    // PopScope forces the Android system back button / predictive back gesture
    // to pop the route. Without this on Android 14+ (target SDK 37), the
    // auto-focus on the embedded xterm can swallow the back event so the user
    // gets stuck on the terminal screen.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          // Should not happen (canPop: true) but be defensive: if the
          // navigator didn't pop, kill the shell and force-pop manually so
          // the user can never get stuck.
          try {
            _pty?.kill();
          } catch (_) {}
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
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
              _restarting = true;
              _pty?.kill();
              _startShell().then((_) => _restarting = false);
            },
            tooltip: 'Restart shell',
          ),
        ],
      ),
      body: _TermuxMissingBody(
        installed: _termuxInstalled,
        onInstall: () async {
          await TerminalService.openInstallPage();
        },
        onRetry: () async {
          // Re-probe Termux install state — user may have just installed it.
          final installed = await TerminalService.isInstalled();
          if (mounted) {
            setState(() => _termuxInstalled = installed);
            if (installed) _startShell();
          }
        },
        child: _spawnError != null
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
                    TextButton(
                      onPressed: () {
                        setState(() => _spawnError = null);
                        _startShell();
                      },
                      child: Text(
                        'Retry with temp directory',
                        style: TextStyle(
                            color: OneDarkColors.cyan, fontSize: 12),
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
                        if (_termuxInstalled == true)
                          _TermuxHandoffBar(
                            onOpenTermux: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final ok = await TerminalService.openTerminalAt(
                                widget.startPath,
                              );
                              if (!ok && mounted) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Could not launch Termux. Make sure '
                                      '"Allow external apps" is enabled in '
                                      'Termux settings.',
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        Expanded(
                    child: GestureDetector(
                      // Tap anywhere on the terminal to focus and raise the
                      // on-screen keyboard (the default keyboardType is
                      // emailAddress, which shows @/.com keys — unusable for
                      // a shell).
                      onTap: () =>
                          _terminalFocusNode.requestFocus(),
                      child: PopScope(
                        // canPop: false means Flutter delivers the back
                        // press to onPopInvokedWithResult; we then decide
                        // whether to pop the route or forward a backspace
                        // (Ctrl-H / 0x7F) to the PTY. The xterm's hidden
                        // EditableText would otherwise eat the back key
                        // for soft-keyboard backspace and the navigator
                        // never sees the press.
                        canPop: false,
                        onPopInvokedWithResult: (didPop, _) {
                          if (didPop) return;
                          // The user pressed back. The simplest reliable
                          // behavior: pop the screen. If we wanted to be
                          // fancy, we'd inspect the xterm's input buffer
                          // and forward a backspace if non-empty — but the
                          // xterm package doesn't expose that, and the
                          // soft-keyboard already has a backspace key for
                          // the in-shell use case. So back always pops.
                          try {
                            _pty?.kill();
                          } catch (_) {}
                          if (mounted) {
                            Navigator.of(context).pop();
                          }
                        },
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
  /// `apt` when available; otherwise a helpful note). Renders the hint on the
  /// terminal DISPLAY (never into the PTY — writing to the PTY would feed the
  /// banner text to the shell as commands, which is exactly what happened
  /// when toybox sh echoed "inaccessible or not found" for every line).
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
    // Display-only write — the shell never sees this text.
    _terminal.write(msg);
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

/// Top-of-terminal bar shown only when Termux is installed. Gives the user a
/// one-tap handoff to a full Termux session in the current directory, which
/// is far better than the embedded xterm (real package manager, scrolling
/// history, copy/paste, etc.). The embedded xterm remains the default view.
class _TermuxHandoffBar extends StatelessWidget {
  final Future<void> Function() onOpenTermux;
  const _TermuxHandoffBar({required this.onOpenTermux});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: OneDarkColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.terminal, size: 14, color: OneDarkColors.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Termux is installed — open a full session in this folder.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onOpenTermux,
            icon: Icon(Icons.open_in_new, size: 14, color: OneDarkColors.cyan),
            label: Text(
              'Open in Termux',
              style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Gates the terminal body on Termux availability. When [installed] is
/// `false`, shows the install-Termux panel (so the user is guided to F-Droid
/// or Play Store) instead of the failed-spawn error path the old code used
/// to fall into. When [installed] is `null`, shows a tiny spinner. When
/// `true`, renders the supplied [child] (the original spawn-error / xterm
/// body).
class _TermuxMissingBody extends StatelessWidget {
  final bool? installed;
  final Future<void> Function() onInstall;
  final Future<void> Function() onRetry;
  final Widget child;

  const _TermuxMissingBody({
    required this.installed,
    required this.onInstall,
    required this.onRetry,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (installed == null) {
      return Center(
        child: CircularProgressIndicator(color: OneDarkColors.cyan),
      );
    }
    if (installed == true) {
      return child;
    }
    return _InstallTermuxPanel(onInstall: onInstall, onRetry: onRetry);
  }
}

class _InstallTermuxPanel extends StatelessWidget {
  final Future<void> Function() onInstall;
  final Future<void> Function() onRetry;
  const _InstallTermuxPanel({required this.onInstall, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final accent = OneDarkColors.amber;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.terminal, size: 56, color: accent),
            const SizedBox(height: 12),
            Text(
              'Termux is not installed',
              style: TextStyle(color: OneDarkColors.fg, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'SwordFM needs Termux to provide a real bash shell with a '
              'package manager (pkg / apt). Without it, the embedded shell '
              'is just the Android toybox mksh and is not useful for real '
              'work.',
              style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onInstall,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Install Termux (F-Droid)'),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, size: 16, color: OneDarkColors.cyan),
              label: Text(
                'I just installed it — retry',
                style: TextStyle(color: OneDarkColors.cyan, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
