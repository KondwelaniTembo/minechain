// A sketch of a zone's shape (GPS zones plan §4.2 and §4.3, Q2): the
// corners joined in order and numbered, north up, on a plain background. No
// map, so nothing is downloaded and it works offline. It is there to make a
// mistyped corner, a swapped one or a "bow-tie" (edges that cross, which
// neither the app nor the server can catch) easy to see.
//
// The corners are projected flat around their middle: east-west distances
// are shrunk by the cosine of the latitude, so a square on the ground looks
// square here. At the size of a licensed site (50 km at most) that is close
// enough for a sketch.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../domain/corner_input.dart';
import '../domain/gps_zone.dart';

class ZoneShapeView extends StatelessWidget {
  const ZoneShapeView({required this.corners, super.key});

  final List<ZoneCorner> corners;

  @override
  Widget build(BuildContext context) {
    // Fewer than three corners enclose nothing: no sketch yet.
    if (corners.length < minZoneCorners) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: AppText.zoneSketchLabel(corners.length),
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: CustomPaint(
              painter: ZoneShapePainter(
                corners: corners,
                line: scheme.primary,
                fill: scheme.primary.withValues(alpha: 0.15),
                dot: scheme.primary,
                label: scheme.onPrimary,
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Public so the tests can check it gets every corner.
class ZoneShapePainter extends CustomPainter {
  ZoneShapePainter({
    required this.corners,
    required this.line,
    required this.fill,
    required this.dot,
    required this.label,
    required this.textScaler,
  });

  final List<ZoneCorner> corners;
  final Color line;
  final Color fill;
  final Color dot;
  final Color label;
  final TextScaler textScaler;

  /// The corners on a canvas of [size], in their order, with room around
  /// them for the numbered dots. Public for the tests.
  List<Offset> pointsFor(Size size) {
    if (corners.length < minZoneCorners) return const [];
    final middleLat =
        corners.map((c) => c.latitude).reduce((a, b) => a + b) / corners.length;
    final shrink = math.cos(middleLat * math.pi / 180);
    // x grows to the east, y to the south (screen y grows downwards).
    final flat = [
      for (final c in corners) Offset(c.longitude * shrink, -c.latitude),
    ];
    final left = flat.map((p) => p.dx).reduce(math.min);
    final right = flat.map((p) => p.dx).reduce(math.max);
    final top = flat.map((p) => p.dy).reduce(math.min);
    final bottom = flat.map((p) => p.dy).reduce(math.max);

    const margin = 24.0;
    final room = Size(
      math.max(size.width - 2 * margin, 1),
      math.max(size.height - 2 * margin, 1),
    );
    final spanX = right - left;
    final spanY = bottom - top;
    // All corners in one spot (or on one line): no division by zero.
    final scale = math.min(
      spanX > 0 ? room.width / spanX : double.infinity,
      spanY > 0 ? room.height / spanY : double.infinity,
    );
    final usable = scale.isFinite ? scale : 0.0;
    // Centred in the canvas.
    final offsetX = (size.width - spanX * usable) / 2;
    final offsetY = (size.height - spanY * usable) / 2;
    return [
      for (final p in flat)
        Offset(
          offsetX + (p.dx - left) * usable,
          offsetY + (p.dy - top) * usable,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final points = pointsFor(size);
    if (points.isEmpty) return;

    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // The numbers say the order, so a corner out of place stands out.
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 11, Paint()..color = dot);
      final number = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: label,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        // Capped: the number must stay inside its dot at large text.
        textScaler: textScaler.clamp(maxScaleFactor: 1.0),
      )..layout();
      number.paint(
        canvas,
        points[i] - Offset(number.width / 2, number.height / 2),
      );
      number.dispose();
    }
  }

  @override
  bool shouldRepaint(ZoneShapePainter old) =>
      old.corners != corners ||
      old.line != line ||
      old.fill != fill ||
      old.dot != dot ||
      old.label != label;
}
