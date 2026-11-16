// The register screen inside the real app and router, with a stand-in auth
// controller: what is checked before sending, what is sent, where each
// server answer is shown, the confirmation, the way back, and small screens.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';

late AppHarness app;

/// Starts signed out, then follows the login screen's link.
Future<void> openRegister(
  WidgetTester tester, {
  Future<RegisterOutcome> Function()? answer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(const SignedOut(), registerAnswer: answer),
    size: size,
    textScale: textScale,
  );
  await tapVisible(tester, find.text(AppText.requestAccountLink));
  expect(app.path, AppRoutes.register);
}

final fullNameField = find.widgetWithText(TextField, AppText.fullName);
final usernameField = find.widgetWithText(TextField, AppText.username);
final licenceField = find.widgetWithText(
  TextField,
  AppText.licenceNumberOptional,
);
final passwordField = find.widgetWithText(TextField, AppText.password);
final confirmField = find.widgetWithText(TextField, AppText.confirmPassword);
final sendButton = find.widgetWithText(FilledButton, AppText.sendRequest);

String? errorUnder(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).decoration!.errorText;
String textOf(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Finder roleOption(Role role) => find.text(switch (role) {
  Role.miner => AppText.minerTitle,
  Role.transporter => AppText.transporterTitle,
  Role.buyer => AppText.buyerTitle,
  _ => throw ArgumentError('not offered'),
});

/// Fills every field. [send] taps the button too.
Future<void> fill(
  WidgetTester tester, {
  Role? role = Role.miner,
  String licence = 'ZM-ASM-0042',
  String password = 'gold river kasempa',
  String? confirm,
  bool send = true,
}) async {
  await typeInto(tester, fullNameField, 'Mutale Banda');
  await typeInto(tester, usernameField, 'mutale_banda');
  if (role != null) await tapVisible(tester, roleOption(role));
  await typeInto(tester, licenceField, licence);
  await typeInto(tester, passwordField, password);
  await typeInto(tester, confirmField, confirm ?? password);
  if (send) await tapVisible(tester, sendButton);
}

ServerRefused refused(
  String code, {
  int status = 400,
  List<FieldProblem> details = const [],
}) => ServerRefused(
  status: status,
  code: code,
  serverMessage: 'The server says no.',
  details: details,
);

void main() {
  testWidgets('the login link opens it, and the back arrow returns',
      (tester) async {
    await openRegister(tester);
    expect(find.text(AppText.registerTitle), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(app.path, AppRoutes.login);
  });

  testWidgets('offers exactly the three roles api.md allows', (tester) async {
    await openRegister(tester);
    for (final role in registrableRoles) {
      expect(roleOption(role), findsOneWidget);
    }
    expect(find.text(AppText.officerTitle), findsNothing);
    expect(find.text(AppText.adminTitle), findsNothing);
  });

  testWidgets('shows the password policy as a hint', (tester) async {
    await openRegister(tester);
    expect(find.text(AppText.passwordPolicyHint), findsOneWidget);
  });

  testWidgets('empty form: nothing is sent, each field says what is missing',
      (tester) async {
    await openRegister(tester);
    await tapVisible(tester, sendButton);

    expect(app.auth.registerCalls, isEmpty);
    expect(errorUnder(tester, fullNameField), AppText.enterFullName);
    expect(errorUnder(tester, usernameField), AppText.enterNewUsername);
    expect(find.text(AppText.chooseRole), findsOneWidget);
    expect(errorUnder(tester, passwordField), AppText.choosePassword);
  });

  testWidgets('passwords not the same: nothing is sent, both cleared',
      (tester) async {
    await openRegister(tester);
    await fill(tester, confirm: 'gold river kasempb');

    expect(app.auth.registerCalls, isEmpty);
    expect(errorUnder(tester, confirmField), AppText.passwordsDoNotMatch);
    expect(textOf(tester, passwordField), isEmpty);
    expect(textOf(tester, confirmField), isEmpty);
  });

  testWidgets('success: sends what was typed, shows the confirmation, '
      'stays signed out', (tester) async {
    await openRegister(tester);
    await fill(tester, role: Role.transporter);

    expect(app.auth.registerCalls, [
      {
        'username': 'mutale_banda',
        'fullName': 'Mutale Banda',
        'password': 'gold river kasempa',
        'role': Role.transporter,
        'licenceNumber': 'ZM-ASM-0042',
      },
    ]);
    expect(find.text(AppText.requestSentTitle), findsOneWidget);
    expect(find.text(AppText.requestSentBody), findsOneWidget);
    expect(app.container.read(authControllerProvider), isA<SignedOut>());
    expect(app.path, AppRoutes.register);

    await tapVisible(
      tester,
      find.widgetWithText(FilledButton, AppText.backToLogin),
    );
    expect(app.path, AppRoutes.login);
  });

  // api.md lists licenceNumber as optional with no rule per role, so every
  // role shows the field and may leave it empty.
  for (final role in registrableRoles) {
    testWidgets('${role.name}: licence shown, optional', (tester) async {
      await openRegister(tester);
      await tapVisible(tester, roleOption(role));
      expect(licenceField, findsOneWidget);

      await fill(tester, role: role, licence: '');

      expect(app.auth.registerCalls.single['role'], role);
      expect(app.auth.registerCalls.single['licenceNumber'], '');
      expect(find.text(AppText.requestSentTitle), findsOneWidget);
    });
  }

  testWidgets('WEAK_PASSWORD: each reason under the password, fields cleared',
      (tester) async {
    await openRegister(
      tester,
      answer: () async => RegisterFailed(
        refused(
          ApiCodes.weakPassword,
          details: const [
            FieldProblem(
              field: 'password',
              code: ApiCodes.passwordTooShort,
              message: 'Use at least 12 characters.',
            ),
            FieldProblem(
              field: 'password',
              code: ApiCodes.passwordTooCommon,
              message: 'This password is too common.',
            ),
          ],
        ),
      ),
    );
    await fill(tester, password: 'password', confirm: 'password');

    expect(
      errorUnder(tester, passwordField),
      'Use at least 12 characters.\nThis password is too common.',
    );
    // Explained under the field, so no second sentence under the form.
    expect(find.text(AppText.weakPassword), findsNothing);
    expect(textOf(tester, passwordField), isEmpty);
    expect(textOf(tester, confirmField), isEmpty);
    // The rest of the form is kept.
    expect(textOf(tester, usernameField), 'mutale_banda');
  });

  testWidgets('USERNAME_TAKEN: under the username', (tester) async {
    await openRegister(
      tester,
      answer: () async =>
          RegisterFailed(refused(ApiCodes.usernameTaken, status: 409)),
    );
    await fill(tester);

    expect(errorUnder(tester, usernameField), AppText.usernameTaken);
    expect(find.text(AppText.requestSentTitle), findsNothing);
  });

  testWidgets('VALIDATION_FAILED: details under their fields, and a sentence',
      (tester) async {
    await openRegister(
      tester,
      answer: () async => RegisterFailed(
        refused(
          ApiCodes.validationFailed,
          details: const [
            FieldProblem(field: 'fullName', message: 'is too long'),
            FieldProblem(field: 'username', message: 'has a character not allowed'),
          ],
        ),
      ),
    );
    await fill(tester);

    expect(errorUnder(tester, fullNameField), 'is too long');
    expect(errorUnder(tester, usernameField), 'has a character not allowed');
    expect(find.text(AppText.checkTheForm), findsOneWidget);
  });

  testWidgets('no network: the plain sentence', (tester) async {
    await openRegister(
      tester,
      answer: () async => const RegisterFailed(NoConnection()),
    );
    await fill(tester);
    expect(find.text(AppText.noConnection), findsOneWidget);
  });

  testWidgets('the button is disabled while sending', (tester) async {
    final answer = Completer<RegisterOutcome>();
    await openRegister(tester, answer: () => answer.future);
    await fill(tester, send: false);
    await tester.ensureVisible(sendButton);
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    // pump, not pumpAndSettle: the spinner never stops while waiting.
    await tester.pump();

    final busy = find.ancestor(
      of: find.text(AppText.sending),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(busy).onPressed, isNull);
    // A disabled button still receives the tap (nothing blocks pointers);
    // it just does nothing, which is what is being checked.
    await tester.tap(busy);
    expect(app.auth.registerCalls, hasLength(1));

    answer.complete(const RegisterSent());
    await tester.pumpAndSettle();
    expect(find.text(AppText.requestSentTitle), findsOneWidget);
  });

  group('a field\'s error clears when that field is edited', () {
    testWidgets('text fields: gone on edit, back on Send', (tester) async {
      await openRegister(tester);
      await tapVisible(tester, sendButton);
      expect(errorUnder(tester, fullNameField), AppText.enterFullName);
      expect(errorUnder(tester, usernameField), AppText.enterNewUsername);

      await typeInto(tester, fullNameField, 'M');
      await tester.pump();
      expect(errorUnder(tester, fullNameField), isNull);
      // Only the edited field's error goes.
      expect(errorUnder(tester, usernameField), AppText.enterNewUsername);

      await typeInto(tester, fullNameField, '   ');
      await tapVisible(tester, sendButton);
      expect(errorUnder(tester, fullNameField), AppText.enterFullName);
      expect(app.auth.registerCalls, isEmpty);
    });

    testWidgets('the role picker: gone on choosing, back on Send if still '
        'unchosen', (tester) async {
      await openRegister(tester);
      await tapVisible(tester, sendButton);
      expect(find.text(AppText.chooseRole), findsOneWidget);

      await tapVisible(tester, roleOption(Role.buyer));
      expect(find.text(AppText.chooseRole), findsNothing);

      // A fresh form, Send without a role: it comes back.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text(AppText.requestAccountLink));
      await tapVisible(tester, sendButton);
      expect(find.text(AppText.chooseRole), findsOneWidget);
    });

    testWidgets('the passwords: the mismatch goes on editing the confirm '
        'field, back on Send', (tester) async {
      await openRegister(tester);
      await fill(tester, confirm: 'gold river kasempb');
      expect(errorUnder(tester, confirmField), AppText.passwordsDoNotMatch);

      await typeInto(tester, confirmField, 'g');
      await tester.pump();
      expect(errorUnder(tester, confirmField), isNull);

      await typeInto(tester, passwordField, 'gold river kasempa');
      await typeInto(tester, confirmField, 'gold river kasempx');
      await tapVisible(tester, sendButton);
      expect(errorUnder(tester, confirmField), AppText.passwordsDoNotMatch);
      expect(app.auth.registerCalls, isEmpty);
    });

    testWidgets('a half-typed licence: gone on edit, back on Send',
        (tester) async {
      await openRegister(tester);
      await fill(tester, licence: 'zm-as');
      expect(app.auth.registerCalls, isEmpty);
      expect(errorUnder(tester, licenceField), AppText.licenceIncomplete);

      await typeInto(tester, licenceField, 'ZM-ASM-00');
      await tester.pump();
      expect(errorUnder(tester, licenceField), isNull);

      // Still not whole. (A local refusal keeps the passwords: nothing was
      // sent, and they matched.)
      expect(textOf(tester, licenceField), 'ZM-ASM-00');
      await tapVisible(tester, sendButton);
      expect(errorUnder(tester, licenceField), AppText.licenceIncomplete);
      expect(app.auth.registerCalls, isEmpty);
    });

    testWidgets('a server error (USERNAME_TAKEN): gone on edit, back on Send',
        (tester) async {
      await openRegister(
        tester,
        answer: () async =>
            RegisterFailed(refused(ApiCodes.usernameTaken, status: 409)),
      );
      await fill(tester);
      expect(errorUnder(tester, usernameField), AppText.usernameTaken);

      await typeInto(tester, usernameField, 'mutale_banda2');
      await tester.pump();
      expect(errorUnder(tester, usernameField), isNull);

      await typeInto(tester, passwordField, 'gold river kasempa');
      await typeInto(tester, confirmField, 'gold river kasempa');
      await tapVisible(tester, sendButton);
      expect(errorUnder(tester, usernameField), AppText.usernameTaken);
      expect(app.auth.registerCalls, hasLength(2));
    });
  });

  group('the licence field', () {
    testWidgets('formats what is typed as ZM-ABC-1234', (tester) async {
      await openRegister(tester);
      await typeInto(tester, licenceField, 'zm asm 0001');
      await tester.pump();
      expect(textOf(tester, licenceField), 'ZM-ASM-0001');
    });

    testWidgets('shows the example as its hint', (tester) async {
      await openRegister(tester);
      expect(find.text(AppText.licenceNumberHint), findsOneWidget);
    });

    testWidgets('a whole licence is sent as shown', (tester) async {
      await openRegister(tester);
      await fill(tester, licence: 'zmasm0007');
      expect(app.auth.registerCalls.single['licenceNumber'], 'ZM-ASM-0007');
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('the form, with every error showing: $name', (tester) async {
        await openRegister(tester, size: size, textScale: scale);
        await tapVisible(tester, sendButton); // empty: all the errors
        expect(tester.takeException(), isNull);
        for (final finder in [roleOption(Role.buyer), confirmField, sendButton]) {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('the confirmation: $name', (tester) async {
        await openRegister(tester, size: size, textScale: scale);
        await fill(tester);
        expect(find.text(AppText.requestSentTitle), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, AppText.backToLogin),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
