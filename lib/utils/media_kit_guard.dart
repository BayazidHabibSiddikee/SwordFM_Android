import 'package:media_kit/media_kit.dart';

/// One-line wrapper around [MediaKit.ensureInitialized] so any media entry
/// point can guarantee libmpv is loaded before constructing a [Player],
/// without each screen needing to know about app startup details.
///
/// [MediaKit.ensureInitialized] is idempotent — calling it after main() has
/// already initialised is a cheap no-op.
class MediaKitGuard {
  static bool _done = false;

  /// Calls [MediaKit.ensureInitialized] once per process.
  static void ensure() {
    if (_done) return;
    MediaKit.ensureInitialized();
    _done = true;
  }
}
