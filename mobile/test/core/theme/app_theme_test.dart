// Checks the WCAG AA contrast (at least 4.5:1) of the colour pairs the app
// draws text with, in both themes, using the colours the theme really builds
// (some come from the seed, the copper and patina ones are set by hand).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/theme/app_theme.dart';

/// The WCAG contrast ratio of two colours, from 1:1 (same) to 21:1 (black on
/// white). computeLuminance() is the WCAG "relative luminance".
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  const aa = 4.5;
  const nonText = 3.0;

  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    group('$name theme', () {
      final s = theme.colorScheme;

      test('body text on the screen background', () {
        expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(aa));
      });

      test('primary button text, also the main home tile', () {
        expect(contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(aa));
      });

      test('the other home tiles', () {
        expect(
          contrast(s.onSecondaryContainer, s.secondaryContainer),
          greaterThanOrEqualTo(aa),
        );
      });

      test('the chosen role on the register screen', () {
        expect(
          contrast(s.onPrimaryContainer, s.primaryContainer),
          greaterThanOrEqualTo(aa),
        );
      });

      // Notices ("server waking", "enter your password") are patina green.
      test('notices', () {
        expect(
          contrast(s.onTertiaryContainer, s.tertiaryContainer),
          greaterThanOrEqualTo(aa),
        );
        expect(contrast(s.onTertiary, s.tertiary), greaterThanOrEqualTo(aa));
      });

      // Server problems are drawn on the error container.
      test('error banner', () {
        expect(
          contrast(s.onErrorContainer, s.errorContainer),
          greaterThanOrEqualTo(aa),
        );
      });

      // Error sentences under a field are drawn in the error colour straight
      // on the screen background, so that pair matters too.
      test('error text on the screen background', () {
        expect(contrast(s.error, s.surface), greaterThanOrEqualTo(aa));
      });

      // Copper links, icons and borders sit on the screen background.
      test('primary colour on the screen background', () {
        expect(contrast(s.primary, s.surface), greaterThanOrEqualTo(aa));
      });

      // The other home tiles draw their icon in copper on the sand tile
      // (action_tile.dart). An icon is not text, so WCAG asks for 3:1
      // (1.4.11, non-text contrast) rather than 4.5:1. The pair passes more
      // today; the test stops a later colour change from making the icons
      // hard to find.
      // Mobile (36): notices are drawn in primary, with onPrimary text
      // (checked above, "primary button text"), and their button is the pill
      // (primaryContainer). The pill's edge must stand out on the notice.
      test('the pill button on a copper notice', () {
        expect(
          contrast(s.primaryContainer, s.primary),
          greaterThanOrEqualTo(nonText),
        );
        expect(
          contrast(s.onPrimaryContainer, s.primaryContainer),
          greaterThanOrEqualTo(aa),
        );
      });

      test('copper icon on the other home tiles', () {
        expect(
          contrast(s.primary, s.secondaryContainer),
          greaterThanOrEqualTo(nonText),
        );
      });

      // Mobile (36), T8: cards take the tiles' sand. A card draws its text and
      // icons in the default onSurface, and "My consignments" draws its error
      // lines in the error colour, both straight on the sand.
      test('text and error lines on a sand card', () {
        expect(
          contrast(s.onSurface, s.secondaryContainer),
          greaterThanOrEqualTo(aa),
        );
        expect(
          contrast(s.error, s.secondaryContainer),
          greaterThanOrEqualTo(aa),
        );
      });
    });

    // T8: how the theme dresses fields, cards and chips in each state. The
    // contrast of every colour used here is checked above (primary, error
    // and onPrimary on their backgrounds).
    group('$name theme, fields, cards and chips', () {
      final s = theme.colorScheme;
      const none = <WidgetState>{};
      const focused = {WidgetState.focused};
      const error = {WidgetState.error};
      const disabled = {WidgetState.disabled};

      BorderSide fieldLine(Set<WidgetState> states) =>
          WidgetStateProperty.resolveAs<InputBorder?>(
            theme.inputDecorationTheme.border,
            states,
          )!.borderSide;

      Color? fieldLabel(TextStyle? style, Set<WidgetState> states) =>
          WidgetStateProperty.resolveAs<TextStyle?>(style, states)?.color;

      test('the line under a field: copper, 2 dp while typing', () {
        expect(fieldLine(none).color, s.primary);
        expect(fieldLine(none).width, 1);
        expect(fieldLine(focused).color, s.primary);
        expect(fieldLine(focused).width, 2);
        // Still an underline, the shape the fields had before T8.
        expect(
          WidgetStateProperty.resolveAs<InputBorder?>(
            theme.inputDecorationTheme.border,
            none,
          ),
          isA<UnderlineInputBorder>(),
        );
      });

      test('an error keeps the red line and label', () {
        expect(fieldLine(error).color, s.error);
        expect(fieldLine({...error, ...focused}).width, 2);
        final d = theme.inputDecorationTheme;
        expect(fieldLabel(d.labelStyle, error), s.error);
        expect(fieldLabel(d.floatingLabelStyle, error), s.error);
      });

      test('labels and the icon in front in copper', () {
        final d = theme.inputDecorationTheme;
        expect(fieldLabel(d.labelStyle, none), s.primary);
        expect(fieldLabel(d.floatingLabelStyle, focused), s.primary);
        expect(
          WidgetStateProperty.resolveAs<Color?>(d.prefixIconColor, none),
          s.primary,
        );
      });

      test('a disabled field is greyed out, not copper', () {
        final d = theme.inputDecorationTheme;
        expect(fieldLine(disabled).color, isNot(s.primary));
        expect(fieldLabel(d.labelStyle, disabled), isNot(s.primary));
        expect(
          WidgetStateProperty.resolveAs<Color?>(d.prefixIconColor, disabled),
          isNot(s.primary),
        );
      });

      test('cards: sand, a raised shadow and a copper outline', () {
        final card = theme.cardTheme;
        expect(card.color, s.secondaryContainer);
        expect(card.elevation, 3);
        expect(card.shadowColor, AppTheme.shadow);
        final shape = card.shape! as RoundedRectangleBorder;
        expect(shape.side.color, s.primary);
        expect(shape.side.width, 1);
      });

      test(
        'chips: outlined on the screen colour, filled copper when chosen',
        () {
          final chip = theme.chipTheme;
          Color? fill(Set<WidgetState> states) => chip.color?.resolve(states);
          BorderSide? side(Set<WidgetState> states) =>
              WidgetStateProperty.resolveAs<BorderSide?>(chip.side, states);

          expect(fill(none), s.surface);
          expect(fill({WidgetState.selected}), s.primary);
          expect(side(none)!.color, s.primary);
          expect(side(none)!.width, 1.5);
          expect(side({WidgetState.selected})!.color, s.primary);
          expect(fill(disabled), isNot(s.primary));
          expect(side(disabled)!.color, isNot(s.primary));
          expect(chip.shadowColor, AppTheme.shadow);
        },
      );
    });
  }
}
