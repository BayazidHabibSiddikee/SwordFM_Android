import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import '../theme/theme.dart';
import '../utils/constants.dart' show AppPaths;
import '../utils/file_utils.dart' show FileUtils;

/// Built-in terminal emulator.
///
/// Spawns a real pseudo-terminal via [Pty] (native JNI) running the system
/// shell, and renders it with the xterm widget. The Android toybox shell
/// is what's used by default — it works for `ls`, `cat`, `cd`, and other
/// basic file operations. If the device is rooted (has `su`), the
/// terminal starts as root so package-manager commands work.
///
/// Note: the Android toybox shell cannot install packages by itself. For
/// real package management (apt / pkg), the user needs a separate app
/// like Termux from F-Droid — but this is a simple terminal, not a
/// package manager.
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
  String? _spawnError;
  /// True while an intentional restart is in flight so the old shell's exit
  /// doesn't trigger the auto-fallthrough logic.
  bool _restarting = false;
  final FocusNode _terminalFocusNode = FocusNode();
  bool _isRoot = false;
  /// The Termux-install hint banner. Shown by default so the user knows
  /// there's a fuller option. Dismissable — once dismissed, it stays
  /// gone for the session.
  bool _showTermuxHint = true;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    // width = columns, height = rows; Pty.resize takes (rows, columns).
    _terminal.onResize = (width, height, _, _) {
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
      shell = '/system/bin/sh';
      envHome = cwd;
      shellPath =
          '/system/bin:/system/xbin:/product/bin:/vendor/bin';
    } else {
      // Try multiple shell paths in order of preference. mksh is Android's
      // default interactive shell and works under a PTY; toybox sh usually is
      // not interactive and exits immediately.
      const candidates = <String>[
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
            _spawnError = 'No interactive shell found on this device.';
          });
        }
        return;
      }
      shell = usable[attempt];
      envHome = cwd;
      shellPath = '/system/bin:/system/xbin:/product/bin:/vendor/bin';
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
      // bytes) so multi-byte characters survive.
      _outputSub = pty.output.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });

      // Track when the shell exits. A shell that dies within 1.5s of spawn
      // is not usable — fall through to the next candidate shell.
      pty.exitCode.then((code) {
        if (_restarting) return;
        _terminal.write(
            '\r\n\x1b[2m[Process exited with code $code]\x1b[0m\r\n');
        if (mounted) setState(() => _pty = null);
        final ranMs = DateTime.now().difference(spawnTime).inMilliseconds;
        if (ranMs < 1500 && mounted) {
          if (_isRoot) {
            if (mounted) {
              setState(() {
                _spawnError =
                    'Root shell exited immediately. Device may not be '
                    'rooted or su is unavailable.';
              });
            }
          } else {
            _startShell(attempt: attempt + 1);
          }
        }
      });

      // Keyboard/IME input → shell. Encode as UTF-8 so non-ASCII input is
      // written correctly.
      _terminal.onOutput = (data) {
        _pty?.write(utf8.encode(data));
      };

      if (mounted) setState(() => _pty = pty);
    } catch (e) {
      debugPrint('Terminal spawn error ($shell): $e');
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
    // PopScope forces the Android system back button / predictive back
    // gesture to pop the route. Without this on Android 14+ (target SDK
    // 37), the auto-focus on the embedded xterm can swallow the back event
    // so the user gets stuck on the terminal screen.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
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
                        if (_showTermuxHint) _TermuxHintBanner(
                          onDismiss: () => setState(
                              () => _showTermuxHint = false),
                          onOpenStore: () async {
                            // Open F-Droid's Termux page; that's the
                            // canonical distribution. Falls back to the
                            // Play Store if F-Droid isn't installed.
                            final fdroid = Uri.parse(
                                'https://f-droid.org/packages/com.termux/');
                            final play = Uri.parse(
                                'https://play.google.com/store/apps/details?id=com.termux');
                            if (await canLaunchUrl(fdroid)) {
                              await launchUrl(fdroid,
                                  mode: LaunchMode.externalApplication);
                            } else if (await canLaunchUrl(play)) {
                              await launchUrl(play,
                                  mode: LaunchMode.externalApplication);
                            }
                          },
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                _terminalFocusNode.requestFocus(),
                            child: PopScope(
                              canPop: false,
                              onPopInvokedWithResult: (didPop, _) {
                                if (didPop) return;
                                // Back always pops. The xterm's hidden
                                // EditableText would otherwise eat the back
                                // key for soft-keyboard backspace; the
                                // soft keyboard already has a backspace
                                // key for the in-shell use case.
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

/// Small dismissible banner at the top of the terminal screen that
/// suggests installing Termux for the "real" full-feature shell
/// experience. Doesn't take over the screen — just a single line with
/// a label and two icon-buttons (open the store, dismiss).
class _TermuxHintBanner extends StatelessWidget {
  final VoidCallback onDismiss;
  final VoidCallback onOpenStore;

  const _TermuxHintBanner({
    required this.onDismiss,
    required this.onOpenStore,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'For a full bash shell with apt/pkg, install Termux from '
              'F-Droid or Play Store.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onOpenStore,
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: cs.primary,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Dismiss',
            color: cs.onSurfaceVariant,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
