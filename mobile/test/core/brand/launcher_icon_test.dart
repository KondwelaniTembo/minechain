// The launcher icon (plan T7) cannot drift from the app's logo: the committed
// foreground must be exactly what tool/make_launcher_icon.dart writes from
// logo_geometry.dart today, like the backend's ABI drift test. The safe-circle
// check on the same points is in logo_geometry_test.dart.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/brand/logo_geometry.dart';
import 'package:minechain/core/theme/app_theme.dart';

import '../../../tool/make_launcher_icon.dart'
    show
        backgroundColour,
        backgroundFile,
        foregroundColour,
        foregroundFile,
        launcherForegroundXml;

const adaptiveIconFile =
    'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml';

/// Reads a file under mobile/ (flutter test runs there). Git on Windows may
/// check text out with CRLF line endings; the content is what matters.
String readText(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

Color colourOf(String hex) =>
    Color(int.parse('FF${hex.substring(1)}', radix: 16));

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test(
    'the committed foreground is what the tool writes from the geometry',
    () {
      expect(
        readText(foregroundFile),
        launcherForegroundXml(),
        reason:
            'Run `dart run tool/make_launcher_icon.dart` from mobile/ after '
            'changing logo_geometry.dart.',
      );
    },
  );

  test('the foreground has one filled path per logo shape', () {
    expect(
      '<path'.allMatches(launcherForegroundXml()),
      hasLength(LogoGeometry.shapes.length),
    );
  });

  test('the adaptive icon uses the background, foreground and monochrome', () {
    final xml = readText(adaptiveIconFile);
    expect(xml, contains('<adaptive-icon'));
    expect(
      xml,
      contains('<background android:drawable="@color/ic_launcher_background"'),
    );
    expect(
      xml,
      contains(
        '<foreground android:drawable="@drawable/ic_launcher_foreground"',
      ),
    );
    expect(
      xml,
      contains(
        '<monochrome android:drawable="@drawable/ic_launcher_foreground"',
      ),
    );
    expect(
      readText(backgroundFile),
      contains(
        '<color name="ic_launcher_background">$backgroundColour</color>',
      ),
    );
  });

  test('the icon is the theme\'s copper and cream, with clear contrast', () {
    final scheme = AppTheme.light.colorScheme;
    expect(colourOf(backgroundColour), scheme.primary);
    expect(colourOf(foregroundColour), scheme.primaryContainer);

    // 3:1 is WCAG's rule for icons and other non-text shapes (Q2).
    expect(
      contrast(colourOf(foregroundColour), colourOf(backgroundColour)),
      greaterThanOrEqualTo(3.0),
    );
  });
}
