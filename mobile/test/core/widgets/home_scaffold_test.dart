// The home layout on a 5-inch phone (about 360 x 640 dp), turned both ways,
// at normal and very large text. "No overflow" means Flutter reported no layout
// error: an overflow is reported as an exception, which takeException() returns.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';
import 'package:minechain/core/widgets/home_scaffold.dart';
import 'package:minechain/core/widgets/mine_chain_logo.dart';

import '../../fakes/word_breaks.dart';

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

// Labels with short words only, for the tests about the screen-width
// breakpoints. Since T9 a home uses fewer columns when a word does not fit a
// tile (Mobile (36), Q6). The test font draws every letter as a square one
// font size wide, so "consignments" is about 194 dp at normal text, wider
// than a two-column tile's 124 dp label; in Roboto on the phone it is about
// 100 dp and fits. These tests used [actions] until T9; with those labels
// they would now see the one-column layout, which is tested on its own below.
final shortActions = [
  HomeAction(icon: Icons.notifications, label: 'Alerts', onTap: () {}),
  HomeAction(icon: Icons.cloud_upload, label: 'Send my work', onTap: () {}),
  HomeAction(
    icon: Icons.qr_code_scanner,
    label: 'Register consignment',
    onTap: () {},
    primary: true,
  ),
  HomeAction(icon: Icons.history, label: 'Audit trail', onTap: () {}),
  HomeAction(icon: Icons.table_chart, label: 'Reports', onTap: () {}),
];

/// Shows HomeScaffold on a screen of [size] dp with the phone's text size set
/// to [textScale], as if changed in Android's settings.
Future<void> pumpHome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
  // Not "MineChain": that name now belongs to the brand block below the
  // tiles, and a role with the same text would confuse the finders.
  String title = 'Miner',
  String? username,
  List<HomeAction>? tiles,
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
        username: username,
        actions: tiles ?? actions,
        onAccountPressed: () {},
      ),
    ),
  );
}

Finder tileNamed(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ActionTile));

Finder get accountButton => find.widgetWithIcon(IconButton, Icons.person);

