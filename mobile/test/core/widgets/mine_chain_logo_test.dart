// The logo is painted in the theme's copper in both themes, hidden from
// TalkBack (the name beside it is read instead), and sized as asked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/brand/logo_geometry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/widgets/mine_chain_logo.dart';

Future<void> pumpBrand(WidgetTester tester, ThemeData theme) =>
    tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: Center(child: BrandBlock())),
      ),
    );

Finder get logoPaint => find.descendant(
  of: find.byType(MineChainLogo),
  matching: find.byType(CustomPaint),
);

void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    testWidgets('$name: every shape is painted in primary', (tester) async {
      await pumpBrand(tester, theme);

      var expected = paints;
      for (var i = 0; i < LogoGeometry.shapes.length; i++) {
        expected = expected..path(color: theme.colorScheme.primary);
      }
      expect(tester.renderObject(logoPaint), expected);
    });
  }

  testWidgets('the brand block: the logo above the name', (tester) async {
    await pumpBrand(tester, AppTheme.light);

    final logo = tester.getRect(find.byType(MineChainLogo));
    final name = tester.getRect(find.text(AppText.appTitle));
    expect(logo.bottom, lessThanOrEqualTo(name.top));
    expect(logo.size, const Size.square(72));
  });

  testWidgets('TalkBack reads the name once and skips the drawing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBrand(tester, AppTheme.light);

    expect(find.bySemanticsLabel(AppText.appTitle), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(MineChainLogo)).label,
      isNot(contains(AppText.appTitle)),
    );
    semantics.dispose();
  });
}
