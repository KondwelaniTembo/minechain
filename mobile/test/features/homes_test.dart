// The five homes: their tiles, the main tile first, the expired-password
// notice, and no overflow on a small screen, turned, or at large text.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/router/routes.dart';
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
import '../fakes/word_breaks.dart';

/// Each home: its role, screen, title and tiles (the main tile first).
final homes = <(Role, Widget, String, List<String>)>[
  (
    Role.miner,
    const MinerHomeScreen(),
    AppText.minerTitle,
    // In screen order. Every miner tile opens its screen since M7, so the
    // miner has no "Coming soon" tile; its own test checks where each goes.
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
    // "Dashboard" added second by Dashboard T4 (changed by plan).
    [
      AppText.alerts,
      AppText.dashboard,
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
      //
      // Not for the miner: all three of its tiles are built (M7), so it has
      // no "Coming soon" tile. Hardening T3 replaced the skipped miner case
      // with the router test after this loop. Nor for the transporter since
      // Transporter handoff T5 wired its last two tiles (changed by plan);
      // "transporter tiles" below checks each of its tiles instead.
      //
      // The buyer's last tile, "Send my work", is wired since Buyer
      // purchase T3 (changed by plan), and its "Reports" since Reports T3;
      // the officer's "Reports" and "Audit trail" since Reports T3 and T4
      // (changed by plan). "buyer tiles" and "officer tiles" below check
      // each of their tiles instead. The administrator's "Anchoring", the
      // last "Coming soon" tile, is wired since Anchoring status T3 (changed
      // by plan), so no role has one now; "admin tiles" below checks it.

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

      // T9.b (Mobile (36), Q6): no tile label of this home is broken inside a
      // word, the old "My consig / nments".
      for (final (name, size) in [
        ('portrait', const Size(360, 640)),
        ('landscape', const Size(640, 360)),
      ]) {
        testWidgets('text 2.0, $name: every tile label wraps only between '
            'words', (tester) async {
          await pumpHome(
            tester,
            screen,
            signedInAs(role),
            size: size,
            textScale: 2.0,
          );
          expect(tester.takeException(), isNull);

          for (final label in labels) {
            await tester.ensureVisible(tile(label));
            await tester.pumpAndSettle();
            expect(lineEndsInsideWords(tester, find.text(label)), isEmpty);
          }
        });
      }

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
  // Hardening T3, in place of the skipped miner case above: every miner tile
  // opens its own screen, and none says "Coming soon". The home sits in a
  // small router whose task paths show a stand-in page with the path's name,
  // so this checks the home's wiring without the screens' own databases,
  // camera and location (their tests are in features/registration,
  // features/consignments and features/sync).
  group('miner tiles', () {
    tilesOpenTheirPages(Role.miner, AppRoutes.miner, const MinerHomeScreen(), [
      (AppText.registerConsignment, AppRoutes.minerRegister),
      (AppText.myConsignments, AppRoutes.minerConsignments),
      (AppText.sendMyWork, AppRoutes.minerSync),
    ]);
  });

  // Transporter handoff T5: every transporter tile is built, so each is
  // checked the same way.
  group('transporter tiles', () {
    tilesOpenTheirPages(
      Role.transporter,
      AppRoutes.transporter,
      const TransporterHomeScreen(),
      [
        (AppText.takeCustody, AppRoutes.transporterCustody),
        (AppText.checkConsignment, AppRoutes.transporterCheck),
        (AppText.myHandoffs, AppRoutes.transporterHandoffs),
        (AppText.sendMyWork, AppRoutes.transporterSync),
      ],
    );
  });

  // Buyer purchase T3: the four built buyer tiles, the same way. Reports T3
  // (changed by plan): "Reports" is built too, so it joined them.
  group('buyer tiles', () {
    tilesOpenTheirPages(Role.buyer, AppRoutes.buyer, const BuyerHomeScreen(), [
      (AppText.checkConsignment, AppRoutes.buyerCheck),
      (AppText.recordPurchase, AppRoutes.buyerPurchase),
      (AppText.myPurchases, AppRoutes.buyerPurchases),
      (AppText.reports, AppRoutes.buyerReports),
      (AppText.sendMyWork, AppRoutes.buyerSync),
    ]);
  });

  // Officer alerts T2: "Alerts" and "Check a consignment" are built.
  // Reports T3 and T4 (changed by plan): "Reports" opens its screen, and
  // "Audit trail" opens the check (Q2: the trail is downloaded from the
  // result), so the "Reports still says Coming soon" case went and both
  // tiles joined this list. Dashboard T4 (changed by plan): the new
  // "Dashboard" tile joined it too.
  group('officer tiles', () {
    tilesOpenTheirPages(
      Role.officer,
      AppRoutes.officer,
      const OfficerHomeScreen(),
      [
        (AppText.alerts, AppRoutes.officerAlerts),
        (AppText.dashboard, AppRoutes.officerDashboard),
        (AppText.checkConsignment, AppRoutes.officerCheck),
        (AppText.reports, AppRoutes.officerReports),
        (AppText.auditTrail, AppRoutes.officerCheck),
      ],
    );
  });

  // Admin accounts T2: "Accounts" is wired. GPS zones T2 (changed by plan):
  // "GPS zones" is wired too, so it left the "Coming soon" loop below.
  // Reports T3 (changed by plan): so is "Reports". Anchoring status T3
  // (changed by plan): "Anchoring" opens its status screen, so the "still
  // says Coming soon" case went and it joined this list.
  group('admin tiles', () {
    tilesOpenTheirPages(Role.admin, AppRoutes.admin, const AdminHomeScreen(), [
      (AppText.accountRequests, AppRoutes.adminRequests),
      (AppText.accounts, AppRoutes.adminAccounts),
      (AppText.gpsZones, AppRoutes.adminZones),
      (AppText.anchoring, AppRoutes.adminAnchoring),
      (AppText.reports, AppRoutes.adminReports),
    ]);
  });
}

/// One test per tile of [role]'s home ([home] at [homePath]): the tile
/// opens its path, never "Coming soon". Shared by the miner (Hardening T3)
/// and the transporter (T5).
void tilesOpenTheirPages(
  Role role,
  String homePath,
  Widget home,
  List<(String, String)> tiles,
) {
  for (final (label, path) in tiles) {
    testWidgets('"$label" opens $path, never "Coming soon"', (tester) async {
      final router = GoRouter(
        initialLocation: homePath,
        routes: [
          GoRoute(path: homePath, builder: (_, _) => home),
          // A set: two tiles may open the same page (the officer's "Check a
          // consignment" and "Audit trail", Reports T4).
          for (final page in {for (final (_, path) in tiles) path})
            GoRoute(
              path: page,
              builder: (_, _) => Scaffold(body: Text('page $page')),
            ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(360, 640) * 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          retry: noRetry,
          overrides: fakeOverrides(FakeAuthController(signedInAs(role))),
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(tile(label));
      await tester.pump();
      await tester.tap(tile(label));
      await tester.pumpAndSettle();

      expect(find.text('page $path'), findsOneWidget);
      expect(router.state.uri.path, path);
      expect(find.text(AppText.comingSoon), findsNothing);
    });
  }
}
