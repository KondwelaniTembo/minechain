// The state behind one alert's page (officer alerts plan, T3) and its two
// decisions, "Confirm problem" and "Clear, no problem" (T4).
//
// CONFIRMED, never optimistic: the page shows a decision only after the
// server has answered 200. A decision rejects a custody step or lets it onto
// the blockchain, and cannot be undone, so the phone must never show "done"
// for something the server refused.
//
// Never queued (Q3): an officer's decision is their word, not a signed custody
// step. A queued one could meet another officer's decision hours later (409)
// with nobody looking, so a decision without a network is simply not sent,
// and the page says so.
//
// One decision at a time: a second tap while the first is on its way does
// nothing (DecisionIgnored), so a double tap never sends twice.
//
// Nothing about the alert (QR code, username, notes) is logged; toString()
// prints codes only.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/field_errors.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/alerts_repository.dart';
import '../domain/alert.dart';

// ---- The page's states -------------------------------------------------------

sealed class AlertDetailState {
  const AlertDetailState();
}

final class AlertDetailLoading extends AlertDetailState {
  const AlertDetailLoading();
}

/// The token has expired: the password is needed first.
final class AlertDetailNeedsPassword extends AlertDetailState {
  const AlertDetailNeedsPassword();
}

/// 404 ALERT_NOT_FOUND: there is nothing to show or decide.
final class AlertDetailNotFound extends AlertDetailState {
  const AlertDetailNotFound();
}

final class AlertDetailFailed extends AlertDetailState {
  const AlertDetailFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'AlertDetailFailed($failure)';
}

final class AlertDetailLoaded extends AlertDetailState {
  const AlertDetailLoaded(this.alert, {this.deciding = false});

  final Alert alert;

  /// A decision is on its way to the server.
  final bool deciding;

  @override
  String toString() => 'AlertDetailLoaded($alert, deciding: $deciding)';
}

// ---- The two decisions ----------------------------------------------------------

enum AlertDecision {
  /// "Confirm problem": POST /alerts/{id}/review.
  confirmProblem,

  /// "Clear, no problem": POST /alerts/{id}/dismiss.
  clear,
}

/// What a decision came to.
sealed class DecisionOutcome {
  const DecisionOutcome();
}

/// The server saved it. [result] is its answer about the step and the
/// consignment now; [qrCode] names the consignment in the message.
final class DecisionDone extends DecisionOutcome {
  const DecisionDone(this.decision, this.result, this.qrCode);
  final AlertDecision decision;
  final AlertDecisionResult result;
  final String qrCode;

  @override
  String toString() => 'DecisionDone(${decision.name}, $result)';
}

/// 404, or 409 INVALID_STATUS_TRANSITION: another officer decided first (or
/// the alert is gone). The page has been read again.
final class DecisionAlreadyMade extends DecisionOutcome {
  const DecisionAlreadyMade();
}

/// Refused or not sent: the notes stay in the dialog. [fieldErrors] holds the
/// server's per-field messages (under `notes`).
final class DecisionFailed extends DecisionOutcome {
  const DecisionFailed(this.failure, [this.fieldErrors = const {}]);
  final AppFailure failure;
  final Map<String, String> fieldErrors;

  @override
  String toString() => 'DecisionFailed($failure)';
}

/// The token has expired: ask for the password, then try again.
final class DecisionNeedsPassword extends DecisionOutcome {
  const DecisionNeedsPassword();
}

/// Another decision (or a reload) is running; nothing was sent.
final class DecisionIgnored extends DecisionOutcome {
  const DecisionIgnored();
}

// ---- The controller ---------------------------------------------------------------

class AlertDetailController extends Notifier<AlertDetailState> {
  AlertDetailController(this.id);

  /// The alert's id, from the page's path.
  final String id;

  bool _loading = false;

  AlertsRepository get _repository => ref.read(alertsRepositoryProvider);

  @override
  AlertDetailState build() {
    Future.microtask(load);
    return const AlertDetailLoading();
  }

  /// Reads the alert (opening the page, "Try again", after the password).
  Future<void> load() async {
    if (!ref.mounted || _loading) return;
    final before = state;
    if (before is AlertDetailLoaded && before.deciding) return;
    final token = _token();
    if (token == null) {
      state = const AlertDetailNeedsPassword();
      return;
    }
    if (before is! AlertDetailLoaded) state = const AlertDetailLoading();

    _loading = true;
    try {
      final alert = await _repository.alert(token: token, id: id);
      if (!ref.mounted) return;
      state = AlertDetailLoaded(alert);
    } on AppFailure catch (failure) {
      if (!ref.mounted) return;
      if (_isNotFound(failure)) {
        state = const AlertDetailNotFound();
      } else if (_token() == null) {
        state = const AlertDetailNeedsPassword();
      } else if (before is! AlertDetailLoaded) {
        state = AlertDetailFailed(failure);
      }
      // A failed re-read with the alert on screen keeps it there.
    } finally {
      _loading = false;
    }
  }

  /// Sends [decision] with [notes]. The 3–500 character rule is checked by
  /// the dialog first and by the server again.
  Future<DecisionOutcome> decide(AlertDecision decision, String notes) async {
    final current = state;
    if (current is! AlertDetailLoaded || current.deciding || _loading) {
      return const DecisionIgnored();
    }
    final token = _token();
    if (token == null) return const DecisionNeedsPassword();

    state = AlertDetailLoaded(current.alert, deciding: true);
    final AlertDecisionResult result;
    try {
      result = await switch (decision) {
        AlertDecision.confirmProblem => _repository.confirmProblem(
          token: token,
          id: id,
          notes: notes,
        ),
        AlertDecision.clear => _repository.clear(
          token: token,
          id: id,
          notes: notes,
        ),
      };
    } on AppFailure catch (failure) {
      if (!ref.mounted) return DecisionFailed(failure);
      state = AlertDetailLoaded(current.alert);
      if (_alreadyMade(failure)) {
        // Shows the decision someone else made (or "no longer exists").
        await load();
        return const DecisionAlreadyMade();
      }
      return DecisionFailed(
        failure,
        failure is ServerRefused ? fieldErrorsFrom(failure.details) : const {},
      );
    }

    if (ref.mounted) state = AlertDetailLoaded(current.alert);
    return DecisionDone(decision, result, current.alert.consignment.qrCode);
  }

  static bool _isNotFound(AppFailure failure) =>
      failure is ServerRefused && failure.code == ApiCodes.alertNotFound;

  /// The alert is no longer open: another officer decided it first, or it is
  /// gone. STEP_CANNOT_BE_CLEARED is not one of these: nothing changed, and
  /// "Confirm problem" is still the way forward, so it is shown as it is.
  static bool _alreadyMade(AppFailure failure) =>
      _isNotFound(failure) ||
      (failure is ServerRefused &&
          failure.code == ApiCodes.invalidStatusTransition);

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// One controller per alert id. autoDispose: leaving the page forgets it.
final alertDetailControllerProvider = NotifierProvider.autoDispose
    .family<AlertDetailController, AlertDetailState, String>(
      AlertDetailController.new,
    );
