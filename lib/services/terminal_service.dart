/// Minimal terminal service — kept as a stable surface for future
/// native-side extensions, but currently has no method-channel calls
/// or external dependencies.
///
/// The terminal screen is a self-contained embedded xterm via
/// `flutter_pty`. The original SwordFM Linux build used `xterm`
/// invoked via a runner script; the Android port does the same with
/// Android's built-in shell.
class TerminalService {
  static const String channelName = 'com.swordfm/terminal';
}