Finder get nameInAppBar =>
    find.descendant(of: find.byType(AppBar), matching: find.text('MineChain'));

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
    // Short labels (see shortActions): with a two-column grid the main tile
    // is also the widest.
    await pumpHome(tester, size: portrait, tiles: shortActions);

    final primary = tester.getRect(tileNamed('Register consignment'));
    final other = tester.getRect(tileNamed('Alerts'));
    expect(primary.top, lessThan(other.top));
    expect(primary.width, greaterThan(other.width));
  });

  testWidgets('portrait: 2 columns', (tester) async {
    await pumpHome(tester, size: portrait, tiles: shortActions);

    final a = tester.getRect(tileNamed('Alerts'));
    final b = tester.getRect(tileNamed('Send my work'));
    final c = tester.getRect(tileNamed('Audit trail'));
    expect(b.top, a.top, reason: 'first two tiles share a row');
    expect(b.left, greaterThan(a.left));
    expect(c.top, greaterThan(a.top), reason: 'third tile starts a new row');
  });

  testWidgets('landscape: more than 2 columns', (tester) async {
    await pumpHome(tester, size: landscape, tiles: shortActions);

    final a = tester.getRect(tileNamed('Alerts'));
    final c = tester.getRect(tileNamed('Audit trail'));
    expect(c.top, a.top, reason: 'first three tiles share a row');
    expect(c.left, greaterThan(a.left));
  });

  // T9.b (Mobile (36), Q6): a line of a tile label never ends inside a word.
  group('no word broken in the middle', () {
    // titleMedium, the label size of the tiles other than the main one.
    // Read from a drawn tile: the theme only gets its type sizes when a
    // widget asks for it (Theme.of), so AppTheme.light alone has none.
    double labelSize(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(ActionTile).first))
            .textTheme
            .titleMedium!
            .fontSize!;

    for (final (name, size) in [
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets('$name, text $textScale: every tile label wraps only '
            'between words', (tester) async {
          await pumpHome(tester, size: size, textScale: textScale);
          expect(tester.takeException(), isNull);

          for (final action in actions) {
            await tester.ensureVisible(tileNamed(action.label));
            await tester.pumpAndSettle();
            expect(
              lineEndsInsideWords(tester, find.text(action.label)),
              isEmpty,
            );
          }
        });
      }
    }

    testWidgets('landscape, text 2.0: one column when no word fits a narrower '
        'tile, and the labels keep the chosen text size', (tester) async {
      // In the test font "consignments" is 12 × 32 = 384 dp: too wide for a
      // tile in three columns (160 dp of label) or two (264 dp), and it fits
      // one (576 dp).
      await pumpHome(tester, size: landscape, textScale: 2.0);

      final first = tester.getRect(tileNamed('My consignments'));
      for (final label in ['Send my work', 'Check a consignment', 'Reports']) {
        final rect = tester.getRect(tileNamed(label));
        expect(rect.left, first.left, reason: '"$label" is in one column');
        expect(rect.width, first.width);
        expect(rect.top, greaterThan(first.top));
      }
      for (final action in actions.where((a) => !a.primary)) {
        expect(
          drawnFontSize(tester, find.text(action.label)),
          closeTo(labelSize(tester) * 2.0, 0.01),
          reason: '"${action.label}" is not shrunk',
        );
      }
    });

    testWidgets('landscape, text 1.3: two columns before one', (tester) async {
      // "consignments" is about 251 dp here: too wide for three columns
      // (160 dp of label), narrow enough for two (264 dp).
      await pumpHome(tester, size: landscape, textScale: 1.3);

      final a = tester.getRect(tileNamed('My consignments'));
      final b = tester.getRect(tileNamed('Send my work'));
      final c = tester.getRect(tileNamed('Check a consignment'));
      expect(b.top, a.top, reason: 'two tiles share a row');
      expect(c.top, greaterThan(a.top), reason: 'not three');
    });

    testWidgets('portrait, text 2.0: only a label with a word too wide even '
        'for one column is drawn smaller', (tester) async {
      // A full-width tile has 296 dp of label here. "consignments" (384 dp)
      // does not fit; "Send", "Reports" (224 dp) and the rest do.
      await pumpHome(tester, size: portrait, textScale: 2.0);

      for (final label in ['My consignments', 'Check a consignment']) {
        await tester.ensureVisible(tileNamed(label));
        await tester.pumpAndSettle();
        final shrunk = drawnFontSize(tester, find.text(label));
        expect(shrunk, lessThan(labelSize(tester) * 2.0), reason: label);
        // Only as far as needed: the widest word just fits, not much more.
        expect(
          shrunk,
          greaterThan(labelSize(tester) * 2.0 * 0.7),
          reason: label,
        );
      }
      for (final label in ['Send my work', 'Reports']) {
        await tester.ensureVisible(tileNamed(label));
        await tester.pumpAndSettle();
        expect(
          drawnFontSize(tester, find.text(label)),
          closeTo(labelSize(tester) * 2.0, 0.01),
          reason: label,
        );
      }
    });

    testWidgets('normal text, short words: labels at the theme size', (
      tester,
    ) async {
      await pumpHome(tester, size: portrait, tiles: shortActions);

      for (final action in shortActions.where((a) => !a.primary)) {
        expect(
          drawnFontSize(tester, find.text(action.label)),
          closeTo(labelSize(tester), 0.01),
        );
      }
    });

    // The check itself must see the old fault, or a pass means nothing.
    testWidgets('the check finds "My consig|nments" in a two-column tile', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 124,
              child: Text('My consignments', style: TextStyle(fontSize: 32)),
            ),
          ),
        ),
      );

      expect(
        lineEndsInsideWords(tester, find.text('My consignments')),
        isNotEmpty,
      );
    });
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
  // words are much wider here than in Roboto on a phone. The tests check the
  // rule; the phone check shows the real look.
  //
  // Since Mobile (36), "MineChain" is no longer in the app bar at all: it sits
  // with the logo below the tiles. These tests used to allow it in the bar
  // when it fitted whole; they now require it to be absent from the bar.
  group('app bar title', () {
    // The two longest role words (AppText.transporterTitle, adminTitle).
    for (final role in ['Transporter', 'Administrator']) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets('$role at 360 x 640, text scale $textScale: the role is '
            'whole, and "MineChain" is not in the app bar', (tester) async {
          await pumpHome(
            tester,
            size: portrait,
            textScale: textScale,
            title: role,
          );
          expect(tester.takeException(), isNull);

          expect(find.text(role), findsOneWidget);
          expect(isWhole(tester, find.text(role)), isTrue);
          expect(nameInAppBar, findsNothing);

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

    testWidgets('even with room to spare, the app bar shows only the role; '
        '"MineChain" is below the tiles', (tester) async {
      await pumpHome(
        tester,
        size: const Size(900, 640),
        title: 'Administrator',
      );
      expect(tester.takeException(), isNull);

      expect(isWhole(tester, find.text('Administrator')), isTrue);
      expect(nameInAppBar, findsNothing);
      expect(
        find.descendant(
          of: find.byType(BrandBlock),
          matching: find.text('MineChain'),
        ),
        findsOneWidget,
      );
    });
  });

  // The logo and the name below the tiles (Mobile (36), items 7 and 12).
  group('brand block', () {
    for (final (name, size) in [
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets('$name, text $textScale: below the last tile, reachable, '
            'whole', (tester) async {
          await pumpHome(tester, size: size, textScale: textScale);

          final brand = find.byType(BrandBlock);
          await tester.ensureVisible(brand);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          expect(
            find.descendant(of: brand, matching: find.byType(MineChainLogo)),
            findsOneWidget,
          );
          final brandName = find.descendant(
            of: brand,
            matching: find.text('MineChain'),
          );
          expect(isWhole(tester, brandName), isTrue);

          final rect = tester.getRect(brand);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(
            rect.top,
            greaterThan(tester.getRect(tileNamed('Reports')).bottom),
          );
        });
      }
    }
  });

  // The pill shows "role · username" (Mobile (36)). The role keeps every rule
  // above; the username gives way first, and is either whole, shortened with
  // "…" but still showing at least 3 characters, or left out.
  group('role pill with the username', () {
    const short = 'mutale';
    const long = 'mc_administrator_lusaka_province_office';

    for (final role in ['Transporter', 'Administrator']) {
      for (final username in [short, long]) {
        for (final (name, size) in [
          ('portrait', portrait),
          ('landscape', landscape),
        ]) {
          for (final textScale in [1.0, 2.0]) {
            testWidgets('$role · ${username.length} characters, $name, text '
                '$textScale', (tester) async {
              await pumpHome(
                tester,
                size: size,
                textScale: textScale,
                title: role,
                username: username,
              );
              expect(tester.takeException(), isNull);

              expect(isWhole(tester, find.text(role)), isTrue);
              final buttonLeft = tester.getRect(accountButton).left;
              expect(
                tester.getRect(find.text(role)).right,
                lessThanOrEqualTo(buttonLeft),
              );

              final user = find.text(username);
              if (user.evaluate().isEmpty) return; // left out: allowed

              expect(tester.getRect(user).right, lessThanOrEqualTo(buttonLeft));
              if (!isWhole(tester, user)) {
                // Shortened: at least "mc_…" must still be drawn.
                final paragraph = tester.renderObject<RenderParagraph>(user);
                final threeAndDots = TextPainter(
                  text: TextSpan(
                    text: '${username.substring(0, 3)}…',
                    style: paragraph.text.style,
                  ),
                  textDirection: TextDirection.ltr,
                  textScaler: paragraph.textScaler,
                )..layout();
                expect(
                  paragraph.size.width,
                  greaterThanOrEqualTo(threeAndDots.width - 0.01),
                );
                threeAndDots.dispose();
              }
            });
          }
        }
      }
    }

    testWidgets('with room, the whole username is shown beside the role', (
      tester,
    ) async {
      await pumpHome(
        tester,
        size: const Size(900, 640),
        title: 'Miner',
        username: short,
      );

      expect(find.text('Miner'), findsOneWidget);
      expect(find.text(AppText.pillSeparator), findsOneWidget);
      expect(isWhole(tester, find.text(short)), isTrue);
    });

    testWidgets('a long username is shortened with "…", not left out, when '
        'some of it fits', (tester) async {
      await pumpHome(tester, size: landscape, title: 'Miner', username: long);

      expect(find.text(long), findsOneWidget);
      expect(isWhole(tester, find.text(long)), isFalse);
    });

    testWidgets('TalkBack reads the role and the whole username', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpHome(tester, size: portrait, title: 'Miner', username: long);

      expect(
        find.bySemanticsLabel(AppText.signedInAs('Miner', long)),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('no username: the role alone, as before', (tester) async {
      await pumpHome(tester, size: portrait, title: 'Miner');

      expect(find.text('Miner'), findsOneWidget);
      expect(find.text(AppText.pillSeparator), findsNothing);
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
