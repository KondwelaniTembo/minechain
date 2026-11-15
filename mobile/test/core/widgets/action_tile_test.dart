import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';

void main() {
  // Puts one tile on a plain screen, 200 dp wide, the size of a grid cell.
  Future<void> pumpTile(
    WidgetTester tester, {
    required VoidCallback onTap,
    bool primary = false,
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
}
