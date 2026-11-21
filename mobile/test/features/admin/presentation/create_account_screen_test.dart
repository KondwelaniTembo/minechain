// "Create account" and the activation code, shown once (admin accounts plan
// §4.3–4.4, T5), inside the real app and router against the fake accounts
// server; and "New activation code" on an invited account's page.

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/accounts_screen.dart';
import 'package:minechain/features/admin/presentation/create_account_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_accounts_server.dart';
import '../../../fakes/fake_controllers.dart';
import 'account_page_helpers.dart';

Finder field(String label) => find.widgetWithText(TextField, label);

Finder get formScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('create-account-page')),
      matching: find.byType(Scrollable),
    )
    .first;

/// Opens "Create account" from the list's floating button.
Future<void> openCreate(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await openAccounts(tester, size: size, textScale: textScale);
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
}

Future<void> fillForm(
  WidgetTester tester, {
  String fullName = 'Chanda Mwale',
  String username = 'chanda_mwale',
  String? role = AppText.officerTitle,
}) async {
  await typeInto(tester, field(AppText.fullName), fullName);
  await typeInto(tester, field(AppText.username), username);
  if (role != null) await tapVisible(tester, find.text(role));
}

Future<void> tapCreate(WidgetTester tester) => tapVisible(
  tester,
  find.descendant(
    of: find.byType(CreateAccountScreen),
    matching: find.widgetWithText(FilledButton, AppText.createAccount),
  ),
);

String? errorUnder(WidgetTester tester, String label) =>
    tester.widget<TextField>(field(label)).decoration!.errorText;

Map<String, Object?> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, Object?>;

final codeExpiry = DateTime.utc(2026, 11, 24, 9).toLocal();

