// The four alert endpoints, as docs/api.md ("Alerts (FR-08)") documents them:
//
//   GET  /alerts?status=<open|reviewed|dismissed>&limit=<1-100>&offset=<0-10000>
//     200 { "alerts": [alert view, ...], "total", "limit", "offset" }
//     Open alerts oldest first; closed ones newest decision first.
//   GET  /alerts/{id}
//     200 { "alert": {alert view, "otherAlerts": [...]} }
//   POST /alerts/{id}/review    body: { "notes": 3-500 characters }
//   POST /alerts/{id}/dismiss   body: the same
//     200 { "alert": {...}, "step": { id, reviewStatus },
//           "consignment": { id, stage, held } }
//
// All four: active officers only (administrators get 403 too), no caching.
// The two decisions share a limit of 60 per 15 minutes (429 with
// Retry-After). Refusals: VALIDATION_FAILED, FORBIDDEN, ALERT_NOT_FOUND (404),
// INVALID_STATUS_TRANSITION (409, already closed), STEP_CANNOT_BE_CLEARED
// (409, dismiss only), TOO_MANY_REQUESTS, on top of the token errors. They
// arrive as ServerRefused from ApiClient, unchanged.
//
// This file only turns the answers into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/alert.dart';

class AlertsApi {
  AlertsApi(this._api);

  final ApiClient _api;

  /// Alerts per page, as on "Account requests": small answers on a slow
  /// network, and "Show more" for the next.
  static const int pageSize = 20;

  /// GET /alerts with [status], starting after [offset] of them.
  Future<AlertsPage> alerts({
    required String token,
    required AlertStatus status,
    int offset = 0,
  }) async {
    final json = await _api.get(
      const ['alerts'],
      query: {'status': status.name, 'limit': '$pageSize', 'offset': '$offset'},
      token: token,
    );
    if (json is! Map) throw const BadResponse(status: 200);
    final rows = json['alerts'];
    final total = json['total'];
    if (rows is! List || total is! int || total < 0) {
      throw const BadResponse(status: 200);
    }

    final alerts = <Alert>[];
    for (final row in rows) {
      final alert = Alert.fromJson(row);
      // One unreadable alert makes the page unreadable rather than being
      // skipped: an alert silently missing from the queue would hold its
      // consignment for ever, and no officer would know why.
      if (alert == null) throw const BadResponse(status: 200);
      alerts.add(alert);
    }
    return AlertsPage(alerts: alerts, total: total);
  }

  /// GET /alerts/{id}, with the other alerts on its consignment.
  Future<Alert> alert({required String token, required String id}) async {
    final json = await _api.get(['alerts', id], token: token);
    final alert = json is Map ? Alert.fromJson(json['alert']) : null;
    // The detail always carries otherAlerts; without it the hold sentence
    // ("another alert is still open") could be wrong.
    if (alert == null || alert.otherAlerts == null) {
      throw const BadResponse(status: 200);
    }
    return alert;
  }

  /// POST /alerts/{id}/review: "Confirm problem".
  Future<AlertDecisionResult> review({
    required String token,
    required String id,
    required String notes,
  }) => _decide(token, id, 'review', notes);

  /// POST /alerts/{id}/dismiss: "Clear, no problem".
  Future<AlertDecisionResult> dismiss({
    required String token,
    required String id,
    required String notes,
  }) => _decide(token, id, 'dismiss', notes);

  Future<AlertDecisionResult> _decide(
    String token,
    String id,
    String decision,
    String notes,
  ) async {
    final json = await _api.post(
      ['alerts', id, decision],
      // Exactly one field: the server refuses any other.
      body: {'notes': notes},
      token: token,
    );
    return AlertDecisionResult.fromJson(json);
  }
}
