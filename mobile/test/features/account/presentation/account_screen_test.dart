// The account screen and the password prompt, inside the real app and router
// with a stand-in auth controller: what is shown, that Log out asks first,
// that the router follows the sign-in state, and that everything fits small
// screens and large text. No network, no secure storage.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/theme/sizes.dart';
import 'package:minechain/core/widgets/pill_button.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';
import 'package:minechain/main.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart' show tapVisible;
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';

late ProviderContainer container;
late FakeAuthController auth;

/// Starts the whole app in [state]; it lands on the role's home.
Future<void> pumpApp(
  WidgetTester tester,
  AuthState state, {
  Future<LoginOutcome> Function(String password)? reauthAnswer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = size * 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final config =
      (AppConfig.check('https://api.example.test') as ConfigOk).config;
  auth = FakeAuthController(state, reauthAnswer: reauthAnswer);
  container = ProviderContainer.test(
    retry: noRetry,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      ...fakeOverrides(auth),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MineChainApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Starts the app, then opens the account screen the way a user does: the
/// account icon on the home.
Future<void> pumpAccount(
  WidgetTester tester,
  AuthState state, {
  Future<LoginOutcome> Function(String password)? reauthAnswer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await pumpApp(
    tester,
    state,
    reauthAnswer: reauthAnswer,
    size: size,
    textScale: textScale,
  );
  await tester.tap(find.byTooltip(AppText.myAccount));
  await tester.pumpAndSettle();
}

/// The path of the top-most screen. `router.state` reads the LAST match, so
/// it sees a pushed screen; `currentConfiguration.uri` would still say the
/// home's path after a push(), because push adds a match without changing
/// the base address.
String get path => container.read(appRouterProvider).state.uri.path;

// The screen's Log out button, and the one inside the question.
final screenLogOut = find.widgetWithText(FilledButton, AppText.logOut).first;
Finder get dialogLogOut => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.widgetWithText(FilledButton, AppText.logOut),
);

final prompt = find.byType(PasswordPromptDialog);
final promptField = find.descendant(
  of: prompt,
  matching: find.byType(TextField),
);
final promptContinue = find.descendant(
  of: prompt,
  matching: find.widgetWithText(FilledButton, AppText.continueLabel),
);

const wrongPassword = LoginFailed(
  ServerRefused(
    status: 401,
    code: ApiCodes.invalidCredentials,
    serverMessage: 'Username or password is incorrect.',
  ),
);

/// Opens the prompt from the account screen's notice.
Future<void> openPrompt(WidgetTester tester) async {
  await tapVisible(
    tester,
    find.widgetWithText(FilledButton, AppText.enterYourPassword),
  );
  expect(prompt, findsOneWidget);
}

void main() {
  group('the account screen', () {
    testWidgets('opens from the home and shows the user\'s details', (
      tester,
    ) async {
      await pumpAccount(tester, signedInAs(Role.miner));

      expect(path, AppRoutes.account);
      expect(find.text(AppText.myAccount), findsOneWidget);
      // The fixture user: Mutale Banda, mutale_banda, ZM-ASM-0042.
      expect(find.text('Mutale Banda'), findsOneWidget);
      expect(find.text(AppText.minerTitle), findsOneWidget); // the role word
      expect(find.text('mutale_banda'), findsOneWidget);
      expect(find.text(AppText.licenceNumber), findsOneWidget);
      expect(find.text('ZM-ASM-0042'), findsOneWidget);
    });

    // Mobile (36), T8: the details card in the tiles' sand, raised, with a
    // copper outline so its edge shows on the light screen.
    testWidgets('the details card: sand, a shadow and a copper outline', (
      tester,
    ) async {
      await pumpAccount(tester, signedInAs(Role.miner));

      final card = find.byType(Card);
      expect(card, findsOneWidget);
      final scheme = Theme.of(tester.element(card)).colorScheme;
      final material = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)).first,
      );
      expect(material.color, scheme.secondaryContainer);
      expect(material.elevation, 3);
      expect(
        (material.shape! as RoundedRectangleBorder).side.color,
        scheme.primary,
      );
    });

    testWidgets('no licence number: the row is left out', (tester) async {
      final json = userJson(role: 'officer')..['licenceNumber'] = null;
      final officer = (User.fromJson(json) as UserParsed).user;
      await pumpAccount(
        tester,
        SignedIn(
          user: officer,
          token: fakeToken,
          expiresAt: DateTime.utc(2026, 11, 16, 10),
        ),
      );

      expect(find.text(AppText.officerTitle), findsOneWidget);
      expect(find.text(AppText.licenceNumber), findsNothing);
    });

    // Changed by decision (Mobile (37), Q10). Until T12 this test tapped the
    // back arrow. "My account" is now one of the navigation bar's two
    // places, so it has no back arrow; Home in the bar and Android's back
    // button take the user home instead.
    testWidgets('no back arrow; Home in the bar returns to the home', (
      tester,
    ) async {
      await pumpAccount(tester, signedInAs(Role.transporter));
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(AppText.navHome),
        ),
      );
      await tester.pumpAndSettle();

      expect(path, AppRoutes.transporter);
      expect(find.text(AppText.takeCustody), findsOneWidget);
    });

    testWidgets('Android\'s back button returns to the home', (tester) async {
      await pumpAccount(tester, signedInAs(Role.transporter));

      await pressAndroidBack(tester);

      expect(path, AppRoutes.transporter);
      expect(find.text(AppText.takeCustody), findsOneWidget);
    });

    // Every role, in both signed-in states (decision Q2).
    for (final role in Role.values) {
      for (final state in <AuthState>[
        signedInAs(role),
        SignedInNeedsPassword(userOf(role)),
      ]) {
        testWidgets('opens for ${role.name}, ${state.runtimeType}', (
          tester,
        ) async {
          await pumpAccount(tester, state);
          expect(path, AppRoutes.account);
          expect(find.text(AppText.myAccount), findsOneWidget);
        });
      }
    }
  });

  group('Log out', () {
    testWidgets('asks first; Cancel does nothing', (tester) async {
      await pumpAccount(tester, signedInAs(Role.buyer));

      await tester.tap(screenLogOut);
      await tester.pumpAndSettle();
      expect(find.text(AppText.logOutQuestion), findsOneWidget);
      expect(auth.logOutCalls, 0); // asking is not logging out

      await tester.tap(find.widgetWithText(TextButton, AppText.cancel));
      await tester.pumpAndSettle();

      expect(find.text(AppText.logOutQuestion), findsNothing);
      expect(auth.logOutCalls, 0);
      expect(path, AppRoutes.account);
    });

    testWidgets('confirming logs out, and the router moves to /login', (
      tester,
    ) async {
      await pumpAccount(tester, signedInAs(Role.admin));

      await tester.tap(screenLogOut);
      await tester.pumpAndSettle();
      await tester.tap(dialogLogOut);
      await tester.pumpAndSettle();

      expect(auth.logOutCalls, 1);
      expect(path, AppRoutes.login);
      expect(find.widgetWithText(FilledButton, AppText.logIn), findsOneWidget);
    });

    testWidgets('a logout from elsewhere also leaves /account', (tester) async {
      await pumpAccount(tester, signedInAs(Role.officer));
      auth.setState(const SignedOut(reason: ApiCodes.accountSuspended));
      await tester.pumpAndSettle();

      expect(path, AppRoutes.login);
      expect(find.text(AppText.accountSuspended), findsOneWidget);
    });
  });

  group('the needs-password notice', () {
    testWidgets('not shown while signed in', (tester) async {
      await pumpAccount(tester, signedInAs(Role.miner));
      expect(find.text(AppText.accountNeedsPassword), findsNothing);
      expect(
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
        findsNothing,
      );
    });

    testWidgets('shown, with its button, when the token has expired', (
      tester,
    ) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      expect(find.text(AppText.accountNeedsPassword), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
        findsOneWidget,
      );
    });

    // Mobile (36), Q4: the same copper notice and pill button as on the homes.
    testWidgets('copper, with the pill button at full tap height', (
      tester,
    ) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));

      final card = find
          .ancestor(
            of: find.text(AppText.accountNeedsPassword),
            matching: find.byType(Material),
          )
          .first;
      expect(
        tester.widget<Material>(card).color,
        AppTheme.light.colorScheme.primary,
      );
      final button = find.widgetWithText(PillButton, AppText.enterYourPassword);
      expect(button, findsOneWidget);
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(AppSizes.tapTargetMin),
      );
    });

    testWidgets('the home\'s notice button opens the same prompt', (
      tester,
    ) async {
      await pumpApp(tester, SignedInNeedsPassword(userOf(Role.miner)));

      // A PillButton since Mobile (36) (it was a TextButton on the green
      // notice); the tap and the prompt are unchanged.
      await tester.tap(
        find.widgetWithText(PillButton, AppText.enterPasswordButton),
      );
      await tester.pumpAndSettle();

      expect(prompt, findsOneWidget);
    });
  });

  group('the password prompt', () {
    testWidgets('an empty password: nothing is sent', (tester) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      await openPrompt(tester);

      await tester.tap(promptContinue);
      await tester.pumpAndSettle();

      expect(auth.reauthenticateCalls, isEmpty);
      expect(find.text(AppText.enterPassword), findsOneWidget);
      expect(prompt, findsOneWidget);
    });

    testWidgets('the empty-field error goes on typing, back on Continue', (
      tester,
    ) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      await openPrompt(tester);
      String? error() =>
          tester.widget<TextField>(promptField).decoration!.errorText;

      await tester.tap(promptContinue);
      await tester.pump();
      expect(error(), AppText.enterPassword);

      await tester.enterText(promptField, 'g');
      await tester.pump();
      expect(error(), isNull);

      await tester.enterText(promptField, '');
      await tester.tap(promptContinue);
      await tester.pump();
      expect(error(), AppText.enterPassword);
      expect(auth.reauthenticateCalls, isEmpty);
    });

    testWidgets(
      'a wrong password: the sentence, the field cleared, still open',
      (tester) async {
        await pumpAccount(
          tester,
          SignedInNeedsPassword(userOf(Role.miner)),
          reauthAnswer: (_) async => wrongPassword,
        );
        await openPrompt(tester);

        await tester.enterText(promptField, 'not my password');
        await tester.tap(promptContinue);
        await tester.pumpAndSettle();

        expect(auth.reauthenticateCalls, ['not my password']);
        expect(find.text(AppText.invalidCredentials), findsOneWidget);
        expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
        expect(prompt, findsOneWidget);
        // The notice stays, because the state did not change.
        expect(find.text(AppText.accountNeedsPassword), findsOneWidget);
      },
    );

    testWidgets('the right password: the prompt closes, the notice goes', (
      tester,
    ) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      await openPrompt(tester);

      await tester.enterText(promptField, fakePassword);
      await tester.tap(promptContinue);
      await tester.pumpAndSettle();

      expect(auth.reauthenticateCalls, [fakePassword]);
      expect(prompt, findsNothing);
      expect(find.text(AppText.accountNeedsPassword), findsNothing);
      expect(container.read(authControllerProvider), isA<SignedIn>());
      expect(path, AppRoutes.account);
    });

    testWidgets('Cancel closes it and sends nothing', (tester) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      await openPrompt(tester);

      await tester.enterText(promptField, fakePassword);
      await tester.tap(
        find.descendant(
          of: prompt,
          matching: find.widgetWithText(TextButton, AppText.cancel),
        ),
      );
      await tester.pumpAndSettle();

      expect(prompt, findsNothing);
      expect(auth.reauthenticateCalls, isEmpty);
    });

    testWidgets('signed out while checking (a suspended account): it closes', (
      tester,
    ) async {
      await pumpAccount(
        tester,
        SignedInNeedsPassword(userOf(Role.miner)),
        reauthAnswer: (_) async {
          // What the real controller does for a 403 at login.
          auth.setState(const SignedOut(reason: ApiCodes.accountSuspended));
          return const LoginFailed(
            ServerRefused(
              status: 403,
              code: ApiCodes.accountSuspended,
              serverMessage: 'Your account has been suspended.',
            ),
          );
        },
      );
      await openPrompt(tester);

      await tester.enterText(promptField, fakePassword);
      await tester.tap(promptContinue);
      await tester.pumpAndSettle();

      expect(prompt, findsNothing);
      expect(path, AppRoutes.login);
      expect(find.text(AppText.accountSuspended), findsOneWidget);
    });

    testWidgets('show/hide reveals the password and has a tooltip', (
      tester,
    ) async {
      await pumpAccount(tester, SignedInNeedsPassword(userOf(Role.miner)));
      await openPrompt(tester);
      TextField field() => tester.widget<TextField>(promptField);

      expect(field().obscureText, isTrue);
      await tester.tap(find.byTooltip(AppText.showPassword));
      await tester.pump();
      expect(field().obscureText, isFalse);
      expect(find.byTooltip(AppText.hidePassword), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('account screen: $name', (tester) async {
        // The needs-password state shows the most: notice, button, details.
        await pumpAccount(
          tester,
          SignedInNeedsPassword(userOf(Role.miner)),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(screenLogOut);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('password prompt with a failure: $name', (tester) async {
        await pumpAccount(
          tester,
          SignedInNeedsPassword(userOf(Role.miner)),
          reauthAnswer: (_) async => wrongPassword,
          size: size,
          textScale: scale,
        );
        await openPrompt(tester);
        await tester.enterText(promptField, 'not my password');
        await tester.tap(promptContinue);
        await tester.pumpAndSettle();

        expect(find.text(AppText.invalidCredentials), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(promptContinue);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('Log out question: $name', (tester) async {
        await pumpAccount(
          tester,
          signedInAs(Role.miner),
          size: size,
          textScale: scale,
        );
        await tapVisible(tester, screenLogOut);
        expect(find.text(AppText.logOutQuestion), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
