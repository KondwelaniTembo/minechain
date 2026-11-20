// One row of "My consignments" (plan M7, decision Mobile (34)): only what
// the list shows, read by its own query, so the payload, signature, key
// fingerprint and coordinates never leave the database's isolate for it.
//
// Plain Dart with plain fields only, so it can travel back from that
// isolate.

import 'local_step.dart';

/// Where a record stands, in the words "Send my work" uses.
enum StepStatus {
  /// `queued`, or `deferred` for less than [StepCounts.stuckAfter].
  waiting,

  /// `deferred` for [StepCounts.stuckAfter] or more: a person is needed.
  stuck,

  /// Stored on the server, every check passed.
  sent,

  /// Stored on the server, under an officer's review.
  underReview,

  /// Never accepted as it is; kept as evidence.
  rejected,
}

class ConsignmentListItem {
  const ConsignmentListItem({
    required this.stepId,
    required this.qrCode,
    required this.mineral,
    required this.weightMg,
    required this.syncState,
    required this.reviewStatus,
    required this.lastCode,
    required this.lastMessage,
    required this.firstDeferredAt,
    required this.createdAt,
  });

  /// The list's key for the row; never shown.
  final String stepId;
  final String qrCode;

  /// The API's name (`gold`). A registration always has its signed one; a
  /// later step has the unsigned display hint, or none (schema version 2).
  final String? mineral;

  /// Whole milligrams, the signed text.
  final String weightMg;
  final SyncState syncState;
  final String? reviewStatus;
  final String? lastCode;
  final String? lastMessage;
  final DateTime? firstDeferredAt;

  /// When it was saved on this phone (UTC).
  final DateTime createdAt;

  /// The status at [now], by the same rules as the counts on "Send my
  /// work" (`_countsForActor`): flagged, or synced while the server's review
  /// status is still `flagged`, is under review; deferred since
  /// [StepCounts.stuckAfter] or longer is stuck.
  StepStatus statusAt(DateTime now) => switch (syncState) {
    SyncState.queued => StepStatus.waiting,
    SyncState.deferred =>
      firstDeferredAt != null &&
              !firstDeferredAt!.isAfter(now.subtract(StepCounts.stuckAfter))
          ? StepStatus.stuck
          : StepStatus.waiting,
    SyncState.synced =>
      reviewStatus == 'flagged' ? StepStatus.underReview : StepStatus.sent,
    SyncState.flagged => StepStatus.underReview,
    SyncState.rejected => StepStatus.rejected,
  };

  static ConsignmentListItem fromRow(Map<String, Object?> row) {
    final firstDeferred = row['first_deferred_at'] as String?;
    return ConsignmentListItem(
      stepId: row['step_id']! as String,
      qrCode: row['qr_code']! as String,
      mineral: row['mineral'] as String?,
      weightMg: row['weight_mg']! as String,
      syncState: SyncState.values.byName(row['sync_state']! as String),
      reviewStatus: row['review_status'] as String?,
      lastCode: row['last_code'] as String?,
      lastMessage: row['last_message'] as String?,
      firstDeferredAt: firstDeferred == null
          ? null
          : DateTime.parse(firstDeferred),
      createdAt: DateTime.parse(row['created_at']! as String),
    );
  }

  @override
  String toString() => 'ConsignmentListItem(syncState: ${syncState.name})';
}
