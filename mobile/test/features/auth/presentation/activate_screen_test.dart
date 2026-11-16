// The activate screen inside the real app and router, with a stand-in auth
// controller: checks before sending, what is sent, the router moving to the
// home on success, the plain sentence for a bad code, and small screens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';

late AppHarness app;

Future<void> openActivate(
  WidgetTester tester, {
  Future<LoginOutcome> Function()? answer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(const SignedOut(), activateAnswer: answer),
    size: size,
    textScale: textScale,
  );
  await tapVisible(tester, find.text(AppText.haveActivationCodeLink));
  expect(app.path, AppRoutes.activate);
}

final usernameField = find.widgetWithText(TextField, AppText.username);
final codeField = find.widgetWithText(TextField, AppText.activationCode);
final passwordField = find.widgetWithText(TextField, AppText.newPassword);
final confirmField = find.widgetWithText(TextField, AppText.confirmPassword);
final activateButton = find.widgetWithText(
  FilledButton,
  AppText.activateButton,
);

String? errorUnder(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).decoration!.errorText;
String textOf(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Future<void> fill(
  WidgetTester tester, {
  String password = 'copper hill solwezi',
  String? confirm,
}) async {
  await typeInto(tester, usernameField, 'chanda_mwale');
  await typeInto(tester, codeField, '7kq4 m2xd 9tne');
  await typeInto(tester, passwordField, password);
  await typeInto(tester, confirmField, confirm ?? password);
  await tapVisible(tester, activateButton);
}

void main() {
  testWidgets('the login link opens it, and the back arrow returns',
      (tester) async {
    await openActivate(tester);
    expect(find.text(AppText.activateTitle), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(app.path, AppRoutes.login);
  });

  testWidgets('empty form: nothing is sent', (tester) async {
    await openActivate(tester);
    await tapVisible(tester, activateButton);

    expect(app.auth.activateCalls, isEmpty);
    expect(errorUnder(tester, usernameField), AppText.enterUsername);
    expect(errorUnder(tester, codeField), AppText.enterActivationCode);
    expect(errorUnder(tester, passwordField), AppText.choosePassword);
  });

  testWidgets('passwords not the same: nothing is sent, both cleared',
      (tester) async {
    await openActivate(tester);
    await fill(tester, confirm: 'copper hill solwezy');

    expect(app.auth.activateCalls, isEmpty);
    expect(errorUnder(tester, confirmField), AppText.passwordsDoNotMatch);
    expect(textOf(tester, passwordField), isEmpty);
    expect(textOf(tester, confirmField), isEmpty);
  });

  testWidgets('success: sends what was typed, the router goes to the home',
      (tester) async {
    await openActivate(tester);
    await fill(tester);

    expect(app.auth.activateCalls, [
      {
        'username': 'chanda_mwale',
        'code': '7kq4 m2xd 9tne', // as typed; the server normalises it
        'password': 'copper hill solwezi',
      },
    ]);
    expect(app.container.read(authControllerProvider), isA<SignedIn>());
    expect(app.path, AppRoutes.officer);
    expect(find.text(AppText.officerTitle), findsOneWidget);
  });

  testWidgets('ACTIVATION_INVALID: the plain sentence, code kept, '
      'passwords cleared', (tester) async {
    await openActivate(
      tester,
      answer: () async => const LoginFailed(
        ServerRefused(
          status: 401,
          code: ApiCodes.activationInvalid,
          serverMessage: 'This activation code is not valid.',
        ),
      ),
    );
    await fill(tester);

    expect(find.text(AppText.activationInvalid), findsOneWidget);
    expect(textOf(tester, codeField), '7kq4 m2xd 9tne');
    expect(textOf(tester, usernameField), 'chanda_mwale');
    expect(textOf(tester, passwordField), isEmpty);
    expect(textOf(tester, confirmField), isEmpty);
    expect(app.path, AppRoutes.activate);
  });

  testWidgets('WEAK_PASSWORD: the reason under the new password',
      (tester) async {
    await openActivate(
      tester,
      answer: () async => const LoginFailed(
        ServerRefused(
          status: 400,
          code: ApiCodes.weakPassword,
          serverMessage: 'Choose a stronger password.',
          details: [
            FieldProblem(
              field: 'password',
              code: ApiCodes.passwordContainsUsername,
              message: 'Do not include your username in your password.',
            ),
          ],
        ),
      ),
    );
    await fill(
      tester,
      password: 'chanda_mwale rocks',
      confirm: 'chanda_mwale rocks',
    );

    expect(
      errorUnder(tester, passwordField),
      'Do not include your username in your password.',
    );
    expect(find.text(AppText.weakPassword), findsNothing);
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets(name, (tester) async {
        await openActivate(
          tester,
          answer: () async => const LoginFailed(
            ServerRefused(
              status: 401,
              code: ApiCodes.activationInvalid,
              serverMessage: 'This activation code is not valid.',
            ),
          ),
          size: size,
          textScale: scale,
        );
        await tapVisible(tester, activateButton); // every field's error
        expect(tester.takeException(), isNull);
        await fill(tester); // and then the form-level sentence
        expect(find.text(AppText.activationInvalid), findsOneWidget);
        await tester.ensureVisible(activateButton);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
