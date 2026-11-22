// Hands a saved report to Android's share sheet (reports plan, T2, Q1):
// Drive, Gmail, WhatsApp, the phone's own "save" targets, whatever is
// installed. Behind a provider, so widget tests use a fake that only records
// the call.
//
// The file stays in the app's private cache. share_plus hands the chosen app
// a content:// address through its own FileProvider, with a read grant for
// that one file, so no storage permission is needed.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/saved_report.dart';

/// What came of opening the share sheet.
enum ShareOutcome {
  /// The user picked an app.
  shared,

  /// The user closed the sheet without picking one.
  dismissed,

  /// The phone could not say (share_plus's `unavailable`); nothing is shown
  /// either way, so "Not shared" never contradicts a share that happened.
  unknown,
}

abstract interface class ReportSharer {
  /// Opens the share sheet for [report]. Throws if it could not be opened.
  Future<ShareOutcome> share(SavedReport report);
}

class SharePlusReportSharer implements ReportSharer {
  const SharePlusReportSharer();

  @override
  Future<ShareOutcome> share(SavedReport report) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(report.path, mimeType: 'text/csv', name: report.filename),
        ],
        // The subject is what Gmail puts in its subject line.
        subject: report.filename,
      ),
    );
    return switch (result.status) {
      ShareResultStatus.success => ShareOutcome.shared,
      ShareResultStatus.dismissed => ShareOutcome.dismissed,
      ShareResultStatus.unavailable => ShareOutcome.unknown,
    };
  }
}

final reportSharerProvider = Provider<ReportSharer>(
  (ref) => const SharePlusReportSharer(),
);
