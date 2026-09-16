import 'package:event_pulse/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('theme mode persistence', () {
    test('round-trips every mode', () {
      for (final mode in ThemeMode.values) {
        expect(themeModeFromName(themeModeName(mode)), mode);
      }
    });

    test('falls back to system for unknown or missing values', () {
      expect(themeModeFromName(null), ThemeMode.system);
      expect(themeModeFromName(''), ThemeMode.system);
      expect(themeModeFromName('sepia'), ThemeMode.system);
    });

    test('labels every mode', () {
      expect(themeModeLabel(ThemeMode.system), 'System');
      expect(themeModeLabel(ThemeMode.light), 'Light');
      expect(themeModeLabel(ThemeMode.dark), 'Dark');
    });
  });
}
