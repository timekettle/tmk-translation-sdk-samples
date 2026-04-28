import 'package:flutter/material.dart';

const appBackground = Color(0xFF0F1117);
const appSurface = Color(0xFF171B24);
const appCard = Color(0xFF222632);
const appBorder = Color(0xFF2E3345);
const appPrimary = Color(0xFF3B82F6);
const appPrimarySoft = Color(0xFF93C5FD);
const appAccent = Color(0xFF10B981);
const appDanger = Color(0xFFEF4444);
const appWarning = Color(0xFFF59E0B);
const appOffline = Color(0xFFF97316);
const appText = Color(0xFFF3F4F6);
const appTextMuted = Color(0xFF94A3B8);

ThemeData buildDemoTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: appBackground,
    colorScheme: base.colorScheme.copyWith(
      primary: appPrimary,
      secondary: appAccent,
      surface: appSurface,
      error: appDanger,
    ),
    cardColor: appCard,
    dividerColor: appBorder,
    textTheme: base.textTheme.apply(
      bodyColor: appText,
      displayColor: appText,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: appText,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: appCard,
      contentTextStyle: TextStyle(color: appText),
    ),
  );
}
