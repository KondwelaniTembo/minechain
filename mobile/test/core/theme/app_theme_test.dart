// Checks the WCAG AA contrast (at least 4.5:1) of the colour pairs the app
// draws text with, in both themes, using the colours Flutter really generates
// from the seed.

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
    });
  }
}
