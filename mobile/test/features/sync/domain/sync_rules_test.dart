// Reading one sync result, and the backoff (plan §3).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/steps/domain/local_step.dart';
import 'package:minechain/features/sync/domain/sync_rules.dart';

const stepId = '6f1d2c3a-0000-4000-8000-000000000001';
final now = DateTime.utc(2026, 11, 16, 9);

LocalStep sentStep({int attempts = 0}) => LocalStep.fromRow({
  'step_id': stepId,
  'actor_id': '3f2b6c1e-0000-4000-8000-000000000001',
  'type': 'registration',
  'qr_code': 'MC-2026-LSK-0001',
  'mineral': 'gold',
  'weight_mg': '1500',
  'latitude': '-15.419012',
  'longitude': '28.288105',
  'captured_at': '2026-11-16T08:00:00.000Z',
  'payload': 'minechain-step/1/registration\n',
  'signature': 'MEUCIQFAKE==',
  'key_fingerprint': 'f' * 64,
  'gps_accuracy_m': 6.0,
  'sync_state': attempts == 0 ? 'queued' : 'deferred',
  'review_status': null,
  'server_transaction_id': null,
  'last_code': null,
  'last_message': null,
  'attempts': attempts,
  'next_attempt_at': null,
  'first_deferred_at': null,
  'synced_at': null,
  'created_at': '2026-11-16T08:00:01.000Z',
});

StepSyncUpdate? read(Map<String, Object?> result, {int attempts = 0}) =>
    updateFromResult(
      {'index': 0, 'stepId': stepId, ...result},
      index: 0,
      sent: sentStep(attempts: attempts),
      now: now,
    );

void main() {
  group('backoff: 1, 2, 4, 8, 16, 32 minutes, then hourly', () {
    for (final (deferrals, minutes) in [
      (1, 1),
      (2, 2),
      (3, 4),
      (4, 8),
      (5, 16),
      (6, 32),
      (7, 60),
      (50, 60),
    ]) {
      test('deferral $deferrals: $minutes min', () {
        expect(deferredBackoff(deferrals), Duration(minutes: minutes));
      });
    }
  });

  test('created: synced, with the transaction and review status', () {
    final update = read({
      'outcome': 'created',
      'transactionId': 'tx-1',
      'reviewStatus': 'passed',
    });
    expect(update, isA<StepSynced>());
    expect((update! as StepSynced).transactionId, 'tx-1');
  });

  test('duplicate: the same as created', () {
    expect(
      read({
        'outcome': 'duplicate',
        'transactionId': 'tx-1',
        'reviewStatus': 'passed',
      }),
      isA<StepSynced>(),
    );
  });

  test('flagged: the code and the message as given', () {
    final update =
        read({
              'outcome': 'flagged',
              'code': 'DUPLICATE_CONSIGNMENT',
              'message': 'This custody record was already registered.',
              'transactionId': 'tx-2',
              'reviewStatus': 'flagged',
              'alerts': ['duplicate_consignment'],
            })!
            as StepFlagged;
    expect(update.code, 'DUPLICATE_CONSIGNMENT');
    expect(update.message, 'This custody record was already registered.');
  });

  test('rejected with stepId null: matched by its place', () {
    final update = updateFromResult(
      {
        'index': 0,
        'stepId': null,
        'outcome': 'rejected',
        'code': 'PAYLOAD_MALFORMED',
        'message': 'Not in the signed format.',
      },
      index: 0,
      sent: sentStep(),
      now: now,
    );
    expect(update, isA<StepRejected>());
  });

  test('deferred: due again after the backoff for its attempt', () {
    final update =
        read({
              'outcome': 'deferred',
              'code': 'CONSIGNMENT_NOT_FOUND',
              'message': 'Not yet.',
            }, attempts: 2)!
            as StepDeferred;
    // The third deferral: 4 minutes.
    expect(update.nextAttemptAt, now.add(const Duration(minutes: 4)));
    expect(isNoDeviceKey(update), isFalse);
  });

  test('deferred NO_DEVICE_KEY is recognised', () {
    final update = read({
      'outcome': 'deferred',
      'code': 'NO_DEVICE_KEY',
      'message': 'No key yet.',
    })!;
    expect(isNoDeviceKey(update), isTrue);
  });

  group('not usable: the row stays as it was', () {
    for (final (name, result) in <(String, Map<String, Object?>)>[
      (
        'another step id',
        {
          'index': 0,
          'stepId': '6f1d2c3a-0000-4000-8000-000000000002',
          'outcome': 'created',
          'transactionId': 'tx-1',
          'reviewStatus': 'passed',
        },
      ),
      (
        'another index',
        {
          'index': 1,
          'stepId': stepId,
          'outcome': 'created',
          'transactionId': 'tx-1',
          'reviewStatus': 'passed',
        },
      ),
      (
        'an unknown outcome',
        {'index': 0, 'stepId': stepId, 'outcome': 'accepted'},
      ),
      (
        'created without a transaction id',
        {
          'index': 0,
          'stepId': stepId,
          'outcome': 'created',
          'reviewStatus': 'passed',
        },
      ),
      (
        'flagged without a code',
        {
          'index': 0,
          'stepId': stepId,
          'outcome': 'flagged',
          'transactionId': 'tx-1',
          'reviewStatus': 'flagged',
        },
      ),
      (
        'deferred with stepId null',
        {
          'index': 0,
          'stepId': null,
          'outcome': 'deferred',
          'code': 'STAGE_NOT_READY',
        },
      ),
    ]) {
      test(name, () {
        expect(
          updateFromResult(result, index: 0, sent: sentStep(), now: now),
          isNull,
        );
      });
    }

    test('not a map', () {
      expect(
        updateFromResult('created', index: 0, sent: sentStep(), now: now),
        isNull,
      );
    });
  });
}
