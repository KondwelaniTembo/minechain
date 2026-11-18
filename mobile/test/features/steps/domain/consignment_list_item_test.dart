// A record's status on "My consignments": the same rules as the counts on
// "Send my work" (Mobile (34)).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/steps/domain/consignment_list_item.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

final now = DateTime.utc(2026, 11, 18, 12);

ConsignmentListItem item(
  SyncState state, {
  String? reviewStatus,
  DateTime? firstDeferredAt,
}) => ConsignmentListItem(
  stepId: '6f1d2c3a-0000-4000-8000-000000000001',
  qrCode: 'MC-2026-LSK-0001',
  mineral: 'gold',
  weightMg: '1500',
  syncState: state,
  reviewStatus: reviewStatus,
  lastCode: null,
  lastMessage: null,
  firstDeferredAt: firstDeferredAt,
  createdAt: now,
);

void main() {
  test('queued: waiting', () {
    expect(item(SyncState.queued).statusAt(now), StepStatus.waiting);
  });

  test('deferred: waiting until 72 hours, then stuck', () {
    final justUnder = now.subtract(
      StepCounts.stuckAfter - const Duration(seconds: 1),
    );
    final exactly = now.subtract(StepCounts.stuckAfter);
    expect(
      item(SyncState.deferred, firstDeferredAt: justUnder).statusAt(now),
      StepStatus.waiting,
    );
    // The counts' SQL says `first_deferred_at <= now - 72 h`: the same edge.
    expect(
      item(SyncState.deferred, firstDeferredAt: exactly).statusAt(now),
      StepStatus.stuck,
    );
  });

  test('synced: sent, or under review while the server says flagged', () {
    expect(
      item(SyncState.synced, reviewStatus: 'passed').statusAt(now),
      StepStatus.sent,
    );
    expect(
      item(SyncState.synced, reviewStatus: 'flagged').statusAt(now),
      StepStatus.underReview,
    );
  });

  test('flagged: under review; rejected: rejected', () {
    expect(
      item(SyncState.flagged, reviewStatus: 'flagged').statusAt(now),
      StepStatus.underReview,
    );
    expect(item(SyncState.rejected).statusAt(now), StepStatus.rejected);
  });

  test('its text names no field values', () {
    expect(item(SyncState.queued).toString(), isNot(contains('MC-2026')));
  });
}