void main() {
  setUp(() => server = FakeAccountsServer());

  group('the form', () {
    testWidgets('opens from the floating button, with no role chosen', (
      tester,
    ) async {
      await openCreate(tester);
      expect(find.byType(CreateAccountScreen), findsOneWidget);
      expect(find.text(AppText.createAccountIntro), findsOneWidget);
      expect(find.text(AppText.officerTitle), findsOneWidget);
      expect(find.text(AppText.adminTitle), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('nothing filled in: a sentence under each, nothing sent', (
      tester,
    ) async {
      await openCreate(tester);
      await tapCreate(tester);

      expect(server.creates, isEmpty);
      expect(
        errorUnder(tester, AppText.fullName),
        AppText.enterAccountFullName,
      );
      expect(
        errorUnder(tester, AppText.username),
        AppText.enterAccountUsername,
      );
      expect(find.text(AppText.chooseNewAccountRole), findsOneWidget);
    });

    testWidgets('no role chosen: nothing sent', (tester) async {
      await openCreate(tester);
      await fillForm(tester, role: null);
      await tapCreate(tester);
      expect(server.creates, isEmpty);
      expect(find.text(AppText.chooseNewAccountRole), findsOneWidget);
    });

    testWidgets('a taken username: under the field', (tester) async {
      await openCreate(tester);
      await fillForm(tester, username: 'DEMO_USER_1');
      await tapCreate(tester);

      expect(errorUnder(tester, AppText.username), AppText.usernameTaken);
      expect(find.byKey(const ValueKey('activation-code')), findsNothing);
    });

    testWidgets("the server's username rule goes under the field", (
      tester,
    ) async {
      server.answers['create'] = (_) => http.Response(
        errorAnswer(ApiCodes.validationFailed, 'Some fields are missing.', [
          {'field': 'username', 'message': 'must be at least 3 characters'},
        ]),
        400,
      );
      await openCreate(tester);
      await fillForm(tester, username: 'ab');
      await tapCreate(tester);

      expect(
        errorUnder(tester, AppText.username),
        'must be at least 3 characters',
      );
      expect(find.text(AppText.checkTheForm), findsNothing);
    });

    testWidgets('offline: the sentence under the form, nothing lost', (
      tester,
    ) async {
      server.answers['create'] = (_) => throw const SocketException('test');
      await openCreate(tester);
      await fillForm(tester);
      await tapCreate(tester);

      expect(find.text(AppText.noConnection), findsOneWidget);
      expect(
        tester.widget<TextField>(field(AppText.username)).controller!.text,
        'chanda_mwale',
      );
    });
  });

  group('created: the code, shown once', () {
    testWidgets('sends exactly username, fullName and role, then shows the '
        'code', (tester) async {
      await openCreate(tester);
      await fillForm(
        tester,
        fullName: ' Chanda Mwale ',
        username: ' chanda_mwale ',
      );
      await tapCreate(tester);

      expect(bodyOf(server.creates.single), {
        'username': 'chanda_mwale',
        'fullName': 'Chanda Mwale',
        'role': 'officer',
      });
      expect(find.text(AppText.activationCodeTitle), findsOneWidget);
      expect(find.text('7KQ4-M2XD-9TNE'), findsOneWidget);
      expect(
        find.text(AppText.activationCodeFor('chanda_mwale')),
        findsOneWidget,
      );
      expect(find.text(AppText.codeValidFor(codeExpiry)), findsOneWidget);
      expect(find.text(AppText.codeShownOnce('Chanda Mwale')), findsOneWidget);
      // Q3: plain text, nothing to select or copy.
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('an administrator account', (tester) async {
      await openCreate(tester);
      await fillForm(tester, role: AppText.adminTitle);
      await tapCreate(tester);
      expect(bodyOf(server.creates.single)['role'], 'admin');
    });

    testWidgets('"Done": back to the list, now on "Invited", with the new '
        'account', (tester) async {
      await openCreate(tester);
      await fillForm(tester);
      await tapCreate(tester);
      await tapVisible(tester, find.text(AppText.codeDone));

      expect(find.byType(AccountsScreen), findsOneWidget);
      final invited = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, AppText.accountsInvited),
      );
      expect(invited.selected, isTrue);
      expect(server.lists.last.url.queryParameters['status'], 'invited');
      expect(find.text('chanda_mwale'), findsOneWidget);
      expect(find.text(AppText.codeValidUntil(codeExpiry)), findsOneWidget);
    });

    testWidgets('Android back asks first; "Stay" keeps the code', (
      tester,
    ) async {
      await openCreate(tester);
      await fillForm(tester);
      await tapCreate(tester);

      await pressAndroidBack(tester);
      expect(find.text(AppText.leaveWithoutCodeQuestion), findsOneWidget);
      await tester.tap(find.text(AppText.stayOnCode));
      await tester.pumpAndSettle();
      expect(find.text('7KQ4-M2XD-9TNE'), findsOneWidget);

      await pressAndroidBack(tester);
      await tester.tap(find.text(AppText.leaveCode));
      await tester.pumpAndSettle();
      expect(find.byType(AccountsScreen), findsOneWidget);
      expect(find.text('7KQ4-M2XD-9TNE'), findsNothing);
    });

    testWidgets('the back arrow asks too', (tester) async {
      await openCreate(tester);
      await fillForm(tester);
      await tapCreate(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(AppText.leaveWithoutCodeQuestion), findsOneWidget);
    });

    testWidgets('the session running out does not hide the code', (
      tester,
    ) async {
      await openCreate(tester);
      await fillForm(tester);
      await tapCreate(tester);
      app.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
      await tester.pumpAndSettle();
      expect(find.text('7KQ4-M2XD-9TNE'), findsOneWidget);
    });

    testWidgets('the code is in no log line', (tester) async {
      final lines = <String>[];
      final before = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      // Put back inside the test: the framework checks it is unchanged
      // before any tear-down runs.
      try {
        await openCreate(tester);
        await fillForm(tester);
        await tapCreate(tester);
        await tapVisible(tester, find.text(AppText.codeDone));
      } finally {
        debugPrint = before;
      }

      expect(lines.where((l) => l.contains('7KQ4')), isEmpty);
    });
  });

  group('"New activation code" on an invited account', () {
    setUp(() {
      server.accounts.add(
        accountJson(
          5,
          fullName: 'Chanda Mwale',
          username: 'chanda_mwale',
          role: 'officer',
          status: 'invited',
          licenceNumber: null,
          approvedAt: null,
          activationExpiresAt: '2026-11-20T09:00:00.000Z',
        ),
      );
    });

    testWidgets('asks first, then shows the new code; "Done" returns to '
        'the account', (tester) async {
      await openAccount(tester, accountId(5), list: AppText.accountsInvited);
      expect(find.text(AppText.codeExpired), findsOneWidget);

      await tapOnPage(tester, pageButton(AppText.newActivationCode));
      expect(find.text(AppText.newCodeExplanation), findsOneWidget);
      await tester.tap(dialogButton(AppText.giveNewCode));
      await tester.pumpAndSettle();

      final sent = server.actions('activation-code').single;
      expect(sent.body, isEmpty);
      expect(find.text('7KQ4-M2XD-9TNE'), findsOneWidget);
      expect(find.text(AppText.codeShownOnce('Chanda Mwale')), findsOneWidget);

      await tapVisible(tester, find.text(AppText.codeDone));
      expect(find.text('7KQ4-M2XD-9TNE'), findsNothing);
      // The account from the answer: its code is valid again.
      expect(find.text(AppText.codeValidUntil(codeExpiry)), findsOneWidget);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await openAccount(tester, accountId(5), list: AppText.accountsInvited);
      await tapOnPage(tester, pageButton(AppText.newActivationCode));
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(server.actions('activation-code'), isEmpty);
    });

    testWidgets('Android back on the code asks; "Leave" returns to the '
        'account', (tester) async {
      await openAccount(tester, accountId(5), list: AppText.accountsInvited);
      await tapOnPage(tester, pageButton(AppText.newActivationCode));
      await tester.tap(dialogButton(AppText.giveNewCode));
      await tester.pumpAndSettle();

      await pressAndroidBack(tester);
      expect(find.text(AppText.leaveWithoutCodeQuestion), findsOneWidget);
      await tester.tap(find.text(AppText.leaveCode));
      await tester.pumpAndSettle();
      expect(find.text('7KQ4-M2XD-9TNE'), findsNothing);
      expect(find.text(AppText.accountIsInvited), findsOneWidget);
    });

    testWidgets('a second code is a different one', (tester) async {
      await openAccount(tester, accountId(5), list: AppText.accountsInvited);
      for (var i = 0; i < 2; i++) {
        await tapOnPage(tester, pageButton(AppText.newActivationCode));
        await tester.tap(dialogButton(AppText.giveNewCode));
        await tester.pumpAndSettle();
        await tapVisible(tester, find.text(AppText.codeDone));
      }
      expect(server.codesIssued, 2);
      expect(server.actions('activation-code'), hasLength(2));
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the form with errors: $name', (tester) async {
        await openCreate(tester, size: size, textScale: scale);
        await tapCreate(tester);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          find.text(AppText.chooseNewAccountRole),
          scrollable: formScrollable,
        );
        expect(tester.takeException(), isNull);
      });

      // T6b: on one line, inside its card, at every size (on the emulator
      // it broke after the first dash).
      testWidgets('the code on one line: $name', (tester) async {
        await openCreate(tester, size: size, textScale: scale);
        await fillForm(tester);
        await tapCreate(tester);

        final code = find.byKey(const ValueKey('activation-code'));
        expect(tester.widget<Text>(code).maxLines, 1);
        final card = find.ancestor(of: code, matching: find.byType(Card));
        final codeRect = tester.getRect(code);
        final cardRect = tester.getRect(card);
        expect(codeRect.left, greaterThanOrEqualTo(cardRect.left));
        expect(codeRect.right, lessThanOrEqualTo(cardRect.right));
        // One line: no taller than the style's own line height allows.
        final style = tester.widget<Text>(code).style!;
        expect(codeRect.height, lessThan(style.fontSize! * scale * 2));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the code: $name', (tester) async {
        await openCreate(tester, size: size, textScale: scale);
        await fillForm(tester);
        await tapCreate(tester);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          find.text(AppText.codeDone),
          scrollable: formScrollable,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
