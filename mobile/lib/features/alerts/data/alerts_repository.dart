// The officer's alerts, on top of AlertsApi.
//
// Like AdminUsersRepository, it builds the API only when first needed (the
// pinned certificates load in the background) and turns a pinning set-up
// failure into InsecureConnection, so a missing certificate never looks like
// a crash. The expired-session handling (the password prompt) sits in the
// controllers, as for "Account requests".
//
// Decisions are never queued (plan Q3): an officer's decision needs the
// network, and a failure is reported at once.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/alert.dart';
import 'alerts_api.dart';

class AlertsRepository {
  AlertsRepository({required this._api});

  final Future<AlertsApi> Function() _api;

  /// One page of alerts with [status]. Throws an AppFailure.
  Future<AlertsPage> alerts({
    required String token,
    required AlertStatus status,
    int offset = 0,
  }) async {
    final api = await _apiOrInsecure();
    return api.alerts(token: token, status: status, offset: offset);
  }

  /// The alert [id] with the other alerts on its consignment.
  Future<Alert> alert({required String token, required String id}) async {
    final api = await _apiOrInsecure();
    return api.alert(token: token, id: id);
  }

  /// "Confirm problem" on [id] with [notes]. Throws an AppFailure if
  /// refused.
  ///
  /// The notes are sent trimmed: the server trims them too, but they are
  /// kept for ever in the audit log, so what is sent should be exactly what
  /// is meant.
  Future<AlertDecisionResult> confirmProblem({
    required String token,
    required String id,
    required String notes,
  }) async {
    final api = await _apiOrInsecure();
    return api.review(token: token, id: id, notes: notes.trim());
  }

  /// "Clear, no problem" on [id] with [notes], trimmed as above.
  Future<AlertDecisionResult> clear({
    required String token,
    required String id,
    required String notes,
  }) async {
    final api = await _apiOrInsecure();
    return api.dismiss(token: token, id: id, notes: notes.trim());
  }

  Future<AlertsApi> _apiOrInsecure() async {
    try {
      return await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
  }
}

final alertsRepositoryProvider = Provider<AlertsRepository>((ref) {
  return AlertsRepository(
    api: () async => AlertsApi(await ref.read(apiClientProvider.future)),
  );
});
