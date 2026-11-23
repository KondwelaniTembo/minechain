// The officer's dashboard, on top of DashboardApi (dashboard plan, T3).
//
// Like AdminAnchoringRepository, it builds the API only when first needed
// (the pinned certificates load in the background) and turns a pinning
// set-up failure into InsecureConnection. The clock is passed in, so tests
// choose "today". It throws an AppFailure if refused.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/dashboard_period.dart';
import '../domain/dashboard_summary.dart';
import 'dashboard_api.dart';

class DashboardRepository {
  DashboardRepository({required this._api, Clock? clock})
    : _clock = clock ?? systemClock;

  final Future<DashboardApi> Function() _api;
  final Clock _clock;

  Future<DashboardSummary> summary({
    required String token,
    required DashboardQuery query,
  }) async {
    final DashboardApi api;
    try {
      api = await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
    return api.summary(token: token, query: query.parametersAt(_clock()));
  }
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(
    api: () async => DashboardApi(await ref.read(apiClientProvider.future)),
    clock: ref.watch(clockProvider),
  );
});
