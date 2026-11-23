// The anchoring status endpoint, as docs/api.md ("Anchoring administration")
// documents it (anchoring status plan, T2):
//
//   GET /admin/anchoring          no query (any parameter is refused)
//     200 { worker, counts, inFlight, failed, pending, held, lastConfirmed,
//           lastSubmitted, problems }
//
// Admin only, not rate-limited, and it makes no blockchain call, so it
// answers even while the RPC provider is down. Refusals: FORBIDDEN, on top of
// the token errors. "Run now" and "Retry" are not called from the app
// (Scope (11)).
//
// This file only turns the answer into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/anchoring_status.dart';

class AdminAnchoringApi {
  AdminAnchoringApi(this._api);

  final ApiClient _api;

  /// GET /admin/anchoring.
  Future<AnchoringStatus> status({required String token}) async {
    final json = await _api.get(const ['admin', 'anchoring'], token: token);
    final status = AnchoringStatus.fromJson(json);
    if (status == null) throw const BadResponse(status: 200);
    return status;
  }
}
