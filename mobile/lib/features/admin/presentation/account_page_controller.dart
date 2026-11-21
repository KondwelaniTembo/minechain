// The state behind one account's page (admin accounts plan, T3–T5): the
// account, the action running now, and a new activation code to show once.
//
// The page starts from the row the list gave it: there is no
// GET /admin/users/{id}. Every action answers with the account's new admin
// view, which replaces it, so the page always shows what the server last
// said. CONFIRMED updates, as on "Account requests": nothing changes on
// screen until the server has answered 200.
//
// One action at a time: while one runs, every button is off and a second
// call is ignored, so a double tap sends once.
//
// Nothing about the account is logged, and the activation code is held only
// here, in memory, until the administrator leaves the code view.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/field_errors.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_users_repository.dart';
import '../domain/account_actions.dart';
import '../domain/admin_account.dart';

class AccountPageState {
  const AccountPageState({required this.account, this.busy, this.code});

  /// The account as the server last gave it.
  final AdminAccount account;

  /// The action on its way, or null.
  final AccountAction? busy;

  /// A new activation code to show once (T5), or null.
  final ActivationCode? code;

  /// [busy] and [code] are cleared unless given: each new state says afresh
  /// what is running and what is shown.
  AccountPageState copyWith({
    AdminAccount? account,
    AccountAction? busy,
    ActivationCode? code,
  }) => AccountPageState(
    account: account ?? this.account,
    busy: busy,
    code: code,
  );

  @override
  String toString() =>
      'AccountPageState($account, busy: ${busy?.name}, code: ${code != null})';
}

// ---- What an action came to --------------------------------------------------

sealed class AccountActionOutcome {
  const AccountActionOutcome();
}

/// The server accepted it; the page shows [account] now.
final class AccountActionDone extends AccountActionOutcome {
  const AccountActionDone(this.account);
  final AdminAccount account;

  @override
  String toString() => 'AccountActionDone($account)';
}

/// Refused or not sent. [fieldErrors] holds the server's per-field messages
/// (`reason`, `fullName`), keyed by the API's field names.
final class AccountActionFailed extends AccountActionOutcome {
  const AccountActionFailed(this.failure, [this.fieldErrors = const {}]);
  final AppFailure failure;
  final Map<String, String> fieldErrors;

  @override
  String toString() => 'AccountActionFailed($failure)';
}

/// The token has expired: ask for the password, then try again.
final class AccountActionNeedsPassword extends AccountActionOutcome {
  const AccountActionNeedsPassword();
}

/// Another action is running; nothing was sent.
final class AccountActionIgnored extends AccountActionOutcome {
  const AccountActionIgnored();
}

// ---- The controller ---------------------------------------------------------

class AccountPageController extends Notifier<AccountPageState> {
  AccountPageController(this.initial);

  /// The row the list gave the page.
  final AdminAccount initial;

  AdminUsersRepository get _repository =>
      ref.read(adminUsersRepositoryProvider);

  @override
  AccountPageState build() => AccountPageState(account: initial);

  String get _id => state.account.id;

  Future<AccountActionOutcome> rename(String fullName) => _act(
    AccountAction.rename,
    (token) => _repository.rename(token: token, id: _id, fullName: fullName),
  );

  Future<AccountActionOutcome> suspend(String reason) => _act(
    AccountAction.suspend,
    (token) => _repository.suspend(token: token, id: _id, reason: reason),
  );

  Future<AccountActionOutcome> reactivate() => _act(
    AccountAction.reactivate,
    (token) => _repository.reactivate(token: token, id: _id),
  );

  Future<AccountActionOutcome> resetKey(String reason) => _act(
    AccountAction.resetKey,
    (token) => _repository.resetKey(token: token, id: _id, reason: reason),
  );

  Future<AccountActionOutcome> delete(String reason) => _act(
    AccountAction.delete,
    (token) => _repository.delete(token: token, id: _id, reason: reason),
  );

  /// A new activation code. On success the page shows it (state.code) until
  /// [codeSeen].
  Future<AccountActionOutcome> newCode() async {
    ActivationCode? code;
    final outcome = await _act(AccountAction.newCode, (token) async {
      final invited = await _repository.newActivationCode(
        token: token,
        id: _id,
      );
      code = invited.activation;
      return invited.account;
    });
    if (outcome is AccountActionDone && ref.mounted) {
      state = state.copyWith(code: code);
    }
    return outcome;
  }

  /// The administrator has left the code view: the code is forgotten.
  void codeSeen() {
    if (state.code != null) state = state.copyWith(busy: state.busy);
  }

  Future<AccountActionOutcome> _act(
    AccountAction action,
    Future<AdminAccount> Function(String token) send,
  ) async {
    if (state.busy != null) return const AccountActionIgnored();
    final token = _token();
    if (token == null) return const AccountActionNeedsPassword();

    state = state.copyWith(busy: action);
    try {
      final account = await send(token);
      if (!ref.mounted) return AccountActionDone(account);
      state = AccountPageState(account: account);
      return AccountActionDone(account);
    } on AppFailure catch (failure) {
      if (ref.mounted) state = state.copyWith();
      // TOKEN_EXPIRED counts too, before the auth controller has caught up:
      // it hears of the refusal a moment later (T6b, phone check 5:22).
      final expired =
          failure is ServerRefused && failure.code == ApiCodes.tokenExpired;
      if (expired || _token() == null) {
        return const AccountActionNeedsPassword();
      }
      return AccountActionFailed(
        failure,
        failure is ServerRefused ? fieldErrorsFrom(failure.details) : const {},
      );
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// One page per account row. autoDispose: leaving the page forgets it, and
/// any code with it.
final accountPageControllerProvider = NotifierProvider.autoDispose
    .family<AccountPageController, AccountPageState, AdminAccount>(
      AccountPageController.new,
    );

/// The account the list opened last, for its page.
///
/// Why not the route's `extra`: when the 60-minute token runs out on the
/// page (SignedIn → SignedInNeedsPassword), the router re-runs its redirect
/// and rebuilds the page without the `extra`, so the account was lost (found
/// by the T4 test "token expired on the page"). A provider outlives that
/// rebuild. It is still lost when Android closes the app, a known
/// limitation: there is no GET /admin/users/{id} to read it again.
class OpenedAccount extends Notifier<AdminAccount?> {
  @override
  AdminAccount? build() => null;

  void open(AdminAccount account) => state = account;
}

final openedAccountProvider = NotifierProvider<OpenedAccount, AdminAccount?>(
  OpenedAccount.new,
);
