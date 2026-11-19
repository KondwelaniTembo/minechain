// The one endpoint the consignment check needs, as docs/api.md documents it:
//
//   GET /consignments/by-qr/{qrCode}
//     200 { "consignment": {...}, "steps": [...] }, cut down per role
//     transporter, buyer or officer only; 60 scans per 15 minutes per user
//
// Refusals on top of the token errors: 400 VALIDATION_FAILED (a malformed
// code), 403 FORBIDDEN (a miner or administrator), 404 CONSIGNMENT_NOT_FOUND
// (no such code, OR one this buyer may not see: the two are identical on
// purpose), 429 TOO_MANY_REQUESTS with Retry-After. They all arrive as
// ServerRefused from ApiClient, unchanged.
//
// This file only turns the answer into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/consignment_view.dart';

class ConsignmentCheckApi {
  ConsignmentCheckApi(this._api);

  final ApiClient _api;

  /// GET /consignments/by-qr/{qrCode}.
  ///
  /// [qrCode] goes in as one path segment, so ApiClient encodes any "/" in
  /// it as %2F, which api.md requires ("A raw / makes a different path").
  /// The app only scans custody record IDs, which have no "/", but the rule
  /// belongs here, not in the scanner.
  ///
  /// Not retried and not cached: the answer is a LIVE check against the
  /// blockchain (`Cache-Control: no-store`), and every scan counts towards
  /// the rate limit.
  Future<ConsignmentView> byQr({
    required String token,
    required String qrCode,
  }) async {
    final json = await _api.get([
      'consignments',
      'by-qr',
      qrCode,
    ], token: token);
    final view = ConsignmentView.fromJson(json);
    if (view == null) throw const BadResponse(status: 200);
    return view;
  }
}
