// The five actions on an account's page (admin accounts plan §4.5, T4):
// suspend, reset device key, reactivate, delete and edit name. Each through
// the real dialog, repository and ApiClient against the fake accounts
// server: the exact body sent, the message, the page after the answer, and
// every refusal keeping the dialog and what was typed.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_accounts_server.dart';
import '../../../fakes/fake_controllers.dart';
import 'account_page_helpers.dart';

Map<String, Object?> bodyOf(http.Request request) => request.body.isEmpty
    ? {}
    : jsonDecode(request.body) as Map<String, Object?>;

/// Taps [label] on the page, then waits for its dialog. The last action's
/// message is cleared first: a snack bar can cover a button near the bottom.
Future<void> startAction(WidgetTester tester, String label) async {
  ScaffoldMessenger.of(tester.element(find.byType(Scaffold).last))
      .removeCurrentSnackBar();
  await tester.pumpAndSettle();
  await tapOnPage(tester, pageButton(label));
}

/// Types [text] into the dialog's field and taps its [button].
Future<void> sendDialog(WidgetTester tester, String text, String button) async {
  await tester.enterText(dialogField, text);
  await tester.pumpAndSettle();
  await tester.tap(dialogButton(button));
  await tester.pumpAndSettle();
}

/// The text now in the dialog's field.
String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(dialogField).controller!.text;

String? fieldErrorText(WidgetTester tester) =>
    tester.widget<TextField>(dialogField).decoration!.errorText;

/// A suspended miner with a key, opened from the "Suspended" list.
Future<void> openSuspended(WidgetTester tester) async {
  server.accounts.add(
    accountJson(
      5,
      fullName: 'Fred Demo',
      status: 'suspended',
      statusReason: 'Phone replaced',
      fingerprint: fakeFingerprint,
    ),
  );
  await openAccount(tester, accountId(5), list: AppText.accountsSuspended);
}

