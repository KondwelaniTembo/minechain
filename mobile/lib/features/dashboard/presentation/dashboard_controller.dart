// The dashboard screen's state (dashboard plan, T4): one read of
// GET /dashboard when the screen opens, and again when the officer picks
// another period or mineral, pulls down, taps refresh or "Try again". No
// timer, as on the anchoring screen: a free server that sleeps is not woken
// for nothing.
//
// As in the other lists: an expired session asks for the password first, and
// a failed refresh keeps the last answer on screen and returns the failure
// for a short message. A new choice made while an answer is on its way wins:
// the older answer is dropped when it arrives.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/dashboard_repository.dart';
import '../domain/dashboard_period.dart';
import '../domain/dashboard_summary.dart';

sealed class DashboardState {
  const DashboardState(this.query);

  /// The period and mineral chosen.
  final DashboardQuery query;
}

/// The first read for [query] is on its way; nothing to show yet.
final class DashboardLoading extends DashboardState {
  const DashboardLoading(super.query);
}

/// The token has expired: the password is needed first.
final class DashboardNeedsPassword extends DashboardState {
  const DashboardNeedsPassword(super.query);
}

/// The read failed, with nothing to show.
final class DashboardFailed extends DashboardState {
  const DashboardFailed(super.query, this.failure);
  final AppFailure failure;

  @override
  String toString() => 'DashboardFailed($failure)';
}

/// An answer for [query].
final class DashboardLoaded extends DashboardState {
  const DashboardLoaded(super.query, this.summary, {this.refreshing = false});

  final DashboardSummary summary;

  /// A new read is on its way; this answer stays on screen.
  final bool refreshing;

  @override
  String toString() =>
      'DashboardLoaded(days: ${summary.days}, '
      'refreshing: $refreshing)';
}

/// The first choice: the last 7 days, every mineral.
const initialDashboardQuery = DashboardQuery(period: DashboardPeriod.week);

class DashboardController extends Notifier<DashboardState> {
  /// Counts reads, so an answer to an older choice can be dropped.
  int _readNumber = 0;

  @override
  DashboardState build() {
    // The first read starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const DashboardLoading(initialDashboardQuery);
  }

  /// Shows [query] instead. Nothing is read if it is already chosen.
  Future<AppFailure?> choose(DashboardQuery query) async {
    if (!ref.mounted || query == state.query) return null;
    return _read(query);
  }

  /// Reads the chosen period again. Returns a failure only when an answer
  /// was already on screen and stays there; otherwise the failure becomes
  /// the state itself.
  Future<AppFailure?> refresh() async {
    if (!ref.mounted) return null;
    final now = state;
    // One read at a time for the same choice (refresh button, pull-down).
    if (now is DashboardLoaded && now.refreshing) return null;
    return _read(now.query);
  }

  Future<AppFailure?> _read(DashboardQuery query) async {
    final token = _token();
    if (token == null) {
      state = DashboardNeedsPassword(query);
      return null;
    }
    final before = state;
    // The last answer stays on screen while the new one loads, the chips
    // already showing the new choice.
    state = before is DashboardLoaded
        ? DashboardLoaded(query, before.summary, refreshing: true)
        : DashboardLoading(query);

    final number = ++_readNumber;
    try {
      final summary = await ref
          .read(dashboardRepositoryProvider)
          .summary(token: token, query: query);
      if (!ref.mounted || number != _readNumber) return null;
      state = DashboardLoaded(query, summary);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted || number != _readNumber) return null;
      if (_token() == null) {
        state = DashboardNeedsPassword(query); // TOKEN_EXPIRED on this read
        return null;
      }
      if (before is DashboardLoaded) {
        // The last answer stays, with the choice it answers.
        state = DashboardLoaded(before.query, before.summary);
        return failure;
      }
      state = DashboardFailed(query, failure);
      return null;
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets it, so it is read fresh each time.
final dashboardControllerProvider =
    NotifierProvider.autoDispose<DashboardController, DashboardState>(
      DashboardController.new,
    );
