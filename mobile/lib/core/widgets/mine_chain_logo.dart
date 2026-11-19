// The MineChain logo (a pick and a shovel crossed) and the "brand block" that
// shows it with the name: below the tiles on every home, and on the splash and
// login screens (decision Mobile (36)).
//
// Why a CustomPainter and not an image file: it needs no package, stays sharp
// at any size, and takes its colour from the theme, so the same logo is deep
// copper in light mode and light copper in dark mode.

import 'package:flutter/material.dart';

import '../brand/logo_geometry.dart';
import '../text/app_text.dart';
import '../theme/sizes.dart';

class MineChainLogo extends StatelessWidget {
  const MineChainLogo({super.key, this.size = AppSizes.logo, this.color});

  /// The width and height, in dp.
  final double size;

  /// Defaults to the theme's primary copper: 6.1:1 on the light screen and
  /// 10.29:1 on the dark one (tested in app_theme_test.dart).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // Decorative: TalkBack reads the name beside it instead, once.
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _LogoPainter(color ?? Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The shapes are on a 108-unit grid; scale it to the space we were given.
    canvas.scale(size.width / LogoGeometry.size);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    for (final shape in LogoGeometry.shapes) {
      canvas.drawPath(_pathOf(shape), paint);
    }
  }

  static Path _pathOf(List<PathCommand> shape) {
    final path = Path();
    for (final command in shape) {
      switch (command) {
        case MoveTo(:final x, :final y):
          path.moveTo(x, y);
        case LineTo(:final x, :final y):
          path.lineTo(x, y);
        case CubicTo(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x,
          :final y,
        ):
          path.cubicTo(x1, y1, x2, y2, x, y);
        case Close():
          path.close();
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}

/// The logo above "MineChain" in heavy copper, centred.
class BrandBlock extends StatelessWidget {
  const BrandBlock({super.key, this.logoSize = AppSizes.logo, this.nameStyle});

  final double logoSize;

  /// Defaults to headlineSmall. The login and splash screens pass a larger one.
  final TextStyle? nameStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MineChainLogo(size: logoSize),
        const SizedBox(height: AppSizes.spaceS),
        // One word on one line: at the largest text on a 5-inch phone it can
        // be wider than the screen, and Flutter would then break it inside
        // the word ("MineCha / in"). Scaled down to fit instead, the same rule
        // as the role in the top bar: whole, never broken or cut.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            AppText.appTitle,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            style: (nameStyle ?? theme.textTheme.headlineSmall)?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}
