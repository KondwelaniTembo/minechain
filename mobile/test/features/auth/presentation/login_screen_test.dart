// The login screen with a stand-in auth controller: what is sent, what is
// shown, and that it fits small screens and large text.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/widgets/mine_chain_logo.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';
import 'package:minechain/features/auth/presentation/login_screen.dart';

import '../../../fakes/fake_controllers.dart';

late FakeAuthController auth;
late FakeServerStatus server;

Future<void> pumpLogin(
  WidgetTester tester, {
  AuthState state = const SignedOut(),
  Future<LoginOutcome> Function(String, String)? answer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = size * 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  auth = FakeAuthController(state, answer: answer);
  server = FakeServerStatus();
  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: fakeOverrides(auth, server: server),
      child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
    ),
  );
}

final usernameField = find.widgetWithText(TextField, AppText.username);
final passwordField = find.widgetWithText(TextField, AppText.password);
final logInButton = find.widgetWithText(FilledButton, AppText.logIn);

String fieldText(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Future<void> fillAndSubmit(
  WidgetTester tester, {
  String username = 'mutale_banda',
  String password = 'gold river kasempa',
}) async {
  await tester.enterText(usernameField, username);
  await tester.enterText(passwordField, password);
  await tester.tap(logInButton);
  await tester.pump();
}

void main() {
  testWidgets('checks the server when it opens', (tester) async {
    await pumpLogin(tester);
    expect(server.checks, 1);
  });

  // Mobile (36): the logo above the name, and the form still fits.
  testWidgets('the logo and the name are above the fields', (tester) async {
    await pumpLogin(tester);

    final brand = find.byType(BrandBlock);
    expect(find.byType(MineChainLogo), findsOneWidget);
    expect(
      tester.getRect(brand).bottom,
      lessThanOrEqualTo(tester.getRect(usernameField).top),
    );
  });

  testWidgets('empty fields: nothing is sent, both fields say what is missing',
      (tester) async {
    await pumpLogin(tester);

    await tester.tap(logInButton);
    await tester.pump();

    expect(auth.logInCalls, isEmpty);
    expect(find.text(AppText.enterUsername), findsOneWidget);
    expect(find.text(AppText.enterPassword), findsOneWidget);
  });

  testWidgets('only the password missing: nothing is sent', (tester) async {
    await pumpLogin(tester);
    await tester.enterText(usernameField, 'mutale_banda');
    await tester.tap(logInButton);
    await tester.pump();

    expect(auth.logInCalls, isEmpty);
    expect(find.text(AppText.enterPassword), findsOneWidget);
  });

  testWidgets('success: the controller gets exactly what was typed',
      (tester) async {
    await pumpLogin(tester);
    await fillAndSubmit(tester);

    expect(auth.logInCalls, [('mutale_banda', 'gold river kasempa')]);
  });

  testWidgets('wrong password: the sentence, password cleared, username kept',
      (tester) async {
    await pumpLogin(
      tester,
      answer: (_, _) async => const LoginFailed(
        ServerRefused(
          status: 401,
          code: ApiCodes.invalidCredentials,
          serverMessage: 'Username or password is incorrect.',
        ),
      ),
    );

    await fillAndSubmit(tester);
    await tester.pump();

    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(fieldText(tester, passwordField), isEmpty);
    expect(fieldText(tester, usernameField), 'mutale_banda');
  });

  testWidgets('VALIDATION_FAILED details go under their fields', (tester) async {
    await pumpLogin(
      tester,
      answer: (_, _) async => const LoginFailed(
        ServerRefused(
          status: 400,
          code: ApiCodes.validationFailed,
          serverMessage: 'Some fields are missing or invalid.',
          details: [FieldProblem(field: 'username', message: 'is too long')],
        ),
      ),
    );

    await fillAndSubmit(tester);
    await tester.pump();

    expect(find.text('is too long'), findsOneWidget);
    expect(find.text(AppText.checkTheForm), findsOneWidget);
  });

  testWidgets('an unsupported account shows the update sentence',
      (tester) async {
    await pumpLogin(
      tester,
      answer: (_, _) async =>
          const LoginNotPossible(AuthReasons.unsupportedRole),
    );
    await fillAndSubmit(tester);
    await tester.pump();
    expect(find.text(AppText.unsupportedApp), findsOneWidget);
  });

  testWidgets('the button is disabled while a login runs', (tester) async {
    final answer = Completer<LoginOutcome>();
    await pumpLogin(tester, answer: (_, _) => answer.future);

    await fillAndSubmit(tester);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text(AppText.loggingIn), findsOneWidget);

    // A second tap does nothing.
    await tester.tap(find.byType(FilledButton));
    expect(auth.logInCalls, hasLength(1));

    answer.complete(const LoginSucceeded());
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('the show/hide button reveals the password and has a tooltip',
      (tester) async {
    await pumpLogin(tester);
    TextField password() => tester.widget<TextField>(passwordField);

    expect(password().obscureText, isTrue);
    expect(find.byTooltip(AppText.showPassword), findsOneWidget);

    await tester.tap(find.byTooltip(AppText.showPassword));
    await tester.pump();

    expect(password().obscureText, isFalse);
    expect(find.byTooltip(AppText.hidePassword), findsOneWidget);
  });

  group('a field\'s error clears when that field is edited', () {
    String? errorUnder(WidgetTester tester, Finder field) =>
        tester.widget<TextField>(field).decoration!.errorText;

    testWidgets('a local check: gone on edit, back on Log in', (tester) async {
      await pumpLogin(tester);
      await tester.tap(logInButton);
      await tester.pump();
      expect(errorUnder(tester, usernameField), AppText.enterUsername);
      expect(errorUnder(tester, passwordField), AppText.enterPassword);

      await tester.enterText(usernameField, 'm');
      await tester.pump();
      expect(errorUnder(tester, usernameField), isNull);
      // Only the edited field's error goes.
      expect(errorUnder(tester, passwordField), AppText.enterPassword);

      await tester.enterText(usernameField, '');
      await tester.tap(logInButton);
      await tester.pump();
      expect(errorUnder(tester, usernameField), AppText.enterUsername);
      expect(auth.logInCalls, isEmpty);
    });

    testWidgets('a server detail: gone on edit, back on Log in',
        (tester) async {
      await pumpLogin(
        tester,
        answer: (_, _) async => const LoginFailed(
          ServerRefused(
            status: 400,
            code: ApiCodes.validationFailed,
            serverMessage: 'Some fields are missing or invalid.',
            details: [FieldProblem(field: 'username', message: 'is too long')],
          ),
        ),
      );
      await fillAndSubmit(tester);
      await tester.pump();
      expect(errorUnder(tester, usernameField), 'is too long');

      await tester.enterText(usernameField, 'mutale_band');
      await tester.pump();
      expect(errorUnder(tester, usernameField), isNull);

      await fillAndSubmit(tester);
      await tester.pump();
      expect(errorUnder(tester, usernameField), 'is too long');
    });
  });

  group('a sign-out reason is shown on arrival', () {
    final reasons = {
      ApiCodes.tokenInvalid: AppText.sessionNotValid,
      ApiCodes.accountSuspended: AppText.accountSuspended,
      ApiCodes.accountPending: AppText.accountPending,
      ApiCodes.accountRejected: AppText.accountRejected,
      ApiCodes.accountNotActive: AppText.accountNotActive,
      AuthReasons.unsupportedRole: AppText.unsupportedApp,
      AuthReasons.accountChanged: AppText.accountChanged,
    };
    reasons.forEach((reason, sentence) {
      testWidgets(reason, (tester) async {
        await pumpLogin(tester, state: SignedOut(reason: reason));
        expect(find.text(sentence), findsOneWidget);
      });
    });

    testWidgets('no reason, no sentence', (tester) async {
      await pumpLogin(tester);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait', const Size(360, 640), 1.0),
      ('landscape', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets(name, (tester) async {
        await pumpLogin(
          tester,
          state: const SignedOut(reason: ApiCodes.accountSuspended),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        // The button can be scrolled to and reached.
        await tester.ensureVisible(logInButton);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
