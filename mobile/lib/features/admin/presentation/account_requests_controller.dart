// The state behind the "Account requests" screen (plan A1): the pending list,
// and approving or rejecting one request at a time.
//
// Why a plain Notifier with its own sealed states, not an AsyncNotifier: the
// screen needs more than "loading, data or error". It also needs "your
// session expired, enter your password", "this row is being approved", and
// "loading more", while the list stays on screen. Spelling those out as types
// makes every case visible to the compiler and to the tests.
//
// CONFIRMED updates, not optimistic ones: a row leaves the list only after
// the server has answered 200. Approving gives someone access to the system,
// so the screen must never show "done" for something the server refused.
//
// Nothing about a request (name, username, licence) is logged; the states'
// toString() print only counts.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/field_errors.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_users_repository.dart';
import '../domain/account_request.dart';

// ---- The screen's states -------------------------------------------------

sealed class RequestsState {
  const RequestsState();
}

/// The first page is being fetched; nothing to show yet.
final class RequestsLoading extends RequestsState {
  const RequestsLoading();
}

/// The token has expired (decision Q2): the password is needed first.
final class RequestsNeedPassword extends RequestsState {
  const RequestsNeedPassword();
}

/// The first page could not be fetched.
final class RequestsFailed extends RequestsState {
  const RequestsFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'RequestsFailed($failure)';
}

/// The list, possibly empty.
final class RequestsLoaded extends RequestsState {
  const RequestsLoaded({
    required this.requests,
    required this.total,
    this.busyId,
    this.loadingMore = false,
  });

  final List<AccountRequest> requests;

  /// Every pending request on the server, not only those loaded.
  final int total;

  /// The request being approved or rejected right now, or null. Only one at
  /// a time, so every other row's buttons are disabled meanwhile.
  final String? busyId;

  /// "Show more" is fetching the next page.
  final bool loadingMore;

  bool get hasMore => requests.length < total;
  bool get busy => busyId != null || loadingMore;

  @override
  String toString() =>
      'RequestsLoaded(requests: ${requests.length}, total: $total, '
      'busy: ${busyId != null}, loadingMore: $loadingMore)';
}

// ---- What an approve or reject came to ------------------------------------

sealed class RequestAction {
  const RequestAction();
}

/// The server accepted it; the row has left the list.
final class RequestActionDone extends RequestAction {
  const RequestActionDone();
}

/// 404 or 409: another administrator dealt with it (or the account changed)
/// first. The list has been fetched again.
final class RequestAlreadyHandled extends RequestAction {
  const RequestAlreadyHandled();
}

/// Refused or not sent. [fieldErrors] holds the server's per-field messages
/// (for example under `reason`), keyed by the API's field names.
final class RequestActionFailed extends RequestAction {
  const RequestActionFailed(this.failure, [this.fieldErrors = const {}]);
  final AppFailure failure;
  final Map<String, String> fieldErrors;

  @override
  String toString() => 'RequestActionFailed($failure)';
}

/// The token has expired: ask for the password, then try again.
final class RequestNeedsPassword extends RequestAction {
  const RequestNeedsPassword();
}

/// Something else is running (another row, a refresh); nothing was sent.
final class RequestActionIgnored extends RequestAction {
  const RequestActionIgnored();
}

// ---- The controller ------------------------------------------------------

class AccountRequestsController extends Notifier<RequestsState> {
  bool _refreshing = false;

  AdminUsersRepository get _repository =>
      ref.read(adminUsersRepositoryProvider);

  @override
  RequestsState build() {
    // The first fetch starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const RequestsLoading();
  }

  /// Fetches the first page again (pull-to-refresh, the refresh button,
  /// "Try again").
  ///
  /// Returns a failure only when a list was already on screen and stays
  /// there, so the screen can mention it briefly. Without a list, the failure
  /// becomes the state itself.
  Future<AppFailure?> refresh() async {
    // The first call comes from build's microtask; the screen may already
    // have been closed by then, and a disposed notifier has no state.
    if (!ref.mounted) return null;
    final before = state;
    if (_refreshing) return null;
    if (before is RequestsLoaded && before.busy) return null;

    final token = _token();
    if (token == null) {
      state = const RequestsNeedPassword();
      return null;
    }
    if (before is! RequestsLoaded) state = const RequestsLoading();

    _refreshing = true;
    try {
      final page = await _repository.pendingRequests(token: token);
      if (!ref.mounted) return null;
      state = RequestsLoaded(requests: page.requests, total: page.total);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      final now = state;
      if (now is RequestsLoaded) return failure;
      state = _token() == null
          ? const RequestsNeedPassword() // TOKEN_EXPIRED on this very fetch
          : RequestsFailed(failure);
      return null;
    } finally {
      _refreshing = false;
    }
  }

