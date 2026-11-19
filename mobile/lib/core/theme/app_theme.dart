// The app's look: colours, text styles and button sizes, for light and dark
// mode, built from a copper seed colour with some pairs set by hand (decision
// Mobile (35); the design is by Mapalo Maseko).
//
// Why a seed: Material 3 can build a whole matching set of colours (a
// ColorScheme) from one colour. Each colour "role" (primary, surface, the text
// on top of them, ...) is given a fixed lightness, so text stays readable
// whatever the seed's hue.
//
// The seed is burnt copper, the mineral this project is about. Bright "classic"
// copper (#B87333) is only 3.8:1 against white text, which is below the 4.5:1
// that WCAG AA asks for and too weak for use in bright sun, so the seed is a
// deeper copper that reaches 6.4:1. Copper turns green as it weathers, so the
// green of the old theme (malachite, patina) is kept as the "tertiary" colour,
// used for notices and for things that are verified or done.
//
// Why a few colours are set by hand (copyWith below): the seed alone gives the
// right hue, but not the warm surfaces or the patina green we want. Each pair
// below was checked by hand for contrast, and test/core/theme/app_theme_test.dart
// checks them again from the real theme, so a later change cannot quietly break
// readability.
//
// Copper and Material's error red have about the same brightness (a contrast
// of 1.01:1), so only their hue tells them apart. That is acceptable because
// status is never shown by colour alone: a tick or cross and a word as well
// (plan section 7).
//
// Depth: filled tiles and light surfaces are only about 1.2:1 apart in light
// mode, so a colour change alone does not separate them. Tiles, cards and
// banners get a soft shadow (elevation) as well.

import 'package:flutter/material.dart';

import 'sizes.dart';

/// The two themes. main.dart passes both to MaterialApp, with
/// `themeMode: ThemeMode.system`, so the app follows the phone's setting.
abstract final class AppTheme {
  /// Burnt copper.
  static const Color seed = Color(0xFF8F4E1E);

  /// The soft, warm brown the shadows are drawn in. Pure black shadows look
  /// dirty on a warm surface.
  static const Color shadow = Color(0xFF3A1A04);

