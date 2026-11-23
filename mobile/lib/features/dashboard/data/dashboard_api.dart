// The officer's dashboard endpoint, as docs/api.md ("GET /dashboard")
// documents it (dashboard plan, T3):
//
//   GET /dashboard?from=YYYY-MM-DD&to=YYYY-MM-DD[&mineral=gold]
//     200 { period, mineral, now, steps, registeredWeightMg, byDay,
//           byMineral, byZone, outsideZones, anomalies }
//
// Officer only, not rate-limited, not audited. Refusals: VALIDATION_FAILED and
// FORBIDDEN, on top of the token errors.
//
// This file only turns the answer into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/dashboard_summary.dart';

class DashboardApi {
  DashboardApi(this._api);

  final ApiClient _api;

  /// GET /dashboard with [query] (from, to and an optional mineral).
  Future<DashboardSummary> summary({
    required String token,
    required Map<String, String> query,
  }) async {
    final json = await _api.get(
      const ['dashboard'],
      token: token,
      query: query,
    );
    final summary = DashboardSummary.fromJson(json);
    if (summary == null) throw const BadResponse(status: 200);
    return summary;
  }
}
