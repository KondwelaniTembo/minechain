// The five homes: their tiles, the main tile first, the expired-password
// notice, and no overflow on a small screen, turned, or at large text.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';
import 'package:minechain/core/widgets/mine_chain_logo.dart';
import 'package:minechain/core/widgets/pill_button.dart';
import 'package:minechain/features/admin/presentation/admin_home_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/buyer/presentation/buyer_home_screen.dart';
import 'package:minechain/features/miner/presentation/miner_home_screen.dart';
import 'package:minechain/features/officer/presentation/officer_home_screen.dart';
import 'package:minechain/features/transporter/presentation/transporter_home_screen.dart';

import '../fakes/fake_controllers.dart';

/// Each home: its role, screen, title and tiles (the main tile first).
final homes = <(Role, Widget, String, List<String>)>[
  (
    Role.miner,
    const MinerHomeScreen(),
    AppText.minerTitle,
    // In screen order. Every miner tile opens its screen since M7, so the
    // miner has no "Coming soon" tile (see below).
    [AppText.registerConsignment, AppText.myConsignments, AppText.sendMyWork],
  ),
  (
    Role.transporter,
    const TransporterHomeScreen(),
    AppText.transporterTitle,
    [
      AppText.takeCustody,
      AppText.checkConsignment,
      AppText.myHandoffs,
      AppText.sendMyWork,
    ],
  ),
  (
    Role.buyer,
    const BuyerHomeScreen(),
    AppText.buyerTitle,
    [
      AppText.checkConsignment,
      AppText.recordPurchase,
      AppText.myPurchases,
      AppText.reports,
      AppText.sendMyWork,
    ],
  ),
  (
    Role.officer,
    const OfficerHomeScreen(),
    AppText.officerTitle,
    [
      AppText.alerts,
      AppText.checkConsignment,
      AppText.reports,
      AppText.auditTrail,
    ],
  ),
  (
    Role.admin,
    const AdminHomeScreen(),
    AppText.adminTitle,
    [
      AppText.accountRequests,
      AppText.accounts,
      AppText.gpsZones,
      AppText.anchoring,
      AppText.reports,
    ],
  ),
];

Future<void> pumpHome(
  WidgetTester tester,
  Widget screen,
  AuthState state, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = size * 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: fakeOverrides(FakeAuthController(state)),
      child: MaterialApp(theme: AppTheme.light, home: screen),
    ),
  );
}

Finder tile(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ActionTile));

void main() {
  for (final (role, screen, title, labels) in homes) {
    group(role.name, () {
      testWidgets('title, tiles, main tile first and largest', (tester) async {
        await pumpHome(tester, screen, signedInAs(role));

        expect(find.text(title), findsOneWidget);
        expect(find.byType(ActionTile), findsNWidgets(labels.length));
        final main = tester.widget<ActionTile>(tile(labels.first));
        expect(main.primary, isTrue);
        for (final label in labels.skip(1)) {
          expect(tester.widget<ActionTile>(tile(label)).primary, isFalse);
          expect(
            tester.getTopLeft(tile(labels.first)).dy,
            lessThan(tester.getTopLeft(tile(label)).dy),
          );
        }
      });

      // The last tile, because a home's main tile opens its real screen
      // once its module is built (the admin's "Account requests", plan A1),
      // and that needs the router, which this test leaves out.
      testWidgets(
        'a tile says "Coming soon"',
        (tester) async {
          await pumpHome(tester, screen, signedInAs(role));
          await tester.ensureVisible(tile(labels.last));
          await tester.pump();
          await tester.tap(tile(labels.last));
          await tester.pump();
          expect(find.text(AppText.comingSoon), findsOneWidget);
        },
        // The miner's tiles are all built (M7); the miner's tests in
        // my_consignments_screen_test.dart open "My consignments".
        skip: role == Role.miner,
      );

      testWidgets('signed in: no expired-password notice', (tester) async {
        await pumpHome(tester, screen, signedInAs(role));
        expect(find.text(AppText.needsPasswordNotice), findsNothing);
      });

      testWidgets('token expired: the expired-password notice', (tester) async {
        await pumpHome(tester, screen, SignedInNeedsPassword(userOf(role)));
        expect(find.text(AppText.needsPasswordNotice), findsOneWidget);
      });

      // Mobile (36): the notice takes the main tile's copper, and its button
      // looks like the role pill, at full tap height.
      testWidgets('the expired-password notice is copper, and its pill button '
          'opens the prompt', (tester) async {
        await pumpHome(tester, screen, SignedInNeedsPassword(userOf(role)));

        final notice = find
            .ancestor(
              of: find.text(AppText.needsPasswordNotice),
              matching: find.byType(Material),
            )
            .first;
        expect(
          tester.widget<Material>(notice).color,
          AppTheme.light.colorScheme.primary,
        );

        final button = find.widgetWithText(
          PillButton,
          AppText.enterPasswordButton,
        );
        expect(
          tester.getSize(button).height,
          greaterThanOrEqualTo(AppSizes.tapTargetMin),
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text(AppText.passwordPromptExplanation), findsOneWidget);
      });

      // Item 12 of Mobile (36): at the largest text the name used to vanish
      // from the admin's app bar. It now lives with the logo below the tiles.
      for (final (name, size) in [
        ('portrait', const Size(360, 640)),
        ('landscape', const Size(640, 360)),
      ]) {
        testWidgets('text 2.0, $name: the logo and "MineChain" are on the '
            'home, below the tiles', (tester) async {
          await pumpHome(
            tester,
            screen,
            signedInAs(role),
            size: size,
            textScale: 2.0,
          );

          final brand = find.byType(BrandBlock);
          await tester.ensureVisible(brand);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(MineChainLogo), findsOneWidget);
          expect(
            find.descendant(of: brand, matching: find.text(AppText.appTitle)),
            findsOneWidget,
          );
          expect(
            tester.getRect(brand).top,
            greaterThan(tester.getRect(tile(labels.last)).bottom),
          );
        });
      }

      // Wide enough that the test font's wide letters fit; the narrow cases
      // are in home_scaffold_test.dart.
      testWidgets('the top bar shows the role and the username', (
        tester,
      ) async {
        await pumpHome(
          tester,
          screen,
          signedInAs(role),
          size: const Size(900, 640),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.text(userOf(role).username), findsOneWidget);
      });

      for (final (name, size, scale) in [
        ('portrait', const Size(360, 640), 1.0),
        ('landscape', const Size(640, 360), 1.0),
        ('portrait, text 2.0', const Size(360, 640), 2.0),
        ('landscape, text 2.0', const Size(640, 360), 2.0),
      ]) {
        testWidgets('no overflow, every tile reachable: $name', (tester) async {
          await pumpHome(
            tester,
            screen,
            SignedInNeedsPassword(userOf(role)),
            size: size,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          for (final label in labels) {
            await tester.ensureVisible(tile(label));
            await tester.pump();
            expect(tester.takeException(), isNull);
          }
        });
      }
    });
  }
}
