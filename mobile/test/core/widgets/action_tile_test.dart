import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';

import '../../fakes/word_breaks.dart';

void main() {
  // Puts one tile on a plain screen, 200 dp wide, the size of a grid cell.
  Future<void> pumpTile(
    WidgetTester tester, {
    required VoidCallback onTap,
    bool primary = false,
    double? labelRoom,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: ActionTile(
                icon: Icons.qr_code_scanner,
                label: 'Register consignment',
                onTap: onTap,
                primary: primary,
                labelRoom: labelRoom,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows its icon and label', (tester) async {
    await pumpTile(tester, onTap: () {});

    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    expect(find.text('Register consignment'), findsOneWidget);
  });

  testWidgets('a tap calls onTap once', (tester) async {
    var taps = 0;
    await pumpTile(tester, onTap: () => taps++);

    await tester.tap(find.byType(ActionTile));

    expect(taps, 1);
  });

  testWidgets('is announced as one button named by its label', (tester) async {
    // Semantics (what TalkBack reads) is off in tests unless asked for.
    final semantics = tester.ensureSemantics();
    await pumpTile(tester, onTap: () {});

    expect(
      tester.getSemantics(find.byType(ActionTile)),
      // isSemantics checks only the fields named here, and ignores the rest.
      isSemantics(
        label: 'Register consignment',
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('is at least the minimum tile size, larger when primary', (
    tester,
  ) async {
    await pumpTile(tester, onTap: () {});
    expect(
      tester.getSize(find.byType(ActionTile)).height,
      greaterThanOrEqualTo(AppSizes.tileMin),
    );

    await pumpTile(tester, onTap: () {}, primary: true);
    expect(
      tester.getSize(find.byType(ActionTile)).height,
      greaterThanOrEqualTo(AppSizes.primaryTileMin),
    );
  });

  // T9.a (Mobile (36)): stronger shadows than before (3 and 6), the main tile
  // still the highest. The theme is not read, so light and dark match.
  testWidgets('sits at elevation 5, the main tile at 8', (tester) async {
    double elevation() => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(ActionTile),
                matching: find.byType(Material),
              )
              .first,
        )
        .elevation;

    await pumpTile(tester, onTap: () {});
    expect(elevation(), 5);

    await pumpTile(tester, onTap: () {}, primary: true);
    expect(elevation(), 8);
  });

  // T9.b: in the 200 dp tile the label has 168 dp. In the test font
  // "consignment" is 11 × 16 dp = 176 dp, a little too wide.
  group('label width', () {
    const label = 'Register consignment';
    // Read from the drawn tile: the theme only gets its type sizes when a
    // widget asks for it (Theme.of), so AppTheme.light alone has none.
    double themeSize(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(ActionTile)))
            .textTheme
            .titleMedium!
            .fontSize!;

    testWidgets('told its width: shrunk just enough, and wraps only between '
        'words', (tester) async {
      await pumpTile(
        tester,
        onTap: () {},
        labelRoom: ActionTile.labelRoomFor(200),
      );

      final size = drawnFontSize(tester, find.text(label));
      expect(size, lessThan(themeSize(tester)));
      expect(size, greaterThan(themeSize(tester) * 0.9));
      expect(lineEndsInsideWords(tester, find.text(label)), isEmpty);
    });

    testWidgets('not told its width: never shrunk', (tester) async {
      await pumpTile(tester, onTap: () {});

      expect(
        drawnFontSize(tester, find.text(label)),
        closeTo(themeSize(tester), 0.01),
      );
    });

    testWidgets('the words fit: not shrunk', (tester) async {
      await pumpTile(tester, onTap: () {}, labelRoom: 400);

      expect(
        drawnFontSize(tester, find.text(label)),
        closeTo(themeSize(tester), 0.01),
      );
    });
  });
}
