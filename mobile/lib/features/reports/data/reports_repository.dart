// Report downloads, on top of ReportsApi and ReportFileStore (reports plan,
// T1): download, choose a safe name, write the file, count its rows.
//
// The server's byte order mark is left out of the file (T5b, decision
// Reports app): Excel on Windows needs it only for letters outside English,
// while Google Sheets on Android showed it as "ï»¿" in the first header.
//
// Like AlertsRepository, it builds the API only when first needed and turns
// a pinning set-up failure into InsecureConnection. The expired-session
// handling (the password prompt) sits in the controller.
//
// Nothing here is logged: a report holds usernames, licence numbers and
// coordinates, and its name holds an id.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/csv_records.dart';
import '../domain/report_request.dart';
import '../domain/saved_report.dart';
import 'report_file_store.dart';
import 'reports_api.dart';

class ReportsRepository {
  ReportsRepository({
    required this._api,
    required this._store,
    required this._clock,
  });

  final Future<ReportsApi> Function() _api;
  final ReportFileStore _store;
  final Clock _clock;

  /// Downloads [request] and keeps it as the phone's one saved report.
  /// Throws an AppFailure, or ReportNotSaved if it could not be written.
  Future<SavedReport> download({
    required String token,
    required ReportRequest request,
  }) async {
    final ReportsApi api;
    try {
      api = await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
    final file = await api.download(token: token, request: request);
    final filename = reportFilename(file.filename, request);
    final bytes = withoutByteOrderMark(file.bytes);
    final path = await _store.save(bytes, filename);
    return SavedReport(
      path: path,
      filename: filename,
      rows: countRecords(bytes),
      downloadedAt: _clock(),
    );
  }
}

final reportsRepositoryProvider = Provider<ReportsRepository>((ref) {
  return ReportsRepository(
    api: () async => ReportsApi(await ref.read(apiClientProvider.future)),
    store: ref.watch(reportFileStoreProvider),
    clock: ref.watch(clockProvider),
  );
});
