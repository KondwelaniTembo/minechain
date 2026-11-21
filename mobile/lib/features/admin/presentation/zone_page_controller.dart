// The state behind one zone's page (GPS zones plan, T3 and T4): the zone and
// the action running now.
//
// The page starts from the row the list gave it (openedZoneProvider): there
// is no GET /admin/zones/{id}. Every action answers with the zone's new view,
// which replaces it, so the page always shows what the server last said.
// Nothing changes on screen until the server has answered 200.
//
// One action at a time: while one runs, every button is off and a second
// call is ignored, so a double tap sends once.
//
// Built like AccountPageController; nothing about the zone is logged.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/field_errors.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_zones_repository.dart';
import '../domain/gps_zone.dart';
import '../domain/zone_actions.dart';

class ZonePageState {
  const ZonePageState({required this.zone, this.busy});

  /// The zone as the server last gave it.
  final GpsZone zone;

  /// The action on its way, or null.
  final ZoneAction? busy;

  @override
  String toString() => 'ZonePageState($zone, busy: ${busy?.name})';
}

// ---- What an action came to --------------------------------------------------

sealed class ZoneActionOutcome {
  const ZoneActionOutcome();
}

/// The server accepted it; the page shows [zone] now. [warning] is set when a
/// deactivation left no zone active.
final class ZoneActionDone extends ZoneActionOutcome {
  const ZoneActionDone(this.zone, {this.warning});
  final GpsZone zone;
  final ZoneWarning? warning;

  @override
  String toString() => 'ZoneActionDone($zone, warning: $warning)';
}

/// Refused or not sent. [fieldErrors] holds the server's per-field messages
/// (`name`, `reason`), keyed by the API's field names.
final class ZoneActionFailed extends ZoneActionOutcome {
  const ZoneActionFailed(this.failure, [this.fieldErrors = const {}]);
  final AppFailure failure;
  final Map<String, String> fieldErrors;

  /// INVALID_STATUS_TRANSITION: another administrator acted first, so the
  /// page's zone is out of date.
  bool get outOfDate =>
      failure is ServerRefused &&
      (failure as ServerRefused).code == ApiCodes.invalidStatusTransition;

  @override
  String toString() => 'ZoneActionFailed($failure)';
}

/// The token has expired: ask for the password, then try again.
final class ZoneActionNeedsPassword extends ZoneActionOutcome {
  const ZoneActionNeedsPassword();
}

/// Another action is running; nothing was sent.
final class ZoneActionIgnored extends ZoneActionOutcome {
  const ZoneActionIgnored();
}

// ---- The controller ---------------------------------------------------------

class ZonePageController extends Notifier<ZonePageState> {
  ZonePageController(this.initial);

  /// The row the list gave the page.
  final GpsZone initial;

  AdminZonesRepository get _repository =>
      ref.read(adminZonesRepositoryProvider);

  @override
  ZonePageState build() => ZonePageState(zone: initial);

  String get _id => state.zone.id;

  Future<ZoneActionOutcome> rename(String name) => _act(
    ZoneAction.rename,
    (token) async => ZoneActionDone(
      await _repository.rename(token: token, id: _id, name: name),
    ),
  );

  Future<ZoneActionOutcome> deactivate(String reason) =>
      _act(ZoneAction.deactivate, (token) async {
        final answer = await _repository.deactivate(
          token: token,
          id: _id,
          reason: reason,
        );
        return ZoneActionDone(answer.zone, warning: answer.warning);
      });

  Future<ZoneActionOutcome> reactivate() => _act(
    ZoneAction.reactivate,
    (token) async =>
        ZoneActionDone(await _repository.reactivate(token: token, id: _id)),
  );

  Future<ZoneActionOutcome> _act(
    ZoneAction action,
    Future<ZoneActionDone> Function(String token) send,
  ) async {
    if (state.busy != null) return const ZoneActionIgnored();
    final token = _token();
    if (token == null) return const ZoneActionNeedsPassword();

    state = ZonePageState(zone: state.zone, busy: action);
    try {
      final done = await send(token);
      if (ref.mounted) state = ZonePageState(zone: done.zone);
      return done;
    } on AppFailure catch (failure) {
      if (ref.mounted) state = ZonePageState(zone: state.zone);
      // TOKEN_EXPIRED counts too, before the auth controller has caught up
      // (Admin accounts T6b).
      final expired =
          failure is ServerRefused && failure.code == ApiCodes.tokenExpired;
      if (expired || _token() == null) return const ZoneActionNeedsPassword();
      return ZoneActionFailed(
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

/// One page per zone row. autoDispose: leaving the page forgets it.
final zonePageControllerProvider = NotifierProvider.autoDispose
    .family<ZonePageController, ZonePageState, GpsZone>(ZonePageController.new);
