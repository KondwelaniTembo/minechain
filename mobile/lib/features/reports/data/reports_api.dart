// The two report endpoints, as docs/api.md ("Reports (FR-09, FR-13)")
// documents them:
//
//   GET /reports/transactions?from&to[&mineral&type&reviewStatus&anchorStatus]
//     officer, buyer (own purchases only) or admin
//   GET /reports/audit-trail?consignmentId=… | ?actorId=…&from&to
//     officer only
//
// 200 is `text/csv; charset=utf-8` with a BOM, every field quoted, CRLF;
// refusals are the usual JSON (VALIDATION_FAILED, FORBIDDEN,
// CONSIGNMENT_NOT_FOUND, USER_NOT_FOUND, REPORT_TOO_LARGE 422,
// TOO_MANY_REQUESTS 429 with Retry-After: 20 downloads per 15 minutes per
// account, both reports together). They arrive as ServerRefused from
// ApiClient, unchanged.

import '../../../core/network/api_client.dart';
import '../domain/report_request.dart';

class ReportsApi {
  ReportsApi(this._api);

  final ApiClient _api;

  /// A full report is up to 10,000 rows, about 6 MB: more than the usual
  /// 30 s on a slow 3G link.
  static const Duration timeout = Duration(seconds: 120);

  /// Downloads [request]'s file.
  Future<DownloadedFile> download({
    required String token,
    required ReportRequest request,
  }) => _api.getFile(
    request.path,
    mediaType: 'text/csv',
    query: request.query,
    token: token,
    timeout: timeout,
  );
}
