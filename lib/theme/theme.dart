import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kThemePref = 'swordfm_theme_mode';

/// Tries to extract dynamic colors from the system accent, falling back to
/// the One Dark palette when no dynamic palette is available.
class OneDarkColors {
  static const Color bg = Color(0xFF282C34);
  static const Color bgDark = Color(0xFF21252B);
  static const Color dim = Color(0xFF3E4451);
  static const Color border = Color(0xFF3E4451);
  static const Color fg = Color(0xFFABB2BF);
  static const Color fgDim = Color(0xFF5C6370);
  
  static const Color cyan = Color(0xFF61AFEF);
  static const Color green = Color(0xFF98C379);
  static const Color amber = Color(0xFFE5C07B);
  static const Color red = Color(0xFFE06C75);
  static const Color purple = Color(0xFFC678DD);
  
  static const Color hover = Color(0xFF2C313C);
  static const Color select = Color(0xFF3E4451);
  static const Color selectFg = Color(0xFF61AFEF);
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
  } catch (_) {}
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
      color: base.surface.withOpacity(0.5),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      textColor: base.onSurface,
      iconColor: base.onSurface,
      selectedTileColor: base.primary.withOpacity(0.15),
      selectedColor: base.primary,
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: base.onSurface, fontSize: 15),
      bodyMedium: TextStyle(color: base.onSurface, fontSize: 13),
      titleMedium: TextStyle(color: base.primary, fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(color: base.onSurface.withOpacity(0.6), fontSize: 12),
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
      titleMedium: TextStyle(color: CreamColors.cyan, fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(color: CreamColors.fgDim, fontSize: 12),
    ),
    cardColor: CreamColors.bgDark,
    dialogTheme: const DialogThemeData(backgroundColor: CreamColors.bg),
  );
}
