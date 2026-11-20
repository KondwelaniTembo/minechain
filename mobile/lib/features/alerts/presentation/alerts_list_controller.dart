// The state behind the officer's alerts list (officer alerts plan, T2): one
// list per status (Q1: "Open", "Confirmed", "Cleared"), fetched 20 at a time.
//
// Built like AccountRequestsController, for the same reason: the screen
// needs more than "loading, data or error" (the password prompt, "Show more"
// while the list stays on screen). The decisions themselves are made on the
// alert's own page (T4); this list is simply read again when the officer
// comes back to it, so it never shows a decision the server has not made.
//
// Nothing about an alert (QR code, username, notes) is logged; the states'
// toString() print only counts.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/alerts_repository.dart';
import '../domain/alert.dart';

sealed class AlertsListState {
  const AlertsListState();
}

/// The first page is being fetched; nothing to show yet.
final class AlertsLoading extends AlertsListState {
  const AlertsLoading();
}

/// The token has expired: the password is needed first.
final class AlertsNeedPassword extends AlertsListState {
  const AlertsNeedPassword();
}

/// The first page could not be fetched.
final class AlertsFailed extends AlertsListState {
  const AlertsFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'AlertsFailed($failure)';
}

/// The list, possibly empty.
final class AlertsLoaded extends AlertsListState {
  const AlertsLoaded({
    required this.alerts,
    required this.total,
    this.loadingMore = false,
  });

  /// In the server's order: open alerts oldest first, closed ones newest
  /// decision first.
  final List<Alert> alerts;

  /// Every alert with this status on the server, not only those loaded.
  final int total;

  /// "Show more" is fetching the next page.
  final bool loadingMore;

  bool get hasMore => alerts.length < total;

  @override
  String toString() =>
      'AlertsLoaded(alerts: ${alerts.length}, total: $total, '
      'loadingMore: $loadingMore)';
}

class AlertsListController extends Notifier<AlertsListState> {
  AlertsListController(this.status);

  /// Which of the three lists this is.
  final AlertStatus status;

  bool _refreshing = false;

  AlertsRepository get _repository => ref.read(alertsRepositoryProvider);

  @override
  AlertsListState build() {
    // The first fetch starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const AlertsLoading();
  }

  /// Fetches the first page again (opening the screen, coming back from an
  /// alert, pull-to-refresh, the refresh button, "Try again").
  ///
  /// Returns a failure only when a list was already on screen and stays
  /// there, so the screen can mention it briefly. Without a list, the
  /// failure becomes the state itself.
  Future<AppFailure?> refresh() async {
    if (!ref.mounted) return null;
    final before = state;
    if (_refreshing) return null;
    if (before is AlertsLoaded && before.loadingMore) return null;

    final token = _token();
    if (token == null) {
      state = const AlertsNeedPassword();
      return null;
    }
    if (before is! AlertsLoaded) state = const AlertsLoading();

    _refreshing = true;
    try {
      final page = await _repository.alerts(token: token, status: status);
      if (!ref.mounted) return null;
      state = AlertsLoaded(alerts: page.alerts, total: page.total);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      if (state is AlertsLoaded) return failure;
      state = _token() == null
          ? const AlertsNeedPassword() // TOKEN_EXPIRED on this very fetch
          : AlertsFailed(failure);
      return null;
    } finally {
      _refreshing = false;
    }
  }

  /// Fetches the next page and adds it under the list.
  Future<AppFailure?> loadMore() async {
    final current = state;
    if (current is! AlertsLoaded || current.loadingMore || !current.hasMore) {
      return null;
    }
    if (_refreshing) return null;
    final token = _token();
    if (token == null) {
      state = const AlertsNeedPassword();
      return null;
    }

    state = AlertsLoaded(
      alerts: current.alerts,
      total: current.total,
      loadingMore: true,
    );
    try {
      final page = await _repository.alerts(
        token: token,
        status: status,
        offset: current.alerts.length,
      );
      if (!ref.mounted) return null;
      // If another officer decided meanwhile, the pages can overlap.
      final known = {for (final a in current.alerts) a.id};
      state = AlertsLoaded(
        alerts: [
          ...current.alerts,
          for (final a in page.alerts)
            if (!known.contains(a.id)) a,
        ],
        total: page.total,
      );
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      state = AlertsLoaded(alerts: current.alerts, total: current.total);
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
final alertsListControllerProvider = NotifierProvider.autoDispose
    .family<AlertsListController, AlertsListState, AlertStatus>(
      AlertsListController.new,
    );
