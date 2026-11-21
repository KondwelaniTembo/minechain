// Which actions the account page offers (admin accounts plan §3, T3): the
// server's table of "from which status", plus the two rules the app can see
// for itself (your own account; a key to reset). The app hides what the
// server would refuse; if it refuses anyway (another administrator acted
// first, the last active administrator), its sentence is shown.
//
// Plain Dart, no Flutter.

import '../../auth/domain/user.dart' show AccountStatus;
import 'admin_account.dart';

enum AccountAction { rename, suspend, resetKey, reactivate, newCode, delete }

/// The actions for [account], in the page's order (delete always last).
/// [own] is true when it is the signed-in administrator's own account:
/// api.md refuses suspending or deleting yourself (403).
List<AccountAction> actionsFor(AdminAccount account, {required bool own}) =>
    switch (account.status) {
      AccountStatus.active => [
        AccountAction.rename,
        if (!own) AccountAction.suspend,
        if (!own) AccountAction.delete,
      ],
      // The lost-phone order: reset the key first, then reactivate.
      AccountStatus.suspended => [
        AccountAction.rename,
        if (account.hasDeviceKey) AccountAction.resetKey,
        AccountAction.reactivate,
        if (!own) AccountAction.delete,
      ],
      AccountStatus.invited => [
        AccountAction.rename,
        AccountAction.newCode,
        AccountAction.delete,
      ],
      // Q5: a pending request is dealt with on "Account requests".
      AccountStatus.pending => const [],
      // Final: nothing leads out of either (api.md).
      AccountStatus.rejected || AccountStatus.deleted => const [],
    };
