import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kThemePref = 'swordfm_theme_mode';

/// Tries to extract dynamic colors from the system accent, falling back to
/// the One Dark palette when no dynamic palette is available.
///
/// Theme-aware: each color returns the dark (One Dark) or light (Cream)
/// variant depending on the current theme mode, so the whole app recolors
/// when the user switches themes.
class OneDarkColors {
  // Dark mode constants (One Dark)
  static const Color _bgDark = Color(0xFF282C34);
  static const Color _bgDarkDark = Color(0xFF21252B);
  static const Color _dimDark = Color(0xFF3E4451);
  static const Color _borderDark = Color(0xFF3E4451);
  static const Color _fgDark = Color(0xFFABB2BF);
  static const Color _fgDimDark = Color(0xFF5C6370);
  static const Color _cyanDark = Color(0xFF61AFEF);
  static const Color _greenDark = Color(0xFF98C379);
  static const Color _amberDark = Color(0xFFE5C07B);
  static const Color _redDark = Color(0xFFE06C75);
  static const Color _purpleDark = Color(0xFFC678DD);
  static const Color _hoverDark = Color(0xFF2C313C);
  static const Color _selectDark = Color(0xFF3E4451);
  static const Color _selectFgDark = Color(0xFF61AFEF);

  // Light mode constants (Cream)
  static const Color _bgLight = Color(0xFFFAF7F0);
  static const Color _bgDarkLight = Color(0xFFF5F0E6);
  static const Color _dimLight = Color(0xFFE8E0D0);
  static const Color _borderLight = Color(0xFFDDD5C5);
  static const Color _fgLight = Color(0xFF3E3832);
  static const Color _fgDimLight = Color(0xFF8A8078);
  static const Color _cyanLight = Color(0xFF2E78B7);
  static const Color _greenLight = Color(0xFF4A8C3F);
  static const Color _amberLight = Color(0xFFB8860B);
  static const Color _redLight = Color(0xFFC0392B);
  static const Color _purpleLight = Color(0xFF8E44AD);
  static const Color _hoverLight = Color(0xFFEDE8DE);
  static const Color _selectLight = Color(0xFFE8E0D0);
  static const Color _selectFgLight = Color(0xFF2E78B7);

  static bool get _isDark => _currentThemeMode == 'dark';

  static Color get bg => _isDark ? _bgDark : _bgLight;
  static Color get bgDark => _isDark ? _bgDarkDark : _bgDarkLight;
  static Color get dim => _isDark ? _dimDark : _dimLight;
  static Color get border => _isDark ? _borderDark : _borderLight;
  static Color get fg => _isDark ? _fgDark : _fgLight;
  static Color get fgDim => _isDark ? _fgDimDark : _fgDimLight;
  static Color get cyan => _isDark ? _cyanDark : _cyanLight;
  static Color get green => _isDark ? _greenDark : _greenLight;
  static Color get amber => _isDark ? _amberDark : _amberLight;
  static Color get red => _isDark ? _redDark : _redLight;
  static Color get purple => _isDark ? _purpleDark : _purpleLight;
  static Color get hover => _isDark ? _hoverDark : _hoverLight;
  static Color get select => _isDark ? _selectDark : _selectLight;
  static Color get selectFg => _isDark ? _selectFgDark : _selectFgLight;
}

/// Cream/light theme colors.
class CreamColors {
  static const Color bg = Color(0xFFFAF7F0);
  static const Color bgDark = Color(0xFFF5F0E6);
  static const Color dim = Color(0xFFE8E0D0);
  static const Color border = Color(0xFFDDD5C5);
  static const Color fg = Color(0xFF3E3832);
  static const Color fgDim = Color(0xFF8A8078);

  static const Color cyan = Color(0xFF2E78B7);
  static const Color green = Color(0xFF4A8C3F);
  static const Color amber = Color(0xFFB8860B);
  static const Color red = Color(0xFFC0392B);
  static const Color purple = Color(0xFF8E44AD);

  static const Color hover = Color(0xFFEDE8DE);
  static const Color select = Color(0xFFE8E0D0);
  static const Color selectFg = Color(0xFF2E78B7);
}

/// Current theme mode: 'dark' or 'light'.
String _currentThemeMode = 'dark';

/// Global notifier for theme changes — callers update via [themeNotifier.value++].
final ValueNotifier<int> themeNotifier = ValueNotifier<int>(0);

/// Gets the current theme mode.
String get currentThemeMode => _currentThemeMode;

/// Loads the saved theme mode from preferences.
Future<void> loadThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    _currentThemeMode = prefs.getString(_kThemePref) ?? 'dark';
  } catch (_) {
    _currentThemeMode = 'dark';
  }
}

/// Saves the theme mode to preferences.
Future<void> saveThemeMode(String mode) async {
  _currentThemeMode = mode;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemePref, mode);
    // Clear manual override so auto-theme can take over again on next schedule change.
    await prefs.setBool(_kManualOverrideKey, false);
  } catch (_) {}
}

// --- Night Mode Scheduling ---

const _kAutoThemeEnabledKey = 'auto_theme_enabled';
const _kAutoThemeStartKey = 'auto_theme_start';
const _kAutoThemeEndKey = 'auto_theme_end';
// When true, auto-theme is suppressed for the current session so a manual
// toggle isn't immediately overwritten on app resume.
const _kManualOverrideKey = 'auto_theme_manual_override';

