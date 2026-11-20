// LocalStepsRepository on an in-memory database (same schema, no cipher).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/consignment_list_item.dart';
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

  group('listRegistrationsForActor (My consignments)', () {
    test(
      'this actor\'s registrations only, newest first, ties by step id',
      () async {
        await repository.insert(step(1, minute: 1));
        await repository.insert(step(2, minute: 3));
        await repository.insert(step(4, minute: 3)); // same time as 2
        await repository.insert(step(3, minute: 5, actor: otherMiner));
        // A handoff by the same actor: not a consignment they registered.
        await repository.insert(
          NewLocalStep(
            stepId: '6f1d2c3a-0000-4000-8000-000000000005',
            actorId: miner,
            type: 'handoff',
            qrCode: 'MC-DEMO-000009',
            mineral: null,
            weightMg: '1500000',
            latitude: '-15.419012',
            longitude: '28.288105',
            capturedAt: '2026-11-17T08:09:00.000Z',
            payload: 'minechain-step/1/handoff\n',
            signature: 'MEQCIF==',
            keyFingerprint: '4d61912d42cf',
            gpsAccuracyM: null,
            createdAt: DateTime.utc(2026, 11, 17, 8, 9),
          ),
        );

        final list = await repository.listRegistrationsForActor(miner);
        expect(list.map((i) => i.stepId), [idOf(4), idOf(2), idOf(1)]);
        expect(await repository.listRegistrationsForActor('nobody'), isEmpty);
      },
    );

    test('the fields the list shows, and the state the server gave', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepFlagged(
          idOf(1),
          code: 'GPS_ZONE',
          message: 'Outside every zone.',
          reviewStatus: 'flagged',
          transactionId: 'tx-1',
        ),
      ], at: at);

      final item = (await repository.listRegistrationsForActor(miner)).single;
      expect(item.qrCode, 'MC-DEMO-000001');
      expect(item.mineral, 'gold');
      expect(item.weightMg, '1500000'); // the signed text
      expect(item.createdAt, DateTime.utc(2026, 11, 17, 8));
      expect(item.syncState, SyncState.flagged);
      expect(item.lastCode, 'GPS_ZONE');
      expect(item.lastMessage, 'Outside every zone.');
      expect(item.statusAt(at), StepStatus.underReview);
      // No payload, signature, fingerprint or coordinates: the class has no
      // such fields, and its text names none of them.
      expect(item.toString(), isNot(contains('MEQCIF')));
    });

    // Fix E as built: a duplicate answer carries no code or message
    // (api.md), and a row still being sent can only hold an earlier
    // DEFERRAL's code, because a flagged answer takes the row out of the
    // queue for good. Keeping that code would show "This consignment is not
    // ready…" under "under review", so it is cleared.
    test('a duplicate answer that says flagged: under review, and an '
        'earlier deferral\'s message is not shown as the review\'s', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepDeferred(
          idOf(1),
          code: 'STAGE_NOT_READY',
          message: 'This consignment is not ready for this step yet.',
          nextAttemptAt: at,
        ),
      ], at: at);
      // Stored as flagged on the server; that answer was lost; the resend
      // comes back duplicate, with the server's review status.
      await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'flagged', transactionId: 'tx-1'),
      ], at: at);

      final item = (await repository.listRegistrationsForActor(miner)).single;
      expect(item.syncState, SyncState.synced);
      expect(item.reviewStatus, 'flagged');
      expect(item.statusAt(at), StepStatus.underReview);
      expect(item.lastCode, isNull);
      expect(item.lastMessage, isNull);
    });

    test('a flagged step keeps its code and message for good', () async {
      await repository.insert(step(1));
      await repository.applyResults([
        StepFlagged(
          idOf(1),
          code: 'DUPLICATE_CONSIGNMENT',
          message: 'Already registered.',
          reviewStatus: 'flagged',
          transactionId: 'tx-1',
        ),
      ], at: at);
      // Any later answer for it is ignored: it is no longer open.
      final changed = await repository.applyResults([
        StepSynced(idOf(1), reviewStatus: 'flagged', transactionId: 'tx-1'),
      ], at: at);

      expect(changed, 0);
      final item = (await repository.listRegistrationsForActor(miner)).single;
      expect(item.lastCode, 'DUPLICATE_CONSIGNMENT');
      expect(item.lastMessage, 'Already registered.');
    });
  });

  // Transporter handoff T2: the unsigned mineral hint (schema version 2),
  // the list by type, and Q4's "already took custody" lookup.
  group('handoffs', () {
    const transporter = '3f2b6c1e-0000-4000-8000-000000000201';
    const otherTransporter = '3f2b6c1e-0000-4000-8000-000000000202';

    /// A handoff with step id ending in [n], at [minute] past 08:00.
    NewLocalStep handoff(
      int n, {
      String actor = transporter,
      String qrCode = 'MC-DEMO-000001',
      String? hint = 'copper',
      int minute = 0,
    }) => NewLocalStep(
      stepId: '6f1d2c3a-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      actorId: actor,
      type: 'handoff',
      qrCode: qrCode,
      mineral: null,
      mineralHint: hint,
      weightMg: '1495000',
      latitude: '-15.418900',
      longitude: '28.288700',
      capturedAt: '2026-11-17T08:00:00.000Z',
      payload: 'minechain-step/1/handoff\nstep_id=...\n',
      signature: 'MEQCIF==',
      keyFingerprint: '4d61912d42cf',
      gpsAccuracyM: 4.0,
      createdAt: DateTime.utc(2026, 11, 17, 8, minute),
    );

    test('the hint is stored apart from the signed mineral', () async {
      await repository.insert(handoff(101));

      final saved = (await repository.listForActor(transporter)).single;
      expect(saved.type, 'handoff');
      expect(saved.mineral, isNull);
      expect(saved.mineralHint, 'copper');
    });

    test('a registration keeps its signed mineral and no hint', () async {
      await repository.insert(step(1));

      final saved = (await repository.listForActor(miner)).single;
      expect(saved.mineral, 'gold');
      expect(saved.mineralHint, isNull);
    });

    test('a hint on a registration is refused by the schema', () async {
      final bad = NewLocalStep(
        stepId: idOf(1),
        actorId: miner,
        type: 'registration',
        qrCode: 'MC-DEMO-000001',
        mineral: 'gold',
        mineralHint: 'gold',
        weightMg: '1500000',
        latitude: '-15.419012',
        longitude: '28.288105',
        capturedAt: '2026-11-17T08:00:00.000Z',
        payload: 'minechain-step/1/registration\n',
        signature: 'MEQCIF==',
        keyFingerprint: '4d61912d42cf',
        gpsAccuracyM: null,
        createdAt: DateTime.utc(2026, 11, 17, 8),
      );
      await expectLater(
        repository.insert(bad),
        throwsA(isA<LocalStepsFailure>()),
      );
      expect(await repository.listForActor(miner), isEmpty);
    });

    group('listOfTypeForActor', () {
      test('only this actor\'s steps of that type, newest first', () async {
        await repository.insert(handoff(101, minute: 1));
        await repository.insert(handoff(102, minute: 4));
        await repository.insert(handoff(103, actor: otherTransporter));
        // The same account's registration is not a handoff.
        await repository.insert(step(1, actor: transporter, minute: 9));

        final list = await repository.listOfTypeForActor(
          transporter,
          'handoff',
        );
        expect(list.map((i) => i.stepId), [
          handoff(102).stepId,
          handoff(101).stepId,
        ]);
        expect(
          (await repository.listOfTypeForActor(
            transporter,
            'registration',
          )).map((i) => i.stepId),
          [idOf(1)],
        );
        expect(
          await repository.listOfTypeForActor(transporter, 'purchase'),
          isEmpty,
        );
      });

      test('a handoff\'s mineral is its hint; none is null', () async {
        await repository.insert(handoff(101, minute: 2));
        await repository.insert(handoff(102, hint: null, minute: 1));

        final list = await repository.listOfTypeForActor(
          transporter,
          'handoff',
        );
        expect(list.map((i) => i.mineral), ['copper', null]);
        expect(list.first.weightMg, '1495000');
      });

      test('listRegistrationsForActor is the registration list', () async {
        await repository.insert(step(1));
        await repository.insert(handoff(101, actor: miner));
        expect(
          (await repository.listRegistrationsForActor(miner))
              .map((i) => i.stepId),
          [idOf(1)],
        );
      });
    });

    group('handedOffOn (Q4)', () {
      test('never: null', () async {
        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          isNull,
        );
      });

      test('the earliest handoff of that code by that account', () async {
        await repository.insert(handoff(101, minute: 7));
        await repository.insert(handoff(102, minute: 3));
        await repository.insert(handoff(103, qrCode: 'MC-DEMO-000002'));

        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          DateTime.utc(2026, 11, 17, 8, 3),
        );
      });

      test('another account\'s handoff does not count', () async {
        await repository.insert(handoff(101, actor: otherTransporter));
        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          isNull,
        );
      });

      test('a registration of the code does not count', () async {
        await repository.insert(step(1, actor: transporter));
        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          isNull,
        );
      });

      test('a rejected handoff does not count; a flagged one does', () async {
        await repository.insert(handoff(101, minute: 1));
        await repository.applyResults([
          StepRejected(
            handoff(101).stepId,
            code: 'SIGNATURE_INVALID',
            message: 'x',
          ),
        ], at: at);
        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          isNull,
        );

        await repository.insert(handoff(102, minute: 5));
        await repository.applyResults([
          StepFlagged(
            handoff(102).stepId,
            code: 'QUANTITY_DISCREPANCY',
            message: 'x',
            reviewStatus: 'flagged',
            transactionId: 'tx-2',
          ),
        ], at: at);
        expect(
          await repository.handedOffOn('MC-DEMO-000001', transporter),
          DateTime.utc(2026, 11, 17, 8, 5),
        );
      });

      test('the code is matched exactly, case included', () async {
        await repository.insert(handoff(101));
        expect(
          await repository.handedOffOn('mc-demo-000001', transporter),
          isNull,
        );
      });
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
