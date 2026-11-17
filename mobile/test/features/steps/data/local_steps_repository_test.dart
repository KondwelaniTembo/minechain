// LocalStepsRepository on an in-memory database (same schema, no cipher).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

const miner = '3f2b6c1e-0000-4000-8000-000000000101';
const otherMiner = '3f2b6c1e-0000-4000-8000-000000000102';

/// A registration with step id ending in [n], saved at [minute] past 08:00.
NewLocalStep step(int n, {String actor = miner, int minute = 0}) =>
    NewLocalStep(
      stepId: '6f1d2c3a-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      actorId: actor,
      type: 'registration',
      qrCode: 'MC-DEMO-${n.toString().padLeft(6, '0')}',
      mineral: 'gold',
      weightMg: '1500000',
      latitude: '-15.419012',
      longitude: '28.288105',
      capturedAt: '2026-11-17T08:00:00.000Z',
      payload: 'minechain-step/1/registration\nstep_id=...\n',
      signature: 'MEQCIF==',
      keyFingerprint: '4d61912d42cf',
      gpsAccuracyM: 6.5,
      createdAt: DateTime.utc(2026, 11, 17, 8, minute),
    );

String idOf(int n) => step(n).stepId;

final at = DateTime.utc(2026, 11, 17, 9);

void main() {
  late InMemoryLocalDatabase database;
  late LocalStepsRepository repository;

  setUp(() {
    database = InMemoryLocalDatabase();
    repository = LocalStepsRepository(database);
  });
  tearDown(() => database.close());

  group('insert and list', () {
    test('a saved step comes back exactly, queued', () async {
      await repository.insert(step(1));

      final saved = (await repository.listForActor(miner)).single;
      expect(saved.stepId, idOf(1));
      expect(saved.payload, step(1).payload);
      expect(saved.signature, 'MEQCIF==');
      expect(saved.weightMg, '1500000'); // text, as signed
      expect(saved.latitude, '-15.419012');
      expect(saved.gpsAccuracyM, 6.5);
      expect(saved.syncState, SyncState.queued);
      expect(saved.attempts, 0);
      expect(saved.createdAt, DateTime.utc(2026, 11, 17, 8));
    });

    test('the same step id twice: LocalStepConflict, the first kept', () async {
      await repository.insert(step(1));
      await expectLater(
        repository.insert(step(1)),
        throwsA(isA<LocalStepConflict>()),
      );
      expect(await repository.listForActor(miner), hasLength(1));
    });

    test(
      'a row the schema refuses: LocalStepsFailure, no SQLite text',
      () async {
        final bad = NewLocalStep(
          stepId: 'NOT-A-STEP-ID',
          actorId: miner,
          type: 'registration',
          qrCode: 'MC-DEMO-000001',
          mineral: 'gold',
          weightMg: '1',
          latitude: '0.000000',
          longitude: '0.000000',
          capturedAt: '2026-11-17T08:00:00.000Z',
          payload: 'secret payload text',
          signature: 'x',
          keyFingerprint: 'x',
          gpsAccuracyM: null,
          createdAt: at,
        );
        await expectLater(
          repository.insert(bad),
          throwsA(
            isA<LocalStepsFailure>().having(
              (f) => f.toString(),
              'text',
              isNot(contains('secret payload text')),
            ),
          ),
        );
      },
    );

    test('newest first, and only that actor', () async {
      await repository.insert(step(1, minute: 1));
      await repository.insert(step(2, minute: 3));
      await repository.insert(step(3, minute: 2, actor: otherMiner));

      final list = await repository.listForActor(miner);
      expect(list.map((s) => s.stepId), [idOf(2), idOf(1)]);
    });
  });

  group('dueForSync', () {
    test('queued steps, oldest first, this actor only', () async {
      await repository.insert(step(2, minute: 2));
      await repository.insert(step(1, minute: 1));
      await repository.insert(step(3, actor: otherMiner));

      final due = await repository.dueForSync(actorId: miner, now: at);
      expect(due.map((s) => s.stepId), [idOf(1), idOf(2)]);
    });

    test('at most 50', () async {
      for (var n = 1; n <= 55; n++) {
        await repository.insert(step(n, minute: n % 60));
      }
      final due = await repository.dueForSync(actorId: miner, now: at);
      expect(due, hasLength(LocalStepsRepository.batchSize));
    });

    test(
      'a deferred step waits for its time, unless Send was tapped',
      () async {
        await repository.insert(step(1));
        await repository.applyResults([
          StepDeferred(
            idOf(1),
            code: 'CONSIGNMENT_NOT_FOUND',
            message: 'Not yet.',
            nextAttemptAt: at.add(const Duration(minutes: 5)),
          ),
        ], at: at);

        expect(await repository.dueForSync(actorId: miner, now: at), isEmpty);
        expect(
          await repository.dueForSync(
            actorId: miner,
            now: at.add(const Duration(minutes: 5)),
          ),
          hasLength(1),
        );
        expect(
          await repository.dueForSync(
            actorId: miner,
            now: at,
            ignoreBackoff: true,
          ),
          hasLength(1),
        );
      },
    );

    test('synced, flagged and rejected steps are never due', () async {
      for (var n = 1; n <= 3; n++) {
        await repository.insert(step(n));
      }
      await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'passed', transactionId: 't1'),
        StepFlagged(
          idOf(2),
          code: 'GPS_ZONE',
          message: 'Outside every zone.',
          reviewStatus: 'flagged',
          transactionId: 't2',
        ),
        StepRejected(idOf(3), code: 'PAYLOAD_MALFORMED', message: 'Bad.'),
      ], at: at);

      expect(
        await repository.dueForSync(
          actorId: miner,
          now: at,
          ignoreBackoff: true,
        ),
        isEmpty,
      );
    });
  });

  group('applyResults', () {
    Future<LocalStep> only() async =>
        (await repository.listForActor(miner)).single;

    test('synced: state, review status, server id, time', () async {
      await repository.insert(step(1));

      final changed = await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'passed', transactionId: 'tx-1'),
      ], at: at);

      expect(changed, 1);
      final s = await only();
      expect(s.syncState, SyncState.synced);
      expect(s.reviewStatus, 'passed');
      expect(s.serverTransactionId, 'tx-1');
      expect(s.syncedAt, at);
      expect(s.nextAttemptAt, isNull);
    });

    test('flagged keeps the code and the server message', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepFlagged(
          idOf(1),
          code: 'DUPLICATE_CONSIGNMENT',
          message: 'This custody record was already registered.',
          reviewStatus: 'flagged',
          transactionId: 'tx-2',
        ),
      ], at: at);

      final s = await only();
      expect(s.syncState, SyncState.flagged);
      expect(s.lastCode, 'DUPLICATE_CONSIGNMENT');
      expect(s.lastMessage, 'This custody record was already registered.');
    });

    test('rejected is kept, with its code', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepRejected(idOf(1), code: 'STEP_ID_CONFLICT', message: 'Conflict.'),
      ], at: at);

      final s = await only();
      expect(s.syncState, SyncState.rejected);
      expect(s.lastCode, 'STEP_ID_CONFLICT');
      expect(s.payload, step(1).payload); // the evidence is still there
    });

    test('deferred twice: attempts counted, first time kept', () async {
      await repository.insert(step(1));
      final later = at.add(const Duration(hours: 1));

      await repository.applyResults([
        StepDeferred(
          idOf(1),
          code: 'NO_DEVICE_KEY',
          message: 'Register the key.',
          nextAttemptAt: at.add(const Duration(minutes: 1)),
        ),
      ], at: at);
      await repository.applyResults([
        StepDeferred(
          idOf(1),
          code: 'CONSIGNMENT_NOT_FOUND',
          message: 'Not yet.',
          nextAttemptAt: later.add(const Duration(minutes: 2)),
        ),
      ], at: later);

      final s = await only();
      expect(s.syncState, SyncState.deferred);
      expect(s.attempts, 2);
      expect(s.firstDeferredAt, at); // the 72-hour clock starts here
      expect(s.nextAttemptAt, later.add(const Duration(minutes: 2)));
      expect(s.lastCode, 'CONSIGNMENT_NOT_FOUND');
    });

    test('a deferred step that then arrives becomes synced', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepDeferred(
          idOf(1),
          code: 'NO_DEVICE_KEY',
          message: 'Later.',
          nextAttemptAt: at,
        ),
      ], at: at);
      await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'passed', transactionId: 'tx-3'),
      ], at: at);

      expect((await only()).syncState, SyncState.synced);
    });

    test('an answered step never moves back', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'passed', transactionId: 'tx-1'),
      ], at: at);

      final changed = await repository.applyResults([
        StepDeferred(
          idOf(1),
          code: 'STAGE_NOT_READY',
          message: 'Later.',
          nextAttemptAt: at,
        ),
        StepRejected(idOf(1), code: 'PAYLOAD_MALFORMED', message: 'Bad.'),
      ], at: at);

      expect(changed, 0);
      expect((await only()).syncState, SyncState.synced);
    });

    test('an unknown step id changes nothing', () async {
      await repository.insert(step(1));
      final changed = await repository.applyResults([
        StepSynced(idOf(9), reviewStatus: 'passed', transactionId: 'tx-9'),
      ], at: at);
      expect(changed, 0);
    });

    test('several answers in one call', () async {
      await repository.insert(step(1));
      await repository.insert(step(2));

      final changed = await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'passed', transactionId: 'a'),
        StepSynced(idOf(2), reviewStatus: 'passed', transactionId: 'b'),
      ], at: at);

      expect(changed, 2);
    });
  });

  test('storedTime is fixed-width UTC with milliseconds', () {
    expect(
      storedTime(DateTime.utc(2026, 1, 2, 3, 4, 5, 6)),
      '2026-01-02T03:04:05.006Z',
    );
    expect(
      storedTime(DateTime.utc(2026, 11, 17, 9)),
      '2026-11-17T09:00:00.000Z',
    );
  });
}
