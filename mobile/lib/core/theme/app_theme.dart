// The app's look: colours, text styles and button sizes, for light and dark
// mode, built from one seed colour.
//
// Why a seed: Material 3 can build a whole matching set of colours (a
// ColorScheme) from one colour. Each colour "role" (primary, surface, the text
// on top of them, ...) is given a fixed lightness, so text stays readable
// whatever the seed's hue.
//
// The seed is malachite green, a copper mineral mined in Zambia. It suits the
// project, is calm rather than alarming, and is clearly different from the red
// Material uses for errors. Status is never shown by colour alone anyway (a tick
// or cross and a word, plan section 7), so green is not mistaken for "OK".
//
// Contrast (WCAG AA asks for at least 4.5:1 for normal text). The colour
// library behind ColorScheme.fromSeed (material_color_utilities 0.13.0) gives
// each role a fixed lightness ("tone", 0 = black, 100 = white):
//   light: text 10 on surface 98, button text 100 on primary 40
//   dark:  text 90 on surface 6,  button text 20 on primary 80
// Those tones work out at about 16:1 and 6.5:1 (light), 14:1 and 7.7:1 (dark).
// test/core/theme/app_theme_test.dart checks the real generated colours.

import 'package:flutter/material.dart';

import 'sizes.dart';

/// The two themes. main.dart passes both to MaterialApp, with
/// `themeMode: ThemeMode.system`, so the app follows the phone's setting.
abstract final class AppTheme {
  /// Malachite green.
  static const Color seed = Color(0xFF0B6E4F);

  // `static final` builds each theme once, the first time it is used, instead
  // of on every rebuild of the app.
  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    // Every kind of button is at least one tap target tall and wide.
    const minimum = Size(AppSizes.tapTargetMin, AppSizes.tapTargetMin);

    return ThemeData(
      // Material 3 is Flutter's default; written out so the choice is visible.
      useMaterial3: true,
      colorScheme: scheme,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: minimum),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: minimum),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: minimum),
      ),
      // A floating snack bar sits above the screen's edge, which reads more
      // clearly as a short message than one fixed to the bottom.
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
