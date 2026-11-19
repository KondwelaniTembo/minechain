// The logo's shapes: well formed, and every point inside Android's safe zone,
// so a round launcher-icon mask (T7) never cuts the pick or the shovel.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/brand/logo_geometry.dart';

void main() {
  test('six shapes: the shovel\'s four and the pick\'s two', () {
    expect(LogoGeometry.shapes, hasLength(6));
  });

  test('each shape starts with a move and ends closed', () {
    for (final shape in LogoGeometry.shapes) {
      expect(shape.first, isA<MoveTo>());
      expect(shape.last, isA<Close>());
      expect(shape.whereType<MoveTo>(), hasLength(1));
    }
  });

  test('every point, control points included, is inside the safe circle', () {
    for (final (x, y) in LogoGeometry.allPoints) {
      final distance = math.sqrt(
        math.pow(x - LogoGeometry.centre, 2) +
            math.pow(y - LogoGeometry.centre, 2),
      );
      expect(
        distance,
        lessThanOrEqualTo(LogoGeometry.safeRadius),
        reason: '($x, $y) is outside the safe circle',
      );
    }
  });

  test(
    'the logo fills a good part of the circle, not a speck in the middle',
    () {
      final furthest = LogoGeometry.allPoints
          .map(
            (p) => math.sqrt(
              math.pow(p.$1 - LogoGeometry.centre, 2) +
                  math.pow(p.$2 - LogoGeometry.centre, 2),
            ),
          )
          .reduce(math.max);
      expect(furthest, greaterThan(LogoGeometry.safeRadius * 0.8));
    },
  );
}
