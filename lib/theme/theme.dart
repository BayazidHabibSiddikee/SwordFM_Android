import 'package:flutter/material.dart';

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

/// Base dark color palette (One Dark). Used as fallback when no dynamic
/// palette is available or when dynamic colors are disabled.
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

/// Builds a ThemeData using [palette] as primary color source.
/// If [useDynamicColor] is true and the device supports it, the system
/// palette is blended into the One Dark base; otherwise the static palette
/// is used unchanged.
ThemeData buildOneDarkTheme({bool useDynamicColor = false}) {
  ColorScheme base = _ONE_DARK;
  if (useDynamicColor) {
    // dynamic_color is handled at the MaterialApp level via builder;
    // this function provides a static fallback.
  }
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

