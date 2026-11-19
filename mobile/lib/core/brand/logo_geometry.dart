// The MineChain logo, a pick and a shovel crossed in an X, described as plain
// shapes (decision Mobile (36)).
//
// Why plain data and no Flutter import: the same shapes draw the logo in the
// app (MineChainLogo, a CustomPainter) and, in T7, are written out as the
// Android launcher icon by a small Dart script. One drawing, two outputs, so
// the app logo and the launcher icon cannot drift apart.
//
// The grid is 108 × 108 units, the size of an Android adaptive icon. Android
// may cut the icon to a circle, so everything stays inside the central circle
// of radius 33 (the "safe zone"); logo_geometry_test.dart checks every point.
//
// Each tool is drawn upright around (0, 0), as if hanging on a wall, then
// turned 45° one way or the other and moved to the centre of the grid. That
// keeps the numbers simple to read and to change.

import 'dart:math' as math;

/// One step of a path, in grid units.
sealed class PathCommand {
  const PathCommand();
}

final class MoveTo extends PathCommand {
  const MoveTo(this.x, this.y);
  final double x;
  final double y;
}

final class LineTo extends PathCommand {
  const LineTo(this.x, this.y);
  final double x;
  final double y;
}

/// A smooth curve to (x, y), pulled towards the two control points.
final class CubicTo extends PathCommand {
  const CubicTo(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double x;
  final double y;
}

final class Close extends PathCommand {
  const Close();
}

abstract final class LogoGeometry {
  /// The grid's width and height.
  static const double size = 108;

  /// The centre of the grid.
  static const double centre = size / 2;

  /// Android's safe zone: what lies inside this circle is never cut by a mask.
  static const double safeRadius = 33;

  /// The logo's shapes, each one filled. Where they overlap they simply merge.
  static final List<List<PathCommand>> shapes = [
    ..._shovel.map((shape) => _place(shape, degrees: 45)),
    ..._pick.map((shape) => _place(shape, degrees: -45)),
  ];

  // ---- The shovel, upright: grip at the top, blade at the bottom ----------

  static const List<List<PathCommand>> _shovel = [
    // The T-grip.
    [MoveTo(-9, -28), LineTo(9, -28), LineTo(9, -22), LineTo(-9, -22), Close()],
    // The handle.
    [
      MoveTo(-2.5, -23),
      LineTo(2.5, -23),
      LineTo(2.5, 11),
      LineTo(-2.5, 11),
      Close(),
    ],
    // The collar where the handle meets the blade.
    [MoveTo(-4, 7), LineTo(4, 7), LineTo(4, 11), LineTo(-4, 11), Close()],
    // The blade: straight shoulders, rounded down to a point.
    [
      MoveTo(-10, 10),
      LineTo(10, 10),
      LineTo(10, 20),
      CubicTo(10, 26, 4, 30, 0, 31),
      CubicTo(-4, 30, -10, 26, -10, 20),
      Close(),
    ],
  ];

  // ---- The pick, upright: the curved head at the top ----------------------

  static const List<List<PathCommand>> _pick = [
    // The handle, ending inside the head.
    [
      MoveTo(-2.5, -22),
      LineTo(2.5, -22),
      LineTo(2.5, 28),
      LineTo(-2.5, 28),
      Close(),
    ],
    // The head: a crescent with two pointed tips, about 6 units thick at the
    // middle.
    [
      MoveTo(-24, -16),
      CubicTo(-12, -30, 12, -30, 24, -16),
      CubicTo(10, -22, -10, -22, -24, -16),
      Close(),
    ],
  ];

  /// Turns [shape] by [degrees] around (0, 0), then moves it to the centre.
  static List<PathCommand> _place(
    List<PathCommand> shape, {
    required double degrees,
  }) {
    final radians = degrees * math.pi / 180;
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    double px(double x, double y) => centre + x * cos - y * sin;
    double py(double x, double y) => centre + x * sin + y * cos;

    return [
      for (final command in shape)
        switch (command) {
          MoveTo(:final x, :final y) => MoveTo(px(x, y), py(x, y)),
          LineTo(:final x, :final y) => LineTo(px(x, y), py(x, y)),
          CubicTo(
            :final x1,
            :final y1,
            :final x2,
            :final y2,
            :final x,
            :final y,
          ) =>
            CubicTo(
              px(x1, y1),
              py(x1, y1),
              px(x2, y2),
              py(x2, y2),
              px(x, y),
              py(x, y),
            ),
          Close() => const Close(),
        },
    ];
  }

  /// Every point and control point of every shape, for checks.
  static Iterable<(double, double)> get allPoints sync* {
    for (final shape in shapes) {
      for (final command in shape) {
        switch (command) {
          case MoveTo(:final x, :final y) || LineTo(:final x, :final y):
            yield (x, y);
          case CubicTo(
            :final x1,
            :final y1,
            :final x2,
            :final y2,
            :final x,
            :final y,
          ):
            yield (x1, y1);
            yield (x2, y2);
            yield (x, y);
          case Close():
            break;
        }
      }
    }
  }
}
