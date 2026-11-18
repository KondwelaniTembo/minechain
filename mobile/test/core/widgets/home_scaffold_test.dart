// The home layout on a 5-inch phone (about 360 x 640 dp), turned both ways,
// at normal and very large text. "No overflow" means Flutter reported no layout
// error: an overflow is reported as an exception, which takeException() returns.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';
import 'package:minechain/core/widgets/home_scaffold.dart';

const portrait = Size(360, 640);
const landscape = Size(640, 360);

// Listed with the primary in the middle on purpose: HomeScaffold must still
// put it first.
final actions = [
  HomeAction(icon: Icons.inventory_2, label: 'My consignments', onTap: () {}),
  HomeAction(icon: Icons.cloud_upload, label: 'Send my work', onTap: () {}),
  HomeAction(
    icon: Icons.qr_code_scanner,
    label: 'Register consignment',
    onTap: () {},
    primary: true,
  ),
  HomeAction(icon: Icons.search, label: 'Check a consignment', onTap: () {}),
  HomeAction(icon: Icons.table_chart, label: 'Reports', onTap: () {}),
];

/// Shows HomeScaffold on a screen of [size] dp with the phone's text size set
/// to [textScale], as if changed in Android's settings.
Future<void> pumpHome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
  String title = 'MineChain',
}) async {
  // The test screen is set in physical pixels; 3 pixels per dp is typical of
  // a modern phone. reset() puts it back after the test.
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = size * 3.0;
  addTearDown(tester.view.reset);

  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: HomeScaffold(
        title: title,
        actions: actions,
        onAccountPressed: () {},
      ),
    ),
  );
}

Finder tileNamed(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ActionTile));

Finder get accountButton => find.widgetWithIcon(IconButton, Icons.person);

/// Whether the text found by [finder] is drawn whole: its full one-line width
/// fits inside the width it was given, so nothing was cut or replaced by "…".
bool isWhole(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final fullWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
  return !paragraph.didExceedMaxLines &&
      fullWidth <= paragraph.size.width + 0.01;
}

void main() {
  for (final (name, size) in [
    ('portrait', portrait),
    ('landscape', landscape),
  ]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('$name at text scale $textScale: no overflow, every tile '
          'reachable', (tester) async {
        await pumpHome(tester, size: size, textScale: textScale);
        expect(tester.takeException(), isNull);

        for (final action in actions) {
          // Scroll the tile into view, then check it is really on screen.
          await tester.ensureVisible(tileNamed(action.label));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final tile = tester.getRect(tileNamed(action.label));
          expect(tile.left, greaterThanOrEqualTo(0));
          expect(tile.right, lessThanOrEqualTo(size.width));
          expect(tile.top, lessThan(size.height));
          expect(tile.bottom, greaterThan(0));
        }
      });
    }
  }

  testWidgets('the primary tile comes first, across the full width', (
    tester,
  ) async {
    await pumpHome(tester, size: portrait);

    final primary = tester.getRect(tileNamed('Register consignment'));
    final other = tester.getRect(tileNamed('My consignments'));
    expect(primary.top, lessThan(other.top));
    expect(primary.width, greaterThan(other.width));
  });

  testWidgets('portrait: 2 columns', (tester) async {
    await pumpHome(tester, size: portrait);

    final a = tester.getRect(tileNamed('My consignments'));
    final b = tester.getRect(tileNamed('Send my work'));
    final c = tester.getRect(tileNamed('Check a consignment'));
    expect(b.top, a.top, reason: 'first two tiles share a row');
    expect(b.left, greaterThan(a.left));
    expect(c.top, greaterThan(a.top), reason: 'third tile starts a new row');
  });

  testWidgets('landscape: more than 2 columns', (tester) async {
    await pumpHome(tester, size: landscape);

    final a = tester.getRect(tileNamed('My consignments'));
    final c = tester.getRect(tileNamed('Check a consignment'));
    expect(c.top, a.top, reason: 'first three tiles share a row');
    expect(c.left, greaterThan(a.left));
  });

  test('columnsForWidth follows the breakpoints', () {
    expect(AppSizes.columnsForWidth(360), 2);
    expect(AppSizes.columnsForWidth(599), 2);
    expect(AppSizes.columnsForWidth(600), 3);
    expect(AppSizes.columnsForWidth(640), 3);
    expect(AppSizes.columnsForWidth(839), 3);
    expect(AppSizes.columnsForWidth(840), 4);
  });

  testWidgets('the account button has a tooltip', (tester) async {
    await pumpHome(tester, size: portrait);

    expect(find.byTooltip('My account'), findsOneWidget);
  });

  // The test font draws every letter as a square as wide as the font size, so
  // words are much wider here than in Roboto on a phone. "MineChain" is often
  // left out at 360 dp in these tests; they check the rule, and the phone check
  // shows the real look.
  group('app bar title', () {
    // The two longest role words (AppText.transporterTitle, adminTitle).
    for (final role in ['Transporter', 'Administrator']) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets('$role at 360 x 640, text scale $textScale: the role is '
            'whole, "MineChain" is whole or absent', (tester) async {
          await pumpHome(
            tester,
            size: portrait,
            textScale: textScale,
            title: role,
          );
          expect(tester.takeException(), isNull);

          expect(find.text(role), findsOneWidget);
          expect(isWhole(tester, find.text(role)), isTrue);

          final name = find.text('MineChain');
          if (name.evaluate().isNotEmpty) {
            expect(isWhole(tester, name), isTrue);
            expect(
              tester.getRect(name).right,
              lessThanOrEqualTo(tester.getRect(find.text(role)).left),
            );
          }

          // Whole, and also inside the bar: not under the account button and
          // not past the screen's edge.
          final roleRect = tester.getRect(find.text(role));
          expect(roleRect.left, greaterThanOrEqualTo(0));
          expect(
            roleRect.right,
            lessThanOrEqualTo(tester.getRect(accountButton).left),
          );
        });
      }
    }

    testWidgets('with room to spare, both "MineChain" and the role are shown '
        'whole', (tester) async {
      await pumpHome(
        tester,
        size: const Size(900, 640),
        title: 'Administrator',
      );
      expect(tester.takeException(), isNull);

      expect(find.text('MineChain'), findsOneWidget);
      expect(isWhole(tester, find.text('MineChain')), isTrue);
      expect(isWhole(tester, find.text('Administrator')), isTrue);
    });
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets('the account button is at least one tap target in both '
        'directions, text scale $textScale', (tester) async {
      await pumpHome(tester, size: portrait, textScale: textScale);

      final size = tester.getSize(accountButton);
      expect(size.width, greaterThanOrEqualTo(AppSizes.tapTargetMin));
      expect(size.height, greaterThanOrEqualTo(AppSizes.tapTargetMin));
    });
  }
}