  // `static final` builds each theme once, the first time it is used, instead
  // of on every rebuild of the app.
  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final generated = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    // Hand-set roles, each pair checked for at least 4.5:1 (see the header).
    final scheme = switch (brightness) {
      Brightness.light => generated.copyWith(
        primary: const Color(0xFF8F4E1E),
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFFFDCC6),
        onPrimaryContainer: const Color(0xFF3A1A04),
        secondaryContainer: const Color(0xFFF3E0D2),
        onSecondaryContainer: const Color(0xFF2E1A0D),
        tertiary: const Color(0xFF1D6A55),
        onTertiary: const Color(0xFFFFFFFF),
        tertiaryContainer: const Color(0xFFC4EBDC),
        onTertiaryContainer: const Color(0xFF00201A),
        surface: const Color(0xFFFFF8F4),
        onSurface: const Color(0xFF201A17),
      ),
      Brightness.dark => generated.copyWith(
        primary: const Color(0xFFF2B48A),
        onPrimary: const Color(0xFF4A2200),
        primaryContainer: const Color(0xFF6B3710),
        onPrimaryContainer: const Color(0xFFFFDCC6),
        secondaryContainer: const Color(0xFF4B392D),
        onSecondaryContainer: const Color(0xFFF3E0D2),
        tertiary: const Color(0xFF8FD3BC),
        onTertiary: const Color(0xFF00382D),
        tertiaryContainer: const Color(0xFF0A5140),
        onTertiaryContainer: const Color(0xFFC4EBDC),
        surface: const Color(0xFF19120D),
        onSurface: const Color(0xFFEDE0D8),
      ),
    };

    // Every kind of button is at least one tap target tall and wide.
    const minimum = Size(AppSizes.tapTargetMin, AppSizes.tapTargetMin);

    return ThemeData(
      // Material 3 is Flutter's default; written out so the choice is visible.
      useMaterial3: true,
      colorScheme: scheme,
      // The top bar sits flat on the screen's colour and only gets a shadow
      // once content scrolls under it, so it separates from the page without
      // being a heavy block of colour.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 3,
        shadowColor: shadow,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      // Cards ("My account", "My consignments", account requests) take the
      // tiles' sand with a soft shadow (Mobile (36)). The sand alone is only
      // about 1.2:1 from the light screen, so a thin copper outline (6.1:1)
      // marks the edge even where the shadow is weak. surfaceTintColor is
      // turned off: Material 3 would otherwise wash the card with the primary
      // colour as its elevation grows.
      cardTheme: CardThemeData(
        color: scheme.secondaryContainer,
        elevation: 3,
        shadowColor: shadow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
          side: BorderSide(color: scheme.primary),
        ),
      ),
      // Text fields in copper (Mobile (36)): the label, the icon in front and
      // the line under the field, 2 dp while typing. An error keeps
      // Material's red, but copper and red are almost equally bright (the
      // Mobile (35) limitation), so the sentence under the field is what
      // really marks the error. The theme applies to every field, so the
      // weight field matches the login (Q5).
      inputDecorationTheme: InputDecorationThemeData(
        border: WidgetStateInputBorder.resolveWith(
          (states) =>
              UnderlineInputBorder(borderSide: _fieldLine(scheme, states)),
        ),
        labelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(color: _fieldLabelColour(scheme, states)),
        ),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(color: _fieldLabelColour(scheme, states)),
        ),
        prefixIconColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : scheme.primary,
        ),
      ),
      // Mineral chips (Mobile (36)): the screen's colour with a copper outline
      // when not chosen, filled copper when chosen. The chosen chip keeps its
      // tick, so the choice is never shown by colour alone. The label colour
      // and the raised shadow of the chosen chip are set on the chip itself
      // (register_consignment_screen.dart): a theme label style would replace
      // the chip's own text style rather than add to it, and a chip has one
      // elevation for both states.
      chipTheme: ChipThemeData(
        color: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surface;
        }),
        side: WidgetStateBorderSide.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? scheme.onSurface.withValues(alpha: 0.12)
                : scheme.primary,
            width: 1.5,
          ),
        ),
        shadowColor: shadow,
        selectedShadowColor: shadow,
        surfaceTintColor: Colors.transparent,
      ),
      // The navigation bar (portrait) and rail (landscape), Home and Account
      // (Mobile (37), Mapalo's suggestion). On the screen's colour like the top
      // bar, raised by the same soft warm shadow. The place you are in sits in
      // a peach pill like the role pill, with a copper outline: peach and the
      // screen are only about 1.2:1 apart, so the outline (6:1) marks the pill,
      // and the word is bold copper. The icon also changes from outlined to
      // filled (app_navigation.dart), so "you are here" never rests on colour
      // alone. Words are always shown, never an icon alone (plan section 7).
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 3,
        shadowColor: shadow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: _navIndicator(scheme),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(color: _navIconColour(scheme, states)),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => _navLabel(scheme, states),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        useIndicator: true,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: _navIndicator(scheme),
        labelType: NavigationRailLabelType.all,
        selectedIconTheme: IconThemeData(
          color: _navIconColour(scheme, const {WidgetState.selected}),
        ),
        unselectedIconTheme: IconThemeData(
          color: _navIconColour(scheme, const {}),
        ),
        selectedLabelTextStyle: _navLabel(scheme, const {WidgetState.selected}),
        unselectedLabelTextStyle: _navLabel(scheme, const {}),
      ),
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

  /// The line under a text field in each state.
  static BorderSide _fieldLine(ColorScheme scheme, Set<WidgetState> states) {
    final focused = states.contains(WidgetState.focused);
    if (states.contains(WidgetState.disabled)) {
      return BorderSide(color: scheme.onSurface.withValues(alpha: 0.38));
    }
    if (states.contains(WidgetState.error)) {
      return BorderSide(color: scheme.error, width: focused ? 2 : 1);
    }
    return BorderSide(color: scheme.primary, width: focused ? 2 : 1);
  }

  /// The pill behind the navigation destination you are on.
  static ShapeBorder _navIndicator(ColorScheme scheme) =>
      StadiumBorder(side: BorderSide(color: scheme.primary));

  /// A navigation icon: dark on the peach pill when chosen, otherwise the
  /// quieter onSurfaceVariant on the screen's colour.
  static Color _navIconColour(ColorScheme scheme, Set<WidgetState> states) =>
      states.contains(WidgetState.selected)
      ? scheme.onPrimaryContainer
      : scheme.onSurfaceVariant;

  /// A navigation word. It sits under (or beside) the pill, on the screen's
  /// colour, so its pairs are with surface.
  ///
  /// 14 sp, the size of the role pill's text (labelLarge), a little larger
  /// than Material's 12 sp for users with limited reading. The size is
  /// written out because a theme's text styles only get their sizes when the
  /// theme is built for a widget, and a style without one would fall back to
  /// whatever the surrounding text is.
  static TextStyle _navLabel(ColorScheme scheme, Set<WidgetState> states) {
    final selected = states.contains(WidgetState.selected);
    return TextStyle(
      fontSize: 14,
      letterSpacing: 0.1,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: selected ? scheme.primary : scheme.onSurfaceVariant,
    );
  }

  /// A field's label, in the field or floating above it.
  static Color _fieldLabelColour(ColorScheme scheme, Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      return scheme.onSurface.withValues(alpha: 0.38);
    }
    if (states.contains(WidgetState.error)) return scheme.error;
    return scheme.primary;
  }
}