/// Loads auto-theme settings and returns (enabled, startHour, startMinute, endHour, endMinute).
Future<(bool, int, int, int, int)> loadAutoThemeSettings() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kAutoThemeEnabledKey) ?? false;
    final start = prefs.getString(_kAutoThemeStartKey) ?? '19:00';
    final end = prefs.getString(_kAutoThemeEndKey) ?? '07:00';
    final sp = start.split(':');
    final ep = end.split(':');
    return (
      enabled,
      int.tryParse(sp[0]) ?? 19,
      int.tryParse(sp.length > 1 ? sp[1] : '0') ?? 0,
      int.tryParse(ep[0]) ?? 7,
      int.tryParse(ep.length > 1 ? ep[1] : '0') ?? 0,
    );
  } catch (_) {
    return (false, 19, 0, 7, 0);
  }
}

/// Saves auto-theme settings.
Future<void> saveAutoThemeSettings({
  required bool enabled,
  required int startHour,
  required int startMinute,
  required int endHour,
  required int endMinute,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoThemeEnabledKey, enabled);
    await prefs.setString(_kAutoThemeStartKey,
        '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}');
    await prefs.setString(_kAutoThemeEndKey,
        '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}');
  } catch (_) {}
}

/// Checks if auto-theme is enabled and applies the correct theme.
/// Returns true if theme was changed, false otherwise.
Future<bool> checkAutoTheme() async {
  final (enabled, startH, startM, endH, endM) = await loadAutoThemeSettings();
  if (!enabled) return false;

  // Respect a manual override set when the user toggles theme in Settings.
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kManualOverrideKey) == true) return false;
  } catch (_) {}

  final now = DateTime.now();
  final currentMinutes = now.hour * 60 + now.minute;
  final startMinutes = startH * 60 + startM;
  final endMinutes = endH * 60 + endM;

  bool shouldBeDark;
  if (startMinutes <= endMinutes) {
    // Same-day range (e.g., 09:00 → 17:00)
    shouldBeDark = currentMinutes < startMinutes || currentMinutes >= endMinutes;
  } else {
    // Overnight range (e.g., 19:00 → 07:00)
    shouldBeDark = currentMinutes >= startMinutes || currentMinutes < endMinutes;
  }

  final targetMode = shouldBeDark ? 'dark' : 'light';
  if (_currentThemeMode != targetMode) {
    _currentThemeMode = targetMode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemePref, targetMode);
    } catch (_) {}
    themeNotifier.value++;
    return true;
  }
  return false;
}

/// Returns whether the current theme is dark.
bool get isDarkTheme => _currentThemeMode == 'dark';

const _ONE_DARK = ColorScheme.dark(
  surface: Color(0xFF21252B),
  onSurface: Color(0xFFABB2BF),
  primary: Color(0xFF61AFEF),
  onPrimary: Color(0xFF282C34),
  secondary: Color(0xFF98C379),
  onSecondary: Color(0xFF282C34),
  error: Color(0xFFE06C75),
  onError: Color(0xFF282C34),
);

const _CREAM = ColorScheme.light(
  surface: Color(0xFFF5F0E6),
  onSurface: Color(0xFF3E3832),
  primary: Color(0xFF2E78B7),
  onPrimary: Color(0xFFFFFFFF),
  secondary: Color(0xFF4A8C3F),
  onSecondary: Color(0xFFFFFFFF),
  error: Color(0xFFC0392B),
  onError: Color(0xFFFFFFFF),
);

ThemeData buildOneDarkTheme({bool useDynamicColor = false}) {
  ColorScheme base = _ONE_DARK;
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF282C34),
    colorScheme: base,
    appBarTheme: AppBarTheme(
      backgroundColor: base.surface,
      foregroundColor: base.onSurface,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(
      color: base.surface.withValues(alpha: 0.5),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      textColor: base.onSurface,
      iconColor: base.onSurface,
      selectedTileColor: base.primary.withValues(alpha: 0.15),
      selectedColor: base.primary,
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: base.onSurface, fontSize: 15),
      bodyMedium: TextStyle(color: base.onSurface, fontSize: 13),
      titleMedium: TextStyle(
        color: base.primary,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        color: base.onSurface.withValues(alpha: 0.6),
        fontSize: 12,
      ),
    ),
    cardColor: base.surface,
    dialogTheme: DialogThemeData(backgroundColor: base.surface),
  );
}

ThemeData buildCreamTheme() {
  const base = _CREAM;
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: CreamColors.bg,
    colorScheme: base,
    appBarTheme: const AppBarTheme(
      backgroundColor: CreamColors.bgDark,
      foregroundColor: CreamColors.fg,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: CreamColors.border,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      textColor: CreamColors.fg,
      iconColor: CreamColors.fg,
      selectedTileColor: CreamColors.select,
      selectedColor: CreamColors.cyan,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: CreamColors.fg, fontSize: 15),
      bodyMedium: TextStyle(color: CreamColors.fg, fontSize: 13),
      titleMedium: TextStyle(
        color: CreamColors.cyan,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(color: CreamColors.fgDim, fontSize: 12),
    ),
    cardColor: CreamColors.bgDark,
    dialogTheme: const DialogThemeData(backgroundColor: CreamColors.bg),
  );
}
