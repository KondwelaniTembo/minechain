// The state behind the administrator's "Accounts" list (admin accounts plan,
// T2): one list per status (Q2: "Active", "Suspended", "Invited",
// "Rejected", "Deleted"), fetched 20 at a time.
//
// Built like AlertsListController, for the same reason: the screen needs
// more than "loading, data or error" (the password prompt, "Show more" while
// the list stays on screen). The actions themselves happen on the account's
// own page (T3, T4); this list is read again when the administrator comes
// back to it, so it never shows a change the server has not made.
//
// Nothing about an account (name, username, reason) is logged; the states'
// toString() print only counts.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart' show AccountStatus;
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_users_repository.dart';
import '../domain/admin_account.dart';

/// The statuses the list shows, in the chips' order. Pending requests are
/// left to "Account requests" (Q5).
const List<AccountStatus> listedStatuses = [
  AccountStatus.active,
  AccountStatus.suspended,
  AccountStatus.invited,
  AccountStatus.rejected,
  AccountStatus.deleted,
];

sealed class AccountsListState {
  const AccountsListState();
}

/// The first page is being fetched; nothing to show yet.
final class AccountsLoading extends AccountsListState {
  const AccountsLoading();
}

/// The token has expired: the password is needed first.
final class AccountsNeedPassword extends AccountsListState {
  const AccountsNeedPassword();
}

/// The first page could not be fetched.
final class AccountsFailed extends AccountsListState {
  const AccountsFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'AccountsFailed($failure)';
}

/// The list, possibly empty.
final class AccountsLoaded extends AccountsListState {
  const AccountsLoaded({
    required this.accounts,
    required this.total,
    this.loadingMore = false,
  });

  /// In the server's order: oldest request or creation first.
  final List<AdminAccount> accounts;

  /// Every account with this status on the server, not only those loaded.
  final int total;

  /// "Show more" is fetching the next page.
  final bool loadingMore;

  bool get hasMore => accounts.length < total;

  @override
  String toString() =>
      'AccountsLoaded(accounts: ${accounts.length}, total: $total, '
      'loadingMore: $loadingMore)';
}

class AccountsListController extends Notifier<AccountsListState> {
  AccountsListController(this.status);

  /// Which of the five lists this is.
  final AccountStatus status;

  bool _refreshing = false;

  AdminUsersRepository get _repository =>
      ref.read(adminUsersRepositoryProvider);

  @override
  AccountsListState build() {
    // The first fetch starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const AccountsLoading();
  }

  /// Fetches the first page again (opening the screen, coming back from an
  /// account, pull-to-refresh, the refresh button, "Try again").
  ///
  /// Returns a failure only when a list was already on screen and stays
  /// there, so the screen can mention it briefly. Without a list, the
  /// failure becomes the state itself.
  Future<AppFailure?> refresh() async {
    if (!ref.mounted) return null;
    final before = state;
    if (_refreshing) return null;
    if (before is AccountsLoaded && before.loadingMore) return null;

    final token = _token();
    if (token == null) {
      state = const AccountsNeedPassword();
      return null;
    }
    if (before is! AccountsLoaded) state = const AccountsLoading();

    _refreshing = true;
    try {
      final page = await _repository.accounts(token: token, status: status);
      if (!ref.mounted) return null;
      state = AccountsLoaded(accounts: page.accounts, total: page.total);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      if (state is AccountsLoaded) return failure;
      state = _token() == null
          ? const AccountsNeedPassword() // TOKEN_EXPIRED on this very fetch
          : AccountsFailed(failure);
      return null;
    } finally {
      _refreshing = false;
    }
  }

  /// Fetches the next page and adds it under the list.
  Future<AppFailure?> loadMore() async {
    final current = state;
    if (current is! AccountsLoaded || current.loadingMore || !current.hasMore) {
      return null;
    }
    if (_refreshing) return null;
    final token = _token();
    if (token == null) {
      state = const AccountsNeedPassword();
      return null;
    }

    state = AccountsLoaded(
      accounts: current.accounts,
      total: current.total,
      loadingMore: true,
    );
    try {
      final page = await _repository.accounts(
        token: token,
        status: status,
        offset: current.accounts.length,
      );
      if (!ref.mounted) return null;
      // If another administrator acted meanwhile, the pages can overlap.
      final known = {for (final a in current.accounts) a.id};
      state = AccountsLoaded(
        accounts: [
          ...current.accounts,
          for (final a in page.accounts)
            if (!known.contains(a.id)) a,
        ],
        total: page.total,
      );
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      state = AccountsLoaded(accounts: current.accounts, total: current.total);
      return failure;
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// One list per status. autoDispose: leaving the screen (or switching to
/// another list) forgets it, so it is always fetched fresh.
final accountsListControllerProvider = NotifierProvider.autoDispose
    .family<AccountsListController, AccountsListState, AccountStatus>(
      AccountsListController.new,
    );
