import 'package:flutter/material.dart';

/// Seed for the app's light and dark palettes.
const Color seedColor = Color(0xFF1F6F8B);

/// How long a newly arrived person stays highlighted. Long enough that someone
/// glancing over after a few seconds still catches it, short enough that the
/// board does not stay lit up.
const Duration highlightDuration = Duration(seconds: 30);

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );
}

/// Background for a row that has just appeared, and the accent used on its
/// leading edge and "NEW" chip.
Color newArrivalColor(ColorScheme scheme) => scheme.tertiaryContainer;

Color onNewArrivalColor(ColorScheme scheme) => scheme.onTertiaryContainer;
