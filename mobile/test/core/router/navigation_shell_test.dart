// T11 (Mobile (37)): the frame with the navigation bar around the homes and
// "My account", in the real app and router with a stand-in auth controller.
//
// Finders skip what is offstage. While Account is shown the home is kept
// alive but offstage, so a finder only sees the place on screen; the tests
// that must look behind the scenes say skipOffstage: false.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/redirect.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../fakes/app_harness.dart';
import '../../fakes/fake_controllers.dart';

late AppHarness app;

Finder get bar => find.byType(NavigationBar);

int selectedPlace(WidgetTester tester) =>
    tester.widget<NavigationBar>(bar).selectedIndex;

/// Taps [word] ("Home" or "Account") in the bar.
Future<void> tapBar(WidgetTester tester, String word) async {
  await tester.tap(find.descendant(of: bar, matching: find.text(word)));
  await tester.pumpAndSettle();
}

/// The title on each role's home.
String titleOf(Role role) => switch (role) {
  Role.miner => AppText.minerTitle,
  Role.transporter => AppText.transporterTitle,
  Role.buyer => AppText.buyerTitle,
  Role.officer => AppText.officerTitle,
  Role.admin => AppText.adminTitle,
};

Future<void> start(WidgetTester tester, AuthState state) async {
  app = await AppHarness.pump(tester, FakeAuthController(state));
}

void main() {
  for (final role in Role.values) {
    testWidgets('${role.name}: Home, then Account, then Home again, with the '
        'bar on both', (tester) async {
      await start(tester, signedInAs(role));
      expect(app.path, homeOf(role));
      expect(bar, findsOneWidget);
      expect(selectedPlace(tester), 0);

      await tapBar(tester, AppText.navAccount);
      expect(app.path, AppRoutes.account);
      expect(find.widgetWithText(AppBar, AppText.myAccount), findsOneWidget);
      expect(bar, findsOneWidget);
      expect(selectedPlace(tester), 1);

      await tapBar(tester, AppText.navHome);
      expect(app.path, homeOf(role));
      expect(find.text(titleOf(role)), findsOneWidget);
      expect(selectedPlace(tester), 0);
    });
  }

  // Q9: one "My account", two ways in.
  testWidgets('the top bar\'s account button opens the same Account place, '
      'shown as chosen in the bar', (tester) async {
    await start(tester, signedInAs(Role.transporter));

    await tester.tap(find.byTooltip(AppText.myAccount));
    await tester.pumpAndSettle();

    expect(app.path, AppRoutes.account);
    expect(selectedPlace(tester), 1);
    // Only one account page in the app, not one pushed on top of another.
    expect(
      find.widgetWithText(AppBar, AppText.myAccount, skipOffstage: false),
      findsOneWidget,
    );

    await tapBar(tester, AppText.navHome);
    expect(app.path, AppRoutes.transporter);
  });

  testWidgets('the home keeps its scroll position while Account is open', (
    tester,
  ) async {
    // Large text, so the admin's home is taller than the screen.
    app = await AppHarness.pump(
      tester,
      FakeAuthController(signedInAs(Role.admin)),
      textScale: 2.0,
    );
    final home = find.byType(Scrollable).first;
    await tester.drag(home, const Offset(0, -300));
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(home).position.pixels;
    expect(before, greaterThan(0));

    await tapBar(tester, AppText.navAccount);
    await tapBar(tester, AppText.navHome);

    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      before,
    );
  });

  // The frame must not keep the last user's home for the next one.
  testWidgets('log out as a miner, log in as an administrator: Home is the '
      'admin\'s home, and no miner page is left anywhere', (tester) async {
    await start(tester, signedInAs(Role.miner));
    await tapBar(tester, AppText.navAccount);

    app.auth.setState(const SignedOut());
    await tester.pumpAndSettle();
    expect(app.path, AppRoutes.login);
    expect(bar, findsNothing);

    app.auth.setState(signedInAs(Role.admin));
    await tester.pumpAndSettle();
    expect(app.path, AppRoutes.admin);
    expect(selectedPlace(tester), 0);

    await tapBar(tester, AppText.navAccount);
    await tapBar(tester, AppText.navHome);
    expect(app.path, AppRoutes.admin);
    expect(find.text(AppText.adminTitle), findsOneWidget);
    expect(find.text(AppText.minerTitle, skipOffstage: false), findsNothing);
  });

  // Mobile (11): an expired token keeps the app open; only server actions
  // ask for the password again.
  testWidgets('token expired: both places open, and each shows its password '
      'notice', (tester) async {
    await start(tester, SignedInNeedsPassword(userOf(Role.buyer)));
    expect(app.path, AppRoutes.buyer);
    expect(find.text(AppText.needsPasswordNotice), findsOneWidget);

    await tapBar(tester, AppText.navAccount);
    expect(app.path, AppRoutes.account);
    expect(find.text(AppText.accountNeedsPassword), findsOneWidget);

    await tapBar(tester, AppText.navHome);
    expect(app.path, AppRoutes.buyer);
  });

  testWidgets('signed out: no bar on login, register or activate', (
    tester,
  ) async {
    await start(tester, const SignedOut());
    final router = app.container.read(appRouterProvider);

    for (final page in [
      AppRoutes.login,
      AppRoutes.register,
      AppRoutes.activate,
    ]) {
      router.go(page);
      await tester.pumpAndSettle();
      expect(app.path, page);
      expect(bar, findsNothing, reason: page);
    }
  });

  // Redirect rule 4 holds inside the frame too.
  testWidgets('a miner sent to the admin home ends on the miner home, in the '
      'frame', (tester) async {
    await start(tester, signedInAs(Role.miner));
    app.container.read(appRouterProvider).go(AppRoutes.admin);
    await tester.pumpAndSettle();

    expect(app.path, AppRoutes.miner);
    expect(selectedPlace(tester), 0);
    expect(find.text(AppText.adminTitle, skipOffstage: false), findsNothing);
  });
}
