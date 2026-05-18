import 'package:flutter/material.dart';

class DivinePalette {
  static const Color cosmicVoid = Color(0xFF0A0E14);
  static const Color neonCyan = Color(0xFF00FFF2);
  static const Color celestialGold = Color(0xFFFFD700);
  static const Color matrixGreen = Color(0xFF00FF41);
  static const Color shadowGray = Color(0xFF1C1F26);
  static const Color translucentWhite = Color(0x11FFFFFF);
  static const Color terminalBlack = Color(0xFF0D1117);

  static BoxShadow glow(Color color) => BoxShadow(
    color: color.withAlpha(77),
    blurRadius: 15,
    spreadRadius: 2,
  );
}

class DivineTheme {
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: DivinePalette.cosmicVoid,
    primaryColor: DivinePalette.neonCyan,
    colorScheme: const ColorScheme.dark(
      primary: DivinePalette.neonCyan,
      secondary: DivinePalette.celestialGold,
      surface: DivinePalette.shadowGray,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Colors.white, fontFamily: 'monospace'),
      bodyMedium: TextStyle(color: Colors.white70, fontFamily: 'monospace'),
    ),
  );
}
