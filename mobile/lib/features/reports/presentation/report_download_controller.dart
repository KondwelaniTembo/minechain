// One report download and its share (reports plan, T3; used again by T4):
// download → write the file → open the share sheet.
//
// A family by [ReportSlot], so the transactions screen, the check result's
// audit trail and the alert page's audit trail each keep their own card.
// autoDispose: leaving the screen forgets the card (the file itself stays in
// the cache until the next download, Q5).
//
// One download at a time: a tap while one runs does nothing, so a double tap
// sends one request (each counts towards 20 per 15 minutes on the server).
//
// Nothing about a report is logged; the states' toString() print no id,
// path or name.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/report_file_store.dart';
import '../data/report_sharer.dart';
import '../data/reports_repository.dart';
import '../domain/report_request.dart';
import '../domain/saved_report.dart';

/// Which download this is: each place that offers one has its own.
enum ReportSlot { transactions, consignmentTrail, personTrail }

/// Where the share sheet has got to, for the line on the card.
enum ShareStatus {
  /// The sheet is opening (it opens by itself after a download, Q6).
  opening,
  shared,
  notShared,

  /// The phone could not say: no line is shown.
  unknown,

  /// The sheet could not be opened.
  failed,
}

sealed class ReportDownloadState {
  const ReportDownloadState();
}

/// Nothing downloaded yet.
final class ReportIdle extends ReportDownloadState {
  const ReportIdle();

  @override
  String toString() => 'ReportIdle()';
}

/// [request] is downloading.
final class ReportDownloading extends ReportDownloadState {
  const ReportDownloading(this.request);
  final ReportRequest request;

  @override
  String toString() => 'ReportDownloading()';
}

/// The session has ended: the password is needed before [request] is sent
/// again. Nothing more was downloaded.
final class ReportNeedsPassword extends ReportDownloadState {
  const ReportNeedsPassword(this.request);
  final ReportRequest request;

  @override
  String toString() => 'ReportNeedsPassword()';
}

/// [request] failed: [failure] is an AppFailure, or ReportNotSaved when the
/// file could not be written.
final class ReportFailed extends ReportDownloadState {
  const ReportFailed(this.request, this.failure);
  final ReportRequest request;
  final Exception failure;

  @override
  String toString() => 'ReportFailed($failure)';
}

/// [report] is on the phone; [share] says how its share went.
final class ReportReady extends ReportDownloadState {
  const ReportReady(this.request, this.report, this.share);
  final ReportRequest request;
  final SavedReport report;
  final ShareStatus share;

  @override
  String toString() => 'ReportReady($report, $share)';
}

class ReportDownloadController extends Notifier<ReportDownloadState> {
  ReportDownloadController(this.slot);

  final ReportSlot slot;

  @override
  ReportDownloadState build() => const ReportIdle();

  bool get busy => switch (state) {
    ReportDownloading() => true,
    ReportReady(share: ShareStatus.opening) => true,
    _ => false,
  };

  /// "Download and share". The screen checks the period first and never
  /// sends a request with a problem; this checks again, so none is sent.
  Future<void> download(ReportRequest request) async {
    if (busy || request.problem != null) return;
    final token = _token();
    if (token == null) {
      state = ReportNeedsPassword(request);
      return;
    }
    state = ReportDownloading(request);
    final SavedReport report;
    try {
      report = await ref
          .read(reportsRepositoryProvider)
          .download(token: token, request: request);
    } on AppFailure catch (failure) {
      if (!ref.mounted) return;
      // A TOKEN_EXPIRED on this very request has already moved the session
      // to "needs password" (ApiClient's session events).
      state = _token() == null
          ? ReportNeedsPassword(request)
          : ReportFailed(request, failure);
      return;
    } on ReportNotSaved catch (failure) {
      if (!ref.mounted) return;
      state = ReportFailed(request, failure);
      return;
    }
    if (!ref.mounted) return;
    await _share(request, report);
  }

  /// "Try again" after a failure, or after the password was entered: the
  /// same request again.
  Future<void> retry() async {
    final request = switch (state) {
      ReportFailed(:final request) ||
      ReportNeedsPassword(:final request) => request,
      _ => null,
    };
    if (request == null) return;
    // Out of the failed state first, so download() does not see it.
    state = const ReportIdle();
    await download(request);
  }

  /// The form changed under a failure or a password prompt (T5b): their
  /// "Try again" would send the old choices, so the card goes. A saved file's
  /// card stays: it names its own file.
  void forgetFailure() {
    if (state is ReportFailed || state is ReportNeedsPassword) {
      state = const ReportIdle();
    }
  }

  /// "Share again": the same file, no new download.
  Future<void> shareAgain() async {
    final current = state;
    if (current is! ReportReady || busy) return;
    await _share(current.request, current.report);
  }

  Future<void> _share(ReportRequest request, SavedReport report) async {
    state = ReportReady(request, report, ShareStatus.opening);
    ShareStatus result;
    try {
      final outcome = await ref.read(reportSharerProvider).share(report);
      result = switch (outcome) {
        ShareOutcome.shared => ShareStatus.shared,
        ShareOutcome.dismissed => ShareStatus.notShared,
        ShareOutcome.unknown => ShareStatus.unknown,
      };
    } on Exception {
      // A PlatformException, or anything else from the plugin: the file is
      // still there, and "Share again" can try once more. Programming
      // mistakes (Error, not Exception) still fail loudly.
      result = ShareStatus.failed;
    }
    if (!ref.mounted) return;
    state = ReportReady(request, report, result);
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

final reportDownloadProvider = NotifierProvider.autoDispose
    .family<ReportDownloadController, ReportDownloadState, ReportSlot>(
      ReportDownloadController.new,
    );
