/// Splash screen shown on cold app start.
///
/// Phase 1: animated "SwordFM" wordmark fades in with a slight scale-up.
/// Phase 2: up-to-three recent images cross-fade in the center (image files
/// only, pulled from [WidgetService] recents). Falls back to a stylized sword
/// glyph if no image recents exist.
/// Phase 3: calls [onCompleted] which should navigate to the main app.
///
/// Tapping anywhere at any phase skips immediately to phase 3.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme.dart';
import '../utils/file_utils.dart' show FileItem;

// Duration constants for each phase.
const Duration _kWordmarkDuration = Duration(milliseconds: 600);
const Duration _kImageRotationDuration = Duration(milliseconds: 1800);
const int _kMaxRotatingImages = 3;

class SplashScreen extends StatefulWidget {
  /// Called when the splash has completed (or was skipped).
  final VoidCallback onCompleted;

  const SplashScreen({super.key, required this.onCompleted});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wordmarkAnim;
  late final Animation<double> _wordmarkScale;
  late final Animation<double> _wordmarkOpacity;
  bool _skipped = false;
  Timer? _phase2Timer;
  int _currentImageIndex = 0;
  List<String> _imagePaths = [];

  @override
  void initState() {
    super.initState();
    _wordmarkAnim = AnimationController(vsync: this, duration: _kWordmarkDuration);
    _wordmarkOpacity = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _wordmarkAnim, curve: Curves.easeIn));
    _wordmarkScale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _wordmarkAnim, curve: Curves.easeOutCubic));

    _wordmarkAnim.forward().then((_) => _startImageRotation());
    _fetchRecentImages();
  }

  @override
  void dispose() {
    _wordmarkAnim.dispose();
    _phase2Timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchRecentImages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final recent = prefs.getStringList('widget_recent_files') ?? <String>[];
      if (!mounted) return;
      setState(() {
        _imagePaths = recent
            .where((path) => FileItem.isImagePath(path))
            .toList();
      });
    } catch (_) {}
  }

  void _startImageRotation() {
    if (_imagePaths.isEmpty) {
      _phase2Timer = Timer(const Duration(milliseconds: 800), _go);
      return;
    }
    _scheduleNextImage();
  }

  void _scheduleNextImage() {
    _phase2Timer = Timer(
      _kImageRotationDuration ~/ (_imagePaths.length > 0 ? _imagePaths.length : 1),
      () {
        if (_skipped || !mounted) return;
        setState(() {
          _currentImageIndex = (_currentImageIndex + 1) % _imagePaths.length;
        });
        _scheduleNextImage();
      },
    );
  }

  void _skipToApp() {
    if (_skipped) return;
    _skipped = true;
    _phase2Timer?.cancel();
    _go();
  }

  Future<void> _go() async {
    if (!mounted) return;
    // Set once-per-cold-start flag so warm restores skip the splash.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('splash_shown', true);
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Bail only if disposed. Both the natural-completion timer and the
      // tap-to-skip path funnel through _go() exactly once (_skipToApp
      // cancels the timer), so there is no double-navigation risk.
      // The previous guard `if (mounted && !_skipped) return;` was
      // inverted: _skipped is false on natural completion, so the
      // return fired and onCompleted() never ran on first launch.
      if (!mounted) return;
      widget.onCompleted();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return WillPopScope(
      onWillPop: () async => false, // block back from splash
      child: GestureDetector(
        onTap: _skipToApp,
        child: Scaffold(
          backgroundColor: cs.surface,
          body: Stack(
            children: [
              // Center content
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Wordmark (phase 1)
                    AnimatedBuilder(
                      animation: _wordmarkAnim,
                      builder: (_, __) {
                        return Opacity(
                          opacity: _wordmarkOpacity.value,
                          child: Transform.scale(
                            scale: _wordmarkScale.value,
                            child: _buildWordmark(cs),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                    // Image rotation (phase 2) or fallback glyph
                    if (_imagePaths.isNotEmpty)
                      _buildImageRotator(cs)
                    else
                      _buildSwordGlyph(cs),
                  ],
                ),
              ),
              // Subtle bottom tagline
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    'Tap to skip',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWordmark(ColorScheme cs) {
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.0,
          color: cs.onSurface,
        ),
        children: [
          const TextSpan(text: 'Sword'),
          TextSpan(
            text: 'FM',
            style: const TextStyle(color: Color(0xFFF5A623)),
          ),
        ],
      ),
    );
  }

  Widget _buildImageRotator(ColorScheme cs) {
    if (_imagePaths.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: List.generate(
          _imagePaths.length,
          (i) => Opacity(
            key: ValueKey(i),
            opacity: i == _currentImageIndex ? 1.0 : 0.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(_imagePaths[i]),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: cs.surfaceContainerHighest,
                  child: Icon(Icons.broken_image,
                      color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwordGlyph(ColorScheme cs) {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(
        painter: _SwordGlyphPainter(color: cs.primary),
      ),
    );
  }
}

class _SwordGlyphPainter extends CustomPainter {
  final Color color;
  _SwordGlyphPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawPath(
      Path()
        ..moveTo(cx, 8)
        ..lineTo(cx + 12, cy - 20)
        ..lineTo(cx + 8, cy - 10)
        ..lineTo(cx + 30, cy)
        ..lineTo(cx + 8, cy + 10)
        ..lineTo(cx + 12, cy + 20)
        ..lineTo(cx, cy + 35)
        ..lineTo(cx - 12, cy + 20)
        ..lineTo(cx - 8, cy + 10)
        ..lineTo(cx - 30, cy)
        ..lineTo(cx - 12, cy - 20)
        ..lineTo(cx - 8, cy - 10)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SwordGlyphPainter oldDelegate) =>
      color != oldDelegate.color;
}
