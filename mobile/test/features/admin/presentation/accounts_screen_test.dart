// The "Accounts" list inside the real app and router, with the fake accounts
// server behind the real repository and ApiClient (admin accounts plan, T2):
// the five lists, every card line, paging, refresh, the failure states, and
// fitting small screens and large text.

import 'dart:io' show HandshakeException, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_accounts_server.dart';
import '../../../fakes/fake_controllers.dart';
import 'account_page_helpers.dart';

/// A text inside the card [id].
Finder inCard(String id, String text) =>
    find.descendant(of: cardOf(id), matching: find.text(text));

void main() {
  setUp(() => server = FakeAccountsServer());

  group('the active list', () {
    testWidgets('cards in the server order, with every line', (tester) async {
      await openAccounts(tester);

      final sent = server.lists.single;
      expect(sent.url.queryParameters, {
        'status': 'active',
        'limit': '20',
        'offset': '0',
      });
      expect(
        find.text(AppText.accountsCount(status: 'active', shown: 4, total: 4)),
        findsOneWidget,
      );

      // The server's order, top to bottom (the first three are built; the
      // list is lazy, so the fourth may not exist until scrolled to).
      final tops = [
        for (final id in [ownId, accountId(1), accountId(2)])
          tester.getTopLeft(cardOf(id)).dy,
      ];
      expect(tops, [...tops]..sort());

      expect(inCard(accountId(1), 'Demo Person 1'), findsOneWidget);
      expect(inCard(accountId(1), 'demo_user_1'), findsOneWidget);
      expect(inCard(accountId(1), AppText.minerTitle), findsOneWidget);
      expect(inCard(accountId(1), 'ZM-ASM-0042'), findsOneWidget);
      expect(inCard(accountId(2), AppText.transporterTitle), findsOneWidget);
    });

    testWidgets('officers and administrators have no licence line', (
      tester,
    ) async {
      await openAccounts(tester);
      // The first card before scrolling: the list is lazy, so a card
      // scrolled far off the top is no longer built.
      expect(inCard(ownId, AppText.adminTitle), findsOneWidget);
      expect(inCard(ownId, AppText.noLicenceNumber), findsNothing);
      await scrollTo(tester, cardOf(accountId(3)), scrollable: listScrollable);
      expect(inCard(accountId(3), AppText.officerTitle), findsOneWidget);
      expect(inCard(accountId(3), AppText.noLicenceNumber), findsNothing);
    });

    testWidgets('a miner without a licence says so', (tester) async {
      server.accounts
        ..clear()
        ..add(accountJson(1, licenceNumber: null));
      await openAccounts(tester);
      expect(inCard(accountId(1), AppText.noLicenceNumber), findsOneWidget);
    });

    testWidgets('one account: "1 active account."', (tester) async {
      server.accounts
        ..clear()
        ..add(accountJson(1));
      await openAccounts(tester);
      expect(find.text('1 active account.'), findsOneWidget);
    });
  });

  group('the five lists (Q2)', () {
    setUp(() {
      server = FakeAccountsServer([
        accountJson(1),
        accountJson(
          2,
          status: 'suspended',
          statusReason: 'Lost device reported',
        ),
        accountJson(
          3,
          role: 'officer',
          status: 'invited',
          licenceNumber: null,
          approvedAt: null,
          activationExpiresAt: '2026-11-24T09:00:00.000Z',
        ),
        accountJson(
          4,
          role: 'officer',
          status: 'invited',
          licenceNumber: null,
          approvedAt: null,
          activationExpiresAt: '2026-11-20T09:00:00.000Z',
        ),
        accountJson(
          5,
          role: 'admin',
          status: 'invited',
          licenceNumber: null,
          approvedAt: null,
        ),
        accountJson(
          6,
          status: 'rejected',
          statusReason: 'Licence number could not be verified',
          approvedAt: null,
        ),
        accountJson(7, status: 'deleted', statusReason: 'Left the cooperative'),
      ]);
    });

    testWidgets('the chips, "Active" chosen first', (tester) async {
      await openAccounts(tester);
      for (final label in [
        AppText.accountsActive,
        AppText.accountsSuspended,
        AppText.accountsInvited,
        AppText.accountsRejected,
        AppText.accountsDeleted,
      ]) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }
      final active = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, AppText.accountsActive),
      );
      expect(active.selected, isTrue);
      expect(cardOf(accountId(1)), findsOneWidget);
      expect(cardOf(accountId(2)), findsNothing);
    });

    testWidgets('"Suspended" asks for that status and shows the reason', (
      tester,
    ) async {
      await openAccounts(tester, list: AppText.accountsSuspended);
      expect(server.lists.last.url.queryParameters['status'], 'suspended');
      expect(
        inCard(accountId(2), AppText.suspendedBecause('Lost device reported')),
        findsOneWidget,
      );
      expect(find.text('1 suspended account.'), findsOneWidget);
    });

    testWidgets('"Invited": a valid code, an expired one, none left', (
      tester,
    ) async {
      await openAccounts(tester, list: AppText.accountsInvited);
      expect(server.lists.last.url.queryParameters['status'], 'invited');
      expect(
        inCard(
          accountId(3),
          AppText.codeValidUntil(DateTime.utc(2026, 11, 24, 9).toLocal()),
        ),
        findsOneWidget,
      );
      expect(inCard(accountId(4), AppText.codeExpired), findsOneWidget);
      await scrollTo(tester, cardOf(accountId(5)), scrollable: listScrollable);
      expect(inCard(accountId(5), AppText.noCodeLeft), findsOneWidget);
    });

    testWidgets('"Rejected" and "Deleted" show their reasons', (tester) async {
      await openAccounts(tester, list: AppText.accountsRejected);
      expect(
        inCard(
          accountId(6),
          AppText.rejectedBecause('Licence number could not be verified'),
        ),
        findsOneWidget,
      );

      await pickList(tester, AppText.accountsDeleted);
      expect(server.lists.last.url.queryParameters['status'], 'deleted');
      expect(
        inCard(accountId(7), AppText.deletedBecause('Left the cooperative')),
        findsOneWidget,
      );
    });

    testWidgets('an empty list says so in its own words', (tester) async {
      server.accounts.removeWhere((a) => a['status'] == 'deleted');
      await openAccounts(tester, list: AppText.accountsDeleted);
      expect(find.text(AppText.noAccounts('deleted')), findsOneWidget);
    });
  });

  group('paging', () {
    setUp(() {
      server = FakeAccountsServer([
        for (var n = 1; n <= 25; n++) accountJson(n),
      ]);
    });

    testWidgets('"Show more" adds the next page', (tester) async {
      await openAccounts(tester);
      expect(
        find.text(
          AppText.accountsCount(status: 'active', shown: 20, total: 25),
        ),
        findsOneWidget,
      );

      await scrollToAndTap(
        tester,
        find.text(AppText.showMore),
        scrollable: listScrollable,
      );

      expect(server.lists.last.url.queryParameters['offset'], '20');
      expect(find.text(AppText.showMore), findsNothing);
      await scrollTo(tester, cardOf(accountId(25)), scrollable: listScrollable);
      expect(cardOf(accountId(25)), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('pulling the list down reads it again', (tester) async {
      await openAccounts(tester);
      server.accounts.add(accountJson(9));

      await tester.fling(
        find.text('Demo Person 1'),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(server.lists, hasLength(2));
      expect(
        find.text(AppText.accountsCount(status: 'active', shown: 5, total: 5)),
        findsOneWidget,
      );
    });

    testWidgets('the refresh button reads it again', (tester) async {
      await openAccounts(tester);
      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();
      expect(server.lists, hasLength(2));
    });

    testWidgets('a failed refresh keeps the list and says why', (tester) async {
      await openAccounts(tester);
      server.answers['list'] = (_) => throw const SocketException('test');
      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();
      expect(cardOf(accountId(1)), findsOneWidget);
      expect(snack(AppText.noConnection), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('offline: the sentence and "Try again"', (tester) async {
      server.answers['list'] = (_) => throw const SocketException('test');
      await openAccounts(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.answers.remove('list');
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );
      expect(cardOf(accountId(1)), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      server.answers['list'] = (_) => throw const HandshakeException('test');
      await openAccounts(tester);
      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('an odd answer', (tester) async {
      server.answers['list'] = (_) => json200({'users': 'none'});
      await openAccounts(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('token expired: the password first, then the list', (
      tester,
    ) async {
      await openAccounts(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.admin)),
      );
      expect(find.text(AppText.accountsNeedPassword), findsOneWidget);
      expect(server.received, isEmpty);

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
      );
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
      expect(cardOf(accountId(1)), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the active list: $name', (tester) async {
        await openAccounts(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          cardOf(accountId(3)),
          scrollable: listScrollable,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('a long name and reason: $name', (tester) async {
        server.accounts.add(
          accountJson(
            9,
            status: 'suspended',
            fullName: 'A Person With A Rather Long Full Name For The Card',
            statusReason:
                'Lost device reported at the weighing station on Tuesday',
          ),
        );
        await openAccounts(
          tester,
          list: AppText.accountsSuspended,
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          find.text(
            AppText.suspendedBecause(
              'Lost device reported at the weighing station on Tuesday',
            ),
          ),
          scrollable: listScrollable,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('the empty state: $name', (tester) async {
        server.accounts.clear();
        await openAccounts(tester, size: size, textScale: scale);
        expect(find.text(AppText.noAccounts('active')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
