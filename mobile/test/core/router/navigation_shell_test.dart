// T11 (Mobile (37)): the frame with the navigation bar around the homes and
// "My account", in the real app and router with a stand-in auth controller.
//
// Finders skip what is offstage. While Account is shown the home is kept
// alive but offstage, so a finder only sees the place on screen; the tests
// that must look behind the scenes say skipOffstage: false.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/redirect.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/action_tile.dart';
import 'package:minechain/core/widgets/app_navigation.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../fakes/android_back.dart';
import '../../fakes/app_harness.dart';
import '../../fakes/fake_controllers.dart';
import '../../fakes/word_breaks.dart';

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

  // T12 (Mobile (37)): the bar's layout, the rail on a phone turned on its
  // side, large text, Android's back button, tap size and TalkBack.
  //
  // Flutter's bar draws its words at most 1.3 times their size; the rail has
  // no limit. The test font draws every letter as a square one font size
  // wide, so at text 2.0 "Account" in the rail is 7 × 28 = 196 dp, wider than
  // the rail's 144 dp for a word, and is drawn just small enough to stay
  // whole (the tiles' rule, Mobile (36), Q6). On the phone Roboto draws it at
  // about 110 dp, so it keeps the full size there.
  group('layout', () {
    const portrait = Size(360, 640);
    const landscape = Size(640, 360);

    /// The bar or the rail, whichever is shown.
    Finder navigation(Size size) => size.height < AppSizes.compactHeight
        ? find.byType(NavigationRail)
        : bar;

    /// Both words are drawn whole, inside the bar or rail, never broken.
    void expectWordsWhole(WidgetTester tester, Size size) {
      final nav = tester.getRect(navigation(size));
      for (final word in [AppText.navHome, AppText.navAccount]) {
        final text = find.descendant(
          of: navigation(size),
          matching: find.text(word),
        );
        expect(text, findsOneWidget, reason: word);
        expect(lineEndsInsideWords(tester, text), isEmpty, reason: word);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.01),
          reason: '"$word" on one line',
        );
        final rect = tester.getRect(text);
        expect(rect.top, greaterThanOrEqualTo(nav.top), reason: word);
        expect(rect.bottom, lessThanOrEqualTo(nav.bottom), reason: word);
        expect(rect.left, greaterThanOrEqualTo(nav.left), reason: word);
        expect(rect.right, lessThanOrEqualTo(nav.right), reason: word);
      }
    }

    for (final role in Role.values) {
      for (final (name, size) in [
        ('portrait', portrait),
        ('landscape', landscape),
      ]) {
        for (final textScale in [1.0, 2.0]) {
          testWidgets('${role.name}, $name, text $textScale: '
              '${size == portrait ? 'a bar below' : 'a rail beside'}, words '
              'whole, every tile reachable, and Account fits too', (
            tester,
          ) async {
            app = await AppHarness.pump(
              tester,
              FakeAuthController(signedInAs(role)),
              size: size,
              textScale: textScale,
            );
            expect(tester.takeException(), isNull);
            expect(navigation(size), findsOneWidget);
            expect(
              size == portrait ? find.byType(NavigationRail) : bar,
              findsNothing,
            );
            expectWordsWhole(tester, size);

            // Every tile can be scrolled into view, clear of the bar or rail.
            final nav = tester.getRect(navigation(size));
            final labels = [
              for (final tile in tester.widgetList<ActionTile>(
                find.byType(ActionTile),
              ))
                tile.label,
            ];
            expect(labels, isNotEmpty);
            for (final label in labels) {
              final tile = find.ancestor(
                of: find.text(label),
                matching: find.byType(ActionTile),
              );
              await tester.ensureVisible(tile);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final rect = tester.getRect(tile);
              if (size == portrait) {
                expect(rect.bottom, lessThanOrEqualTo(nav.top), reason: label);
              } else {
                expect(
                  rect.left,
                  greaterThanOrEqualTo(nav.right),
                  reason: label,
                );
              }
            }

            await tester.tap(
              find.descendant(
                of: navigation(size),
                matching: find.text(AppText.navAccount),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(app.path, AppRoutes.account);
            expectWordsWhole(tester, size);
          });
        }
      }
    }

    // Records what Flutter does, so a Flutter upgrade that changes it shows
    // up here: the bar's words stop at 1.3 times; the rail's follow the phone.
    testWidgets('text sizes: the bar\'s words stop at 1.3 times, the rail\'s '
        'follow the phone', (tester) async {
      double drawnSize(Finder nav) => drawnFontSize(
        tester,
        find.descendant(of: nav, matching: find.text(AppText.navAccount)),
      );

      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.miner)),
        textScale: 2.0,
      );
      expect(
        drawnSize(bar),
        closeTo(14 * AppNavigationShell.barWordMaxScale, 0.01),
      );

      // 1.3 in the rail: "Account" is 7 × 18.2 = 127 dp, under its 144 dp.
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.miner)),
        size: landscape,
        textScale: 1.3,
      );
      expect(drawnSize(find.byType(NavigationRail)), closeTo(14 * 1.3, 0.01));
    });

    testWidgets('portrait, text 2.0: the bar is taller than at text 1.0', (
      tester,
    ) async {
      await start(tester, signedInAs(Role.miner));
      final normal = tester.getSize(bar).height;

      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.miner)),
        textScale: 2.0,
      );
      expect(tester.getSize(bar).height, greaterThan(normal));
    });

    testWidgets('landscape: the rail switches places too', (tester) async {
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.officer)),
        size: landscape,
      );
      final rail = find.byType(NavigationRail);

      await tester.tap(
        find.descendant(of: rail, matching: find.text(AppText.navAccount)),
      );
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.account);
      expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);

      await tester.tap(
        find.descendant(of: rail, matching: find.text(AppText.navHome)),
      );
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.officer);
      expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
    });

    for (final (name, size) in [
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      testWidgets('$name: each place is at least 56 dp to tap', (tester) async {
        app = await AppHarness.pump(
          tester,
          FakeAuthController(signedInAs(Role.buyer)),
          size: size,
        );
        for (final word in [AppText.navHome, AppText.navAccount]) {
          final target = find
              .ancestor(
                of: find.descendant(
                  of: navigation(size),
                  matching: find.text(word),
                ),
                matching: find.byWidgetPredicate((w) => w is InkResponse),
              )
              .first;
          final area = tester.getSize(target);
          expect(area.width, greaterThanOrEqualTo(AppSizes.tapTargetMin));
          expect(area.height, greaterThanOrEqualTo(AppSizes.tapTargetMin));
        }
      });
    }
  });

  group('Android back button', () {
    testWidgets('on Account: back to Home, the app stays open', (tester) async {
      final exit = AppExitWatch(tester);
      await start(tester, signedInAs(Role.admin));
      await tapBar(tester, AppText.navAccount);

      await pressAndroidBack(tester);

      expect(app.path, AppRoutes.admin);
      expect(selectedPlace(tester), 0);
      expect(exit.exits, 0);
    });

    testWidgets('on Home: the app closes, as usual on Android', (tester) async {
      final exit = AppExitWatch(tester);
      await start(tester, signedInAs(Role.admin));

      await pressAndroidBack(tester);

      expect(exit.exits, 1);
    });
  });

  testWidgets('TalkBack names each place as a tab, the chosen one selected', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await start(tester, signedInAs(Role.miner));

    expect(
      find.bySemanticsLabel(RegExp(r'Home.*Tab 1 of 2', dotAll: true)),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Account.*Tab 2 of 2', dotAll: true)),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'Home.*Tab 1 of 2', dotAll: true)),
      ),
      isSemantics(isSelected: true),
    );
    semantics.dispose();
  });
}