void main() {
  setUp(() => server = FakeAccountsServer());

  group('suspend', () {
    testWidgets('asks with a reason, sends it trimmed, then shows the '
        'suspended account', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);

      expect(inDialog(find.text(AppText.suspendQuestion)), findsOneWidget);
      expect(
        inDialog(find.text(AppText.suspendExplanation('Demo Person 1'))),
        findsOneWidget,
      );
      expect(inDialog(find.text(AppText.rejectReasonWarning)), findsOneWidget);

      await sendDialog(
        tester,
        '  Lost device reported ',
        AppText.suspendAccount,
      );

      expect(bodyOf(server.actions('suspend').single), {
        'reason': 'Lost device reported',
      });
      expect(dialog, findsNothing);
      expect(snack(AppText.suspendedDone('Demo Person 1')), findsOneWidget);
      expect(find.text(AppText.accountIsSuspended), findsOneWidget);
      expect(
        find.text(AppText.reasonLine('Lost device reported')),
        findsOneWidget,
      );
      expect(pageButton(AppText.suspendAccount), findsNothing);
      expect(pageButton(AppText.resetDeviceKey), findsOneWidget);
      expect(pageButton(AppText.reactivateAccount), findsOneWidget);
    });

    testWidgets('a reason under 3 characters is not sent', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await sendDialog(tester, ' ab ', AppText.suspendAccount);

      expect(server.actions('suspend'), isEmpty);
      expect(fieldErrorText(tester), AppText.rejectReasonTooShort);
    });

    testWidgets('typing stops at 500 characters', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await tester.enterText(dialogField, 'x' * 501);
      await tester.pump();
      expect(fieldText(tester).length, 500);
    });

    testWidgets("another administrator acted first: the server's sentence, "
        'the reason kept', (tester) async {
      const message =
          'Only an active account can be suspended. This account is '
          'suspended.';
      server.answers['suspend'] = (_) =>
          refusal(409, ApiCodes.invalidStatusTransition, message);
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await sendDialog(tester, 'Lost device reported', AppText.suspendAccount);

      expect(dialog, findsOneWidget);
      expect(inDialog(find.text(message)), findsOneWidget);
      expect(fieldText(tester), 'Lost device reported');
      // The page is unchanged until the server says otherwise.
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(find.text(AppText.accountIsActive), findsOneWidget);
    });

    testWidgets("the server's reason detail goes under the field", (
      tester,
    ) async {
      server.answers['suspend'] = (_) => http.Response(
        errorAnswer(ApiCodes.validationFailed, 'Some fields are missing.', [
          {'field': 'reason', 'message': 'must be 500 characters or fewer'},
        ]),
        400,
      );
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await sendDialog(tester, 'Lost device reported', AppText.suspendAccount);

      expect(fieldErrorText(tester), 'must be 500 characters or fewer');
    });

    testWidgets('offline: the dialog stays and says so', (tester) async {
      server.answers['suspend'] = (_) => throw const SocketException('test');
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await sendDialog(tester, 'Lost device reported', AppText.suspendAccount);

      expect(inDialog(find.text(AppText.noConnection)), findsOneWidget);
      expect(fieldText(tester), 'Lost device reported');
    });

    testWidgets('a double tap sends once', (tester) async {
      await openAccount(tester, accountId(1));
      server.hold = Completer<void>();

      await startAction(tester, AppText.suspendAccount);
      await tester.enterText(dialogField, 'Lost device reported');
      await tester.pump();
      await tester.tap(dialogButton(AppText.suspendAccount));
      await tester.pump();
      // The button now reads "Sending…" and is off; a second tap is lost.
      expect(inDialog(find.text(AppText.sending)), findsOneWidget);
      await tester.tap(inDialog(find.text(AppText.sending)));
      await tester.pump();

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(server.actions('suspend'), hasLength(1));
      expect(snack(AppText.suspendedDone('Demo Person 1')), findsOneWidget);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.suspendAccount);
      await tester.enterText(dialogField, 'Lost device reported');
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(server.actions('suspend'), isEmpty);
      expect(find.text(AppText.accountIsActive), findsOneWidget);
    });

    testWidgets('token expired on the page: the password first, then the '
        'dialog', (tester) async {
      await openAccount(tester, accountId(1));
      app.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
      await tester.pumpAndSettle();

      await startAction(tester, AppText.suspendAccount);
      expect(find.byType(PasswordPromptDialog), findsOneWidget);
      expect(server.actions('suspend'), isEmpty);

      await tester.enterText(
        find.descendant(
          of: find.byType(PasswordPromptDialog),
          matching: find.byType(TextField),
        ),
        fakePassword,
      );
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.continueLabel),
      );
      expect(inDialog(find.text(AppText.suspendQuestion)), findsOneWidget);
    });
  });

  group('the lost-phone steps: reset the key, then reactivate', () {
    testWidgets('reset key sends the reason and the key is gone', (
      tester,
    ) async {
      await openSuspended(tester);
      expect(find.text(AppText.accountDeviceKey('50a03528')), findsOneWidget);

      await startAction(tester, AppText.resetDeviceKey);
      expect(
        inDialog(find.text(AppText.resetKeyExplanation('Fred Demo'))),
        findsOneWidget,
      );
      await sendDialog(
        tester,
        'Phone replaced, key reset for the demo',
        AppText.resetKey,
      );

      expect(bodyOf(server.actions('reset-key').single), {
        'reason': 'Phone replaced, key reset for the demo',
      });
      expect(snack(AppText.resetKeyDone('Fred Demo')), findsOneWidget);
      expect(find.text(AppText.accountNoDeviceKey), findsOneWidget);
      expect(pageButton(AppText.resetDeviceKey), findsNothing);
      // Still suspended: reactivating is its own step.
      expect(find.text(AppText.accountIsSuspended), findsOneWidget);
    });

    testWidgets('reactivate after the reset says the new phone registers '
        'its key', (tester) async {
      await openSuspended(tester);
      await startAction(tester, AppText.resetDeviceKey);
      await sendDialog(tester, 'Phone replaced', AppText.resetKey);

      await startAction(tester, AppText.reactivateAccount);
      expect(
        inDialog(
          find.text(
            '${AppText.reactivateExplanation('Fred Demo')} '
            '${AppText.reactivateAfterReset}',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(dialogButton(AppText.reactivateAccount));
      await tester.pumpAndSettle();

      final sent = server.actions('reactivate').single;
      expect(sent.body, isEmpty);
      expect(snack(AppText.reactivatedDone('Fred Demo')), findsOneWidget);
      expect(find.text(AppText.accountIsActive), findsOneWidget);
      expect(find.text(AppText.accountNoDeviceKey), findsOneWidget);
    });

    testWidgets('NO_PUBLIC_KEY: its sentence in the dialog', (tester) async {
      server.answers['reset-key'] = (_) => refusal(
        409,
        ApiCodes.noPublicKey,
        'This account has no device key to reset.',
      );
      await openSuspended(tester);
      await startAction(tester, AppText.resetDeviceKey);
      await sendDialog(tester, 'Phone replaced', AppText.resetKey);
      expect(inDialog(find.text(AppText.noDeviceKeyToReset)), findsOneWidget);
    });

    testWidgets('reactivate offline: the account stays suspended', (
      tester,
    ) async {
      server.answers['reactivate'] = (_) => throw const SocketException('test');
      await openSuspended(tester);
      await startAction(tester, AppText.reactivateAccount);
      await tester.tap(dialogButton(AppText.reactivateAccount));
      await tester.pumpAndSettle();
      expect(snack(AppText.noConnection), findsOneWidget);
      expect(find.text(AppText.accountIsSuspended), findsOneWidget);
    });

    testWidgets('reactivate: Cancel sends nothing', (tester) async {
      await openSuspended(tester);
      await startAction(tester, AppText.reactivateAccount);
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(server.actions('reactivate'), isEmpty);
    });
  });

  group('delete (Q4)', () {
    testWidgets('"cannot be undone", a red "Delete for good", then final', (
      tester,
    ) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.deleteAccount);

      expect(
        inDialog(find.text(AppText.deleteExplanation('Demo Person 1'))),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: inDialog(find.text(AppText.deleteForGood)),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        button.style!.backgroundColor!.resolve({}),
        AppTheme.light.colorScheme.error,
      );

      await sendDialog(tester, ' Left the cooperative ', AppText.deleteForGood);

      expect(bodyOf(server.actions('delete').single), {
        'reason': 'Left the cooperative',
      });
      expect(snack(AppText.deletedDone('Demo Person 1')), findsOneWidget);
      expect(find.text(AppText.accountIsDeleted), findsOneWidget);
      expect(find.text(AppText.accountIsFinal), findsOneWidget);
      expect(pageButton(AppText.editName), findsNothing);
      expect(pageButton(AppText.deleteAccount), findsNothing);
    });

    testWidgets("LAST_ACTIVE_ADMIN: the server's sentence", (tester) async {
      const message =
          'At least one other active administrator must remain, so this '
          'account cannot be deleted.';
      server.answers['delete'] = (_) =>
          refusal(409, ApiCodes.lastActiveAdmin, message);
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.deleteAccount);
      await sendDialog(tester, 'Testing the rule', AppText.deleteForGood);
      expect(inDialog(find.text(message)), findsOneWidget);
    });

    testWidgets('429: too many, the reason kept', (tester) async {
      server.answers['delete'] = (_) => refusal(
        429,
        ApiCodes.tooManyRequests,
        'Too many requests. Try again later.',
      );
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.deleteAccount);
      await sendDialog(tester, 'Left the cooperative', AppText.deleteForGood);
      expect(inDialog(find.text(AppText.tooManyTries)), findsOneWidget);
      expect(fieldText(tester), 'Left the cooperative');
    });
  });

  group('edit name', () {
    testWidgets('the name filled in; the new one sent trimmed and shown', (
      tester,
    ) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.editName);

      expect(inDialog(find.text(AppText.editNameExplanation)), findsOneWidget);
      expect(fieldText(tester), 'Demo Person 1');

      await sendDialog(tester, '  Demo Person One ', AppText.save);

      expect(bodyOf(server.actions('rename').single), {
        'fullName': 'Demo Person One',
      });
      expect(snack(AppText.renamedDone('Demo Person One')), findsOneWidget);
      expect(find.text('Demo Person One'), findsWidgets);
    });

    testWidgets('the same name is not sent and says nothing', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.editName);
      await sendDialog(tester, ' Demo Person 1 ', AppText.save);

      expect(server.actions('rename'), isEmpty);
      expect(dialog, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('an empty name is not sent', (tester) async {
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.editName);
      await sendDialog(tester, '   ', AppText.save);

      expect(server.actions('rename'), isEmpty);
      expect(fieldErrorText(tester), AppText.enterAccountFullName);
    });

    testWidgets('429 on rename: the dialog stays with the name', (
      tester,
    ) async {
      server.answers['rename'] = (_) => refusal(
        429,
        ApiCodes.tooManyRequests,
        'Too many requests. Try again later.',
      );
      await openAccount(tester, accountId(1));
      await startAction(tester, AppText.editName);
      await sendDialog(tester, 'Demo Person One', AppText.save);
      expect(inDialog(find.text(AppText.tooManyTries)), findsOneWidget);
      expect(fieldText(tester), 'Demo Person One');
    });

    testWidgets('your own account can be renamed', (tester) async {
      await openAccount(tester, ownId);
      await startAction(tester, AppText.editName);
      await sendDialog(tester, 'Mutale B. Banda', AppText.save);
      expect(bodyOf(server.actions('rename').single), {
        'fullName': 'Mutale B. Banda',
      });
    });
  });

  // Admin accounts T6b: the session ran out while a dialog was open (phone
  // check, 5:22). The password is asked for on top of the dialog, and the
  // same text is sent again; nothing is typed twice.
  group('the session runs out while a dialog is open', () {
    /// The first [action] answers 401 TOKEN_EXPIRED, as the server does
    /// after 60 minutes, and the session moves on as the real controller
    /// would; later ones are answered normally.
    void expireOnce(String action) {
      server.answers[action] = (request) {
        server.answers.remove(action);
        app.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
        return refusal(401, ApiCodes.tokenExpired, 'Token expired.');
      };
    }

    final prompt = find.byType(PasswordPromptDialog);

    /// Taps [finder] and draws the frames up to the password prompt. Not
    /// pumpAndSettle: the dialog's "Sending…" spinner (or the page button's)
    /// keeps turning under the prompt, so the screen never goes still.
    Future<void> tapToPrompt(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> enterPassword(WidgetTester tester) async {
      await tester.enterText(
        find.descendant(of: prompt, matching: find.byType(TextField)),
        fakePassword,
      );
      await tester.tap(
        find.descendant(
          of: prompt,
          matching: find.widgetWithText(FilledButton, AppText.continueLabel),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('edit name: the password, then the same name is sent', (
      tester,
    ) async {
      await openAccount(tester, accountId(1));
      expireOnce('rename');
      await startAction(tester, AppText.editName);
      await tester.enterText(dialogField, 'Demo Person One');
      await tester.pumpAndSettle();
      await tapToPrompt(tester, dialogButton(AppText.save));

      expect(prompt, findsOneWidget);
      await enterPassword(tester);

      final sent = server.actions('rename');
      expect(sent, hasLength(2));
      expect(bodyOf(sent.last), {'fullName': 'Demo Person One'});
      expect(dialog, findsNothing);
      expect(snack(AppText.renamedDone('Demo Person One')), findsOneWidget);
    });

    testWidgets('suspend: Cancel on the password keeps the dialog and the '
        'reason', (tester) async {
      await openAccount(tester, accountId(1));
      expireOnce('suspend');
      await startAction(tester, AppText.suspendAccount);
      await tester.enterText(dialogField, 'Lost device reported');
      await tester.pumpAndSettle();
      await tapToPrompt(tester, dialogButton(AppText.suspendAccount));

      await tester.tap(
        find.descendant(of: prompt, matching: find.text(AppText.cancel)),
      );
      await tester.pumpAndSettle();

      expect(prompt, findsNothing);
      expect(inDialog(find.text(AppText.sessionExpired)), findsOneWidget);
      expect(fieldText(tester), 'Lost device reported');
      expect(server.actions('suspend'), hasLength(1));

      // Pressing again asks for the password again, then suspends.
      await tapToPrompt(tester, dialogButton(AppText.suspendAccount));
      await enterPassword(tester);
      expect(server.actions('suspend'), hasLength(2));
      expect(snack(AppText.suspendedDone('Demo Person 1')), findsOneWidget);
    });

    testWidgets('reactivate: the password, then it is sent again', (
      tester,
    ) async {
      await openSuspended(tester);
      expireOnce('reactivate');
      await startAction(tester, AppText.reactivateAccount);
      await tapToPrompt(tester, dialogButton(AppText.reactivateAccount));

      await enterPassword(tester);
      expect(server.actions('reactivate'), hasLength(2));
      expect(snack(AppText.reactivatedDone('Fred Demo')), findsOneWidget);
      expect(find.text(AppText.accountIsActive), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the delete dialog with an error: $name', (tester) async {
        server.answers['delete'] = (_) => refusal(
          409,
          ApiCodes.lastActiveAdmin,
          'At least one other active administrator must remain, so this '
          'account cannot be deleted.',
        );
        await openAccount(tester, accountId(1), size: size, textScale: scale);
        await startAction(tester, AppText.deleteAccount);
        await sendDialog(tester, 'Left the cooperative', AppText.deleteForGood);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
