// Writes the launcher icon's foreground (plan T7.a), an Android vector
// drawable, from the same shapes that draw the logo in the app. Run it by
// hand from mobile/ after changing lib/core/brand/logo_geometry.dart:
//
//   dart run tool/make_launcher_icon.dart
//
// test/core/brand/launcher_icon_test.dart runs launcherForegroundXml() in
// memory and compares it with the committed file, so a geometry change that
// is not written out here fails the tests instead of shipping two logos.
//
// It imports only logo_geometry.dart (plain Dart, no Flutter), which is why
// `dart run` can run it. The colours are therefore written here as text; the
// test checks they are the light theme's primary and primaryContainer.

import 'dart:io';

import 'package:minechain/core/brand/logo_geometry.dart';

/// Where the foreground is written, relative to mobile/.
const foregroundFile =
    'android/app/src/main/res/drawable/ic_launcher_foreground.xml';

/// Where the background colour is declared, relative to mobile/.
const backgroundFile =
    'android/app/src/main/res/values/ic_launcher_background.xml';

/// The logo's colour on the icon: cream, the light theme's primaryContainer.
const foregroundColour = '#FFDCC6';

/// The icon's background: deep copper, the light theme's primary.
const backgroundColour = '#8F4E1E';

/// The whole foreground file, one `<path>` per logo shape. Each shape is
/// filled on its own, as MineChainLogo paints it, so overlaps simply merge.
String launcherForegroundXml() {
  final size = _number(LogoGeometry.size);
  final paths = [
    for (final shape in LogoGeometry.shapes)
      '    <path\n'
          '        android:fillColor="$foregroundColour"\n'
          '        android:pathData="${_pathData(shape)}" />\n',
  ].join();

  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!-- Written by tool/make_launcher_icon.dart from\n'
      '     lib/core/brand/logo_geometry.dart. Do not edit by hand: change the\n'
      '     geometry and run the tool again. -->\n'
      '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
      '    android:width="${size}dp"\n'
      '    android:height="${size}dp"\n'
      '    android:viewportWidth="$size"\n'
      '    android:viewportHeight="$size">\n'
      '$paths'
      '</vector>\n';
}

/// SVG-style path data, which Android's pathData uses: M, L, C and Z.
String _pathData(List<PathCommand> shape) => [
  for (final command in shape)
    switch (command) {
      MoveTo(:final x, :final y) => 'M${_point(x, y)}',
      LineTo(:final x, :final y) => 'L${_point(x, y)}',
      CubicTo(:final x1, :final y1, :final x2, :final y2, :final x, :final y) =>
        'C${_point(x1, y1)} ${_point(x2, y2)} ${_point(x, y)}',
      Close() => 'Z',
    },
].join(' ');

String _point(double x, double y) => '${_number(x)},${_number(y)}';

/// Two decimals (a hundredth of a dp on the 108 dp canvas, far below a
/// pixel), with trailing zeros dropped so the file stays readable. Fixed
/// rounding also keeps the output identical on every machine, which the
/// drift test needs.
String _number(double value) {
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text == '-0' ? '0' : text;
}

void main() {
  File(foregroundFile).writeAsStringSync(launcherForegroundXml());
  stdout.writeln('Wrote $foregroundFile');
}
