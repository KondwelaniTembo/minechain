// The anchoring status screen's state (anchoring status plan, T3): one read of
// GET /admin/anchoring when the screen opens, and again on the refresh button,
// pull-down and "Try again" (Q2: no timer, so a free server that sleeps is
// not woken for nothing).
//
// As in the zones list: an expired session asks for the password first, and
// a failed refresh keeps the last answer on screen and returns the failure
// for a short message.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_anchoring_repository.dart';
import '../domain/anchoring_status.dart';

sealed class AnchoringScreenState {
  const AnchoringScreenState();
}

/// The first read is on its way; nothing to show yet.
final class AnchoringLoading extends AnchoringScreenState {
  const AnchoringLoading();
}

/// The token has expired: the password is needed first.
final class AnchoringNeedsPassword extends AnchoringScreenState {
  const AnchoringNeedsPassword();
}

/// The first read failed.
final class AnchoringFailed extends AnchoringScreenState {
  const AnchoringFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'AnchoringFailed($failure)';
}

/// An answer, and when the phone got it.
final class AnchoringLoaded extends AnchoringScreenState {
  const AnchoringLoaded({
    required this.status,
    required this.readAt,
    this.refreshing = false,
  });

  final AnchoringStatus status;

  /// The phone's own time, in UTC.
  final DateTime readAt;

  /// A new read is on its way; the last answer stays on screen.
  final bool refreshing;

  @override
  String toString() =>
      'AnchoringLoaded(state: ${status.state}, refreshing: $refreshing)';
}

class AnchoringStatusController extends Notifier<AnchoringScreenState> {
  bool _reading = false;

  @override
  AnchoringScreenState build() {
    // The first read starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const AnchoringLoading();
  }

  /// Reads the status again. Returns a failure only when an answer was
  /// already on screen and stays there; otherwise the failure becomes the
  /// state itself.
  Future<AppFailure?> refresh() async {
    if (!ref.mounted || _reading) return null;
    final token = _token();
    if (token == null) {
      state = const AnchoringNeedsPassword();
      return null;
    }
    final before = state;
    state = before is AnchoringLoaded
        ? AnchoringLoaded(
            status: before.status,
            readAt: before.readAt,
            refreshing: true,
          )
        : const AnchoringLoading();

    _reading = true;
    try {
      final status = await ref
          .read(adminAnchoringRepositoryProvider)
          .status(token: token);
      if (!ref.mounted) return null;
      state = AnchoringLoaded(
        status: status,
        readAt: ref.read(clockProvider)().toUtc(),
      );
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      if (before is AnchoringLoaded) {
        state = before;
        return failure;
      }
      state = _token() == null
          ? const AnchoringNeedsPassword() // TOKEN_EXPIRED on this very read
          : AnchoringFailed(failure);
      return null;
    } finally {
      _reading = false;
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets it, so it is read fresh each time.
final anchoringStatusControllerProvider =
    NotifierProvider.autoDispose<
      AnchoringStatusController,
      AnchoringScreenState
    >(AnchoringStatusController.new);
