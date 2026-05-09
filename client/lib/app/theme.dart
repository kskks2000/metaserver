import 'package:flutter/material.dart';

class MetaServerColors {
  static const ink = Color(0xFF12372D);
  static const panel = Color(0xFF173F34);
  static const line = Color(0xFFD6E9DF);
  static const canvas = Color(0xFFF3FBF6);
  static const mint = Color(0xFF79DEAC);
  static const cyan = Color(0xFF53CAA0);
  static const green = Color(0xFF2FAE73);
  static const amber = Color(0xFFD3A12F);
  static const danger = Color(0xFFE5484D);
}

ThemeData buildMetaServerTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: MetaServerColors.mint,
    brightness: Brightness.light,
    primary: MetaServerColors.ink,
    secondary: MetaServerColors.cyan,
    tertiary: MetaServerColors.green,
    error: MetaServerColors.danger,
    surface: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: MetaServerColors.canvas,
    fontFamily: 'Roboto',
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: MetaServerColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: MetaServerColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: MetaServerColors.cyan, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: MetaServerColors.danger),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: const TextStyle(fontSize: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: MetaServerColors.ink,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: const BorderSide(color: MetaServerColors.line),
        foregroundColor: MetaServerColors.ink,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: MetaServerColors.ink,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
