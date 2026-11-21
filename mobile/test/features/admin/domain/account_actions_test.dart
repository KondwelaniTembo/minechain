// actionsFor (admin accounts plan §3, T3): exactly the actions each status
// allows, in the page's order, with the two rules the app can see itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/account_actions.dart';
import 'package:minechain/features/admin/domain/admin_account.dart';

import '../../../fakes/fake_accounts_server.dart';

AdminAccount account(String status, {String? fingerprint}) =>
    AdminAccount.fromJson(
      accountJson(1, status: status, fingerprint: fingerprint),
    )!;

void main() {
  test('active: edit name, suspend, delete', () {
    expect(actionsFor(account('active'), own: false), [
      AccountAction.rename,
      AccountAction.suspend,
      AccountAction.delete,
    ]);
  });

  test('your own active account: edit name only', () {
    expect(actionsFor(account('active'), own: true), [AccountAction.rename]);
  });

  test('suspended with a key: edit name, reset key, reactivate, delete', () {
    expect(
      actionsFor(
        account('suspended', fingerprint: fakeFingerprint),
        own: false,
      ),
      [
        AccountAction.rename,
        AccountAction.resetKey,
        AccountAction.reactivate,
        AccountAction.delete,
      ],
    );
  });

  test('suspended without a key: no reset', () {
    expect(actionsFor(account('suspended'), own: false), [
      AccountAction.rename,
      AccountAction.reactivate,
      AccountAction.delete,
    ]);
  });

  test('invited: edit name, new code, delete', () {
    expect(actionsFor(account('invited'), own: false), [
      AccountAction.rename,
      AccountAction.newCode,
      AccountAction.delete,
    ]);
  });

  test('pending (Q5), rejected and deleted: none', () {
    for (final status in ['pending', 'rejected', 'deleted']) {
      expect(actionsFor(account(status), own: false), isEmpty, reason: status);
    }
  });

  test('delete is always last', () {
    for (final status in ['active', 'suspended', 'invited']) {
      final actions = actionsFor(
        account(status, fingerprint: fakeFingerprint),
        own: false,
      );
      expect(actions.last, AccountAction.delete, reason: status);
    }
  });
}
