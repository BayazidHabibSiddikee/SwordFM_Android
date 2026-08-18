import 'package:flutter/material.dart';

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

ThemeData buildOneDarkTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: OneDarkColors.bg,
    colorScheme: const ColorScheme.dark(
      surface: OneDarkColors.bgDark,
      onSurface: OneDarkColors.fg,
      primary: OneDarkColors.cyan,
      secondary: OneDarkColors.green,
      error: OneDarkColors.red,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: OneDarkColors.bgDark,
      foregroundColor: OneDarkColors.fg,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: OneDarkColors.border,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      textColor: OneDarkColors.fg,
      iconColor: OneDarkColors.fg,
      selectedTileColor: OneDarkColors.select,
      selectedColor: OneDarkColors.selectFg,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: OneDarkColors.fg, fontSize: 15),
      bodyMedium: TextStyle(color: OneDarkColors.fg, fontSize: 13),
      titleMedium: TextStyle(color: OneDarkColors.cyan, fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
    ),
    cardColor: OneDarkColors.bgDark,
    dialogTheme: const DialogThemeData(backgroundColor: OneDarkColors.bg),
  );
}