  /// Fetches the next page and adds it under the list.
  Future<AppFailure?> loadMore() async {
    final current = state;
    if (current is! RequestsLoaded || current.busy || !current.hasMore) {
      return null;
    }
    if (_refreshing) return null;
    final token = _token();
    if (token == null) {
      state = const RequestsNeedPassword();
      return null;
    }

    state = RequestsLoaded(
      requests: current.requests,
      total: current.total,
      loadingMore: true,
    );
    try {
      // The offset is how many are on screen. Rows approved or rejected
      // here have already left the server's pending list, so this lines up.
      final page = await _repository.pendingRequests(
        token: token,
        offset: current.requests.length,
      );
      if (!ref.mounted) return null;
      final now = _loadedOr(current);
      // If another administrator acted meanwhile, the pages can overlap.
      final known = {for (final r in now.requests) r.id};
      state = RequestsLoaded(
        requests: [
          ...now.requests,
          for (final r in page.requests)
            if (!known.contains(r.id)) r,
        ],
        total: page.total,
      );
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      final now = _loadedOr(current);
      state = RequestsLoaded(requests: now.requests, total: now.total);
      return failure;
    }
  }

  /// Approves [request].
  Future<RequestAction> approve(AccountRequest request) => _act(
    request,
    (token) => _repository.approve(token: token, id: request.id),
  );

  /// Rejects [request] with [reason]. The 3–500 character rule is checked by
  /// the dialog first and by the server again.
  Future<RequestAction> reject(AccountRequest request, String reason) => _act(
    request,
    (token) => _repository.reject(token: token, id: request.id, reason: reason),
  );

  Future<RequestAction> _act(
    AccountRequest request,
    Future<void> Function(String token) send,
  ) async {
    final current = state;
    if (current is! RequestsLoaded || current.busy || _refreshing) {
      return const RequestActionIgnored();
    }
    final token = _token();
    if (token == null) return const RequestNeedsPassword();

    state = RequestsLoaded(
      requests: current.requests,
      total: current.total,
      busyId: request.id,
    );

    try {
      await send(token);
    } on AppFailure catch (failure) {
      if (!ref.mounted) return RequestActionFailed(failure);
      _clearBusy(current);
      if (_alreadyHandled(failure)) {
        await refresh();
        return const RequestAlreadyHandled();
      }
      return RequestActionFailed(
        failure,
        failure is ServerRefused ? fieldErrorsFrom(failure.details) : const {},
      );
    }

    if (!ref.mounted) return const RequestActionDone();
    // Confirmed: the server said 200, so the row goes now.
    final now = _loadedOr(current);
    final remaining = [
      for (final r in now.requests)
        if (r.id != request.id) r,
    ];
    final total = now.total > 0 ? now.total - 1 : 0;
    state = RequestsLoaded(requests: remaining, total: total);
    // The last loaded row is gone but more wait on the server: fetch them,
    // rather than show an empty list with "Show more".
    if (remaining.isEmpty && total > 0) unawaited(refresh());
    return const RequestActionDone();
  }

  /// 404 USER_NOT_FOUND or 409 INVALID_STATUS_TRANSITION: the request is no
  /// longer pending (another administrator approved or rejected it first).
  /// ROLE_NOT_APPROVABLE is not one of these: it never changes, so it is
  /// shown as it is.
  static bool _alreadyHandled(AppFailure failure) =>
      failure is ServerRefused &&
      (failure.code == ApiCodes.userNotFound ||
          failure.code == ApiCodes.invalidStatusTransition);

  void _clearBusy(RequestsLoaded fallback) {
    final now = _loadedOr(fallback);
    state = RequestsLoaded(requests: now.requests, total: now.total);
  }

  /// The current list, or [fallback] if the state has moved away from it.
  RequestsLoaded _loadedOr(RequestsLoaded fallback) {
    final now = state;
    return now is RequestsLoaded ? now : fallback;
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets the list, so opening it again
/// always fetches a fresh one.
final accountRequestsControllerProvider =
    NotifierProvider.autoDispose<AccountRequestsController, RequestsState>(
      AccountRequestsController.new,
    );
