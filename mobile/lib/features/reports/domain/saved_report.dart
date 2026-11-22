// A report the phone has downloaded and written to its private cache
// (reports plan, T1), and the rule for the name it is written under. Plain
// Dart.

import 'report_request.dart';

/// The only filenames a report is ever written under: the server's own form
/// (api.md, "The file"), starting `minechain-` and ending `.csv`, with only
/// lower-case letters, digits, `.` and `-` between. No `/`, `\` or `..`, so
/// a name can never reach outside the reports folder.
final RegExp _safeName = RegExp(r'^minechain-[a-z0-9.-]{1,110}\.csv$');

bool isSafeReportFilename(String name) =>
    _safeName.hasMatch(name) && !name.contains('..');

/// Used only if even the request's own name is not in the safe form (an id
/// from the server with odd characters in it).
const String lastResortReportFilename = 'minechain-report.csv';

/// The name to write [request]'s file under: the server's [fromServer] if it
/// is safe, else the request's fallback if that is, else
/// [lastResortReportFilename].
String reportFilename(String? fromServer, ReportRequest request) {
  if (fromServer != null && isSafeReportFilename(fromServer)) {
    return fromServer;
  }
  final fallback = request.fallbackFilename;
  return isSafeReportFilename(fallback) ? fallback : lastResortReportFilename;
}

/// A downloaded report, on the phone.
class SavedReport {
  const SavedReport({
    required this.path,
    required this.filename,
    required this.rows,
    required this.downloadedAt,
  });

  /// Where the file is, inside the app's private cache.
  final String path;

  /// Its name, as shown and as shared.
  final String filename;

  /// Data rows, the header not counted.
  final int rows;

  /// When it was written, in UTC.
  final DateTime downloadedAt;

  /// No path or name: the name holds a consignment's or a person's id.
  @override
  String toString() => 'SavedReport(rows: $rows)';
}
