// One account's page inside the real app and router, opened from its card
// (admin accounts plan, T3): every line for each status, exactly the
// buttons the status allows, your own account, the device key line, the
// page opened without an account, and fitting small screens and large text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/accounts_screen.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_accounts_server.dart';
import 'account_page_helpers.dart';

/// Every action button's words, to check that only the expected ones show.
const allButtons = [
  AppText.editName,
  AppText.suspendAccount,
  AppText.resetDeviceKey,
  AppText.reactivateAccount,
  AppText.newActivationCode,
  AppText.deleteAccount,
];

/// Exactly [expected] of the action buttons are on the page.
void expectButtons(List<String> expected) {
  for (final label in allButtons) {
    expect(
      pageButton(label),
      expected.contains(label) ? findsOneWidget : findsNothing,
      reason: label,
    );
  }
}

void main() {
  setUp(() => server = FakeAccountsServer());

  group('an active miner with a device key', () {
    testWidgets('every line', (tester) async {
      await openAccount(tester, accountId(1));

      expect(find.text(AppText.accountTitle), findsOneWidget);
      expect(find.text('Demo Person 1'), findsOneWidget);
      expect(find.text('demo_user_1'), findsOneWidget);
      expect(find.text(AppText.minerTitle), findsOneWidget);
      expect(find.text(AppText.accountIsActive), findsOneWidget);
      expect(find.text('ZM-ASM-0042'), findsOneWidget);
      expect(
        find.text(AppText.requestedOn(DateTime.utc(2026, 11, 5, 9).toLocal())),
        findsOneWidget,
      );
      expect(
        find.text(
          AppText.approvedOn(DateTime.utc(2026, 11, 6, 10, 15).toLocal()),
        ),
        findsOneWidget,
      );
      // The same eight characters the person's "My account" shows.
      expect(find.text(AppText.accountDeviceKey('50a03528')), findsOneWidget);
      expect(find.text(AppText.lostPhoneHint), findsOneWidget);
    });

    testWidgets('edit name, suspend and delete, delete last', (tester) async {
      await openAccount(tester, accountId(1));
      await scrollTo(
        tester,
        pageButton(AppText.deleteAccount),
        scrollable: pageScrollable,
      );
      expectButtons([
        AppText.editName,
        AppText.suspendAccount,
        AppText.deleteAccount,
      ]);
      expect(
        tester.getTopLeft(pageButton(AppText.suspendAccount)).dy,
        lessThan(tester.getTopLeft(pageButton(AppText.deleteAccount)).dy),
      );
    });
  });

  testWidgets('a transporter with no key: "none registered", no lost-phone '
      'line', (tester) async {
    await openAccount(tester, accountId(2));
    expect(find.text(AppText.accountNoDeviceKey), findsOneWidget);
    expect(find.text(AppText.lostPhoneHint), findsNothing);
  });

  testWidgets('an officer: no licence and no device key line, "Created"', (
    tester,
  ) async {
    server.accounts[3] = accountJson(
      3,
      role: 'officer',
      licenceNumber: null,
      approvedAt: null,
    );
    await openAccount(tester, accountId(3));
    expect(find.text(AppText.officerTitle), findsOneWidget);
    expect(find.text(AppText.noLicenceNumber), findsNothing);
    expect(find.text(AppText.accountNoDeviceKey), findsNothing);
    expect(find.textContaining('Device key'), findsNothing);
    expect(
      find.text(AppText.createdOn(DateTime.utc(2026, 11, 5, 9).toLocal())),
      findsOneWidget,
    );
    expect(find.textContaining('Approved'), findsNothing);
  });

  testWidgets('your own account: no Suspend or Delete, and it says why', (
    tester,
  ) async {
    await openAccount(tester, ownId);
    expect(find.text(AppText.yourOwnAccount), findsOneWidget);
    expectButtons([AppText.editName]);
  });

  group('a suspended account', () {
    testWidgets('with a key: the reason, reset, reactivate, delete', (
      tester,
    ) async {
      server.accounts.add(
        accountJson(
          5,
          status: 'suspended',
          statusReason: 'Lost device reported',
          fingerprint: fakeFingerprint,
        ),
      );
      await openAccount(tester, accountId(5), list: AppText.accountsSuspended);
      expect(find.text(AppText.accountIsSuspended), findsOneWidget);
      expect(
        find.text(AppText.reasonLine('Lost device reported')),
        findsOneWidget,
      );
      await scrollTo(
        tester,
        pageButton(AppText.deleteAccount),
        scrollable: pageScrollable,
      );
      expectButtons([
        AppText.editName,
        AppText.resetDeviceKey,
        AppText.reactivateAccount,
        AppText.deleteAccount,
      ]);
      // The lost-phone order: reset before reactivate.
      expect(
        tester.getTopLeft(pageButton(AppText.resetDeviceKey)).dy,
        lessThan(tester.getTopLeft(pageButton(AppText.reactivateAccount)).dy),
      );
    });

    testWidgets('without a key: no reset', (tester) async {
      server.accounts.add(accountJson(5, status: 'suspended'));
      await openAccount(tester, accountId(5), list: AppText.accountsSuspended);
      await scrollTo(
        tester,
        pageButton(AppText.deleteAccount),
        scrollable: pageScrollable,
      );
      expectButtons([
        AppText.editName,
        AppText.reactivateAccount,
        AppText.deleteAccount,
      ]);
    });
  });

  testWidgets('an invited officer: the code line, new code, delete', (
    tester,
  ) async {
    server.accounts.add(
      accountJson(
        5,
        role: 'officer',
        status: 'invited',
        licenceNumber: null,
        approvedAt: null,
        activationExpiresAt: '2026-11-24T09:00:00.000Z',
      ),
    );
    await openAccount(tester, accountId(5), list: AppText.accountsInvited);
    expect(find.text(AppText.accountIsInvited), findsOneWidget);
    expect(
      find.text(
        AppText.codeValidUntil(DateTime.utc(2026, 11, 24, 9).toLocal()),
      ),
      findsOneWidget,
    );
    await scrollTo(
      tester,
      pageButton(AppText.deleteAccount),
      scrollable: pageScrollable,
    );
    expectButtons([
      AppText.editName,
      AppText.newActivationCode,
      AppText.deleteAccount,
    ]);
  });

  for (final (status, chip, sentence) in [
    ('rejected', AppText.accountsRejected, AppText.accountIsRejected),
    ('deleted', AppText.accountsDeleted, AppText.accountIsDeleted),
  ]) {
    testWidgets('a $status account is final: no buttons', (tester) async {
      server.accounts.add(
        accountJson(5, status: status, statusReason: 'Left the cooperative'),
      );
      await openAccount(tester, accountId(5), list: chip);
      expect(find.text(sentence), findsOneWidget);
      expect(
        find.text(AppText.reasonLine('Left the cooperative')),
        findsOneWidget,
      );
      expect(find.text(AppText.accountIsFinal), findsOneWidget);
      expectButtons(const []);
    });
  }

  testWidgets('back returns to the list, which is read again', (tester) async {
    await openAccount(tester, accountId(1));
    expect(server.lists, hasLength(1));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsScreen), findsOneWidget);
    expect(server.lists, hasLength(2));
  });

  testWidgets('Android back returns to the list too', (tester) async {
    await openAccount(tester, accountId(1));
    await pressAndroidBack(tester);
    expect(find.byType(AccountsScreen), findsOneWidget);
  });

  testWidgets('opened without an account: it says so and offers the list', (
    tester,
  ) async {
    await openAccounts(tester);
    app.container.read(appRouterProvider).go(AppRoutes.adminAccount);
    await tester.pumpAndSettle();

    expect(find.text(AppText.accountPageGone), findsOneWidget);
    await tester.tap(find.text(AppText.backToAccounts));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsScreen), findsOneWidget);
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('a suspended account with a long reason: $name', (
        tester,
      ) async {
        server.accounts.add(
          accountJson(
            5,
            status: 'suspended',
            fullName: 'A Person With A Rather Long Full Name For The Page',
            statusReason:
                'Lost device reported at the weighing station on Tuesday',
            fingerprint: fakeFingerprint,
          ),
        );
        await openAccount(
          tester,
          accountId(5),
          list: AppText.accountsSuspended,
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          pageButton(AppText.deleteAccount),
          scrollable: pageScrollable,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
