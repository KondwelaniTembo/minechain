// SyncService (plan M6, §3): the real service, repository and ApiClient,
// with an in-memory database, a fake server behind MockClient, a fixed
// clock, a stand-in auth controller and a fixed device key state.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/network/network_providers.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';
import 'package:minechain/features/sync/data/sync_api.dart';
import 'package:minechain/features/sync/data/sync_service.dart';
import 'package:minechain/features/sync/domain/sync_report.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart';
import '../../../fakes/fake_sync_server.dart';
import '../../../fakes/flaky_database.dart';

const fingerprint =
    '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53';

late InMemoryLocalDatabase database;
late LocalStepsRepository steps;
late FakeSyncServer server;
late FakeAuthController auth;
late StaticDeviceKeyController deviceKey;
late ProviderContainer container;

/// Before signedInAs's token runs out (2026-11-16 10:00).
late DateTime now;

void start({
  AuthState? signedIn,
  DeviceKeyState key = const DeviceKeyReady(fingerprint),
  DeviceKeyState? keyAfterCheck,
  bool databaseFails = false,
  Duration busyRetryDelay = Duration.zero,
}) {
  auth = FakeAuthController(signedIn ?? signedInAs(Role.miner));
  deviceKey = StaticDeviceKeyController(key, afterCheck: keyAfterCheck);
  container = ProviderContainer.test(
    retry: noRetry,
    overrides: [
      ...fakeOverrides(auth),
      ...server.overrides(),
      deviceKeyControllerProvider.overrideWith(() => deviceKey),
      localStepsRepositoryProvider.overrideWith(
        // A real open failure: the key does not open the file.
        (ref) async => databaseFails ? throw const DatabaseWrongKey() : steps,
      ),
      clockProvider.overrideWithValue(() => now),
      // The one retry after a busy moment: at once, unless a test says.
      syncBusyRetryDelayProvider.overrideWithValue(busyRetryDelay),
    ],
  );
  container.read(syncServiceProvider);
}

/// From here on the service's repository goes through a database that can
/// be told to fail. Call after queueing, so the queueing is not counted.
FlakyLocalDatabase useFlakyDatabase() {
  final flaky = FlakyLocalDatabase(database);
  steps = LocalStepsRepository(flaky);
  return flaky;
}

/// The report of the next run to finish after [previous] (the retry).
Future<SyncReport> reportAfter(SyncReport previous) async {
  for (var i = 0; i < 200; i++) {
    final status = container.read(syncServiceProvider);
    final last = status.last;
    if (!status.running && last != null && !identical(last, previous)) {
      return last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('no further run finished');
}

/// Lets any timer at zero, and the run it starts, go.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

SyncService get service => container.read(syncServiceProvider.notifier);

Future<SyncReport> tap() async => (await service.syncNow(SyncTrigger.tap))!;

// Straight from the in-memory database, never through a flaky one, so
// looking at the rows is not counted as a call of the service.
Future<List<LocalStep>> rows([String actor = minerId]) async =>
    (await LocalStepsRepository(database).listForActor(actor)).reversed
        .toList(); // oldest first

Future<void> queue(int count, {int from = 1, String actor = minerId}) =>
    queueSteps(
      steps,
      count: count,
      from: from,
      actor: actor,
      start: now.subtract(const Duration(hours: 1)),
    );

void main() {
  setUp(() {
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
    server = FakeSyncServer();
    now = DateTime.utc(2026, 11, 16, 9);
  });
  tearDown(() => database.close());

  group('accepted', () {
    test(
      'created: synced, the stored payload and signature sent exactly',
      () async {
        await queue(2);
        start();
        final saved = await rows();

        final report = await tap();

        expect(report.sent, 2);
        expect(report.stop, isNull);
        // Exactly the saved strings, oldest first, and nothing else.
        expect(server.batches.single, [
          for (final step in saved)
            {'payload': step.payload, 'signature': step.signature},
        ]);
        expect(server.authorizations.single, 'Bearer $fakeToken');
        expect(server.timeLimits.single, syncTimeout);
        expect(syncTimeout, const Duration(seconds: 90));

        final after = await rows();
        expect(after.map((s) => s.syncState), everyElement(SyncState.synced));
        expect(after.map((s) => s.serverTransactionId), ['tx-1', 'tx-2']);
        expect(after.first.reviewStatus, 'passed');
        expect(after.first.attempts, 0);
      },
    );

    test('duplicate (already stored): synced, counted as sent', () async {
      await queue(1);
      server.stored[stepIdFor(1)] = 'tx-earlier';
      start();

      final report = await tap();

      expect(report.sent, 1);
      expect((await rows()).single.serverTransactionId, 'tx-earlier');
    });

    test('flagged: under review, with the code and message', () async {
      await queue(1);
      server.outcomes[stepIdFor(1)] = {
        'outcome': 'flagged',
        'code': 'DUPLICATE_CONSIGNMENT',
        'message':
            'This custody record was already registered. Your record was '
            'saved, and an officer will review it.',
        'transactionId': 'tx-9',
        'reviewStatus': 'flagged',
        'alerts': ['duplicate_consignment'],
      };
      start();

      final report = await tap();

      expect(report.underReview, 1);
      expect(report.problems.single.qrCode, qrCodeFor(1));
      expect(report.problems.single.code, 'DUPLICATE_CONSIGNMENT');
      final row = (await rows()).single;
      expect(row.syncState, SyncState.flagged);
      expect(row.lastCode, 'DUPLICATE_CONSIGNMENT');
    });
  });

  group('rejected', () {
    test('kept, never sent again', () async {
      await queue(1);
      server.outcomes[stepIdFor(1)] = {
        'outcome': 'rejected',
        'code': 'STEP_ID_CONFLICT',
        'message': 'A different record with this id was already stored.',
      };
      start();

      final report = await tap();
      expect(report.rejected, 1);
      expect(report.problems.single.rejected, isTrue);
      expect((await rows()).single.syncState, SyncState.rejected);

      // A second tap has nothing to send: a rejection is never retried.
      final again = await tap();
      expect(again.nothingToSend, isTrue);
      expect(server.batches, hasLength(1));
    });
  });

  group('deferred', () {
    test('waits with the backoff; a tap ignores it', () async {
      await queue(1);
      server.outcomes[stepIdFor(1)] = {
        'outcome': 'deferred',
        'code': 'CONSIGNMENT_NOT_FOUND',
        'message': 'Not yet.',
      };
      start();

      expect((await tap()).waiting, 1);
      var row = (await rows()).single;
      expect(row.syncState, SyncState.deferred);
      expect(row.attempts, 1);
      expect(row.nextAttemptAt, now.add(const Duration(minutes: 1)));
      expect(row.firstDeferredAt, now);

      // An automatic run 30 s later: not due yet, nothing sent.
      now = now.add(const Duration(seconds: 30));
      final automatic = await service.syncNow(SyncTrigger.afterSave);
      expect(automatic!.nothingToSend, isTrue);
      expect(server.batches, hasLength(1));

      // A tap sends it anyway; the second deferral waits 2 minutes.
      await tap();
      expect(server.batches, hasLength(2));
      row = (await rows()).single;
      expect(row.attempts, 2);
      expect(row.nextAttemptAt, now.add(const Duration(minutes: 2)));
    });

    test('NO_DEVICE_KEY: the key is sent, then the step once more', () async {
      await queue(1);
      // The first answer only; after the key PUT the server accepts it.
      server.outcomesOnce[stepIdFor(1)] = {
        'outcome': 'deferred',
        'code': 'NO_DEVICE_KEY',
        'message': 'No device key yet.',
      };
      start();

      final report = await tap();

      expect(deviceKey.checks, 1);
      expect(server.batches, hasLength(2));
      expect(report.sent, 1);
      expect((await rows()).single.syncState, SyncState.synced);
    });
  });

  group('whole-request failures change nothing', () {
    test(
      'offline: "not sent", rows still queued, no attempt counted',
      () async {
        await queue(2);
        server.next.add(offline);
        start();

        final report = await tap();

        expect(report.stop, SyncStop.offline);
        final after = await rows();
        expect(after.map((s) => s.syncState), everyElement(SyncState.queued));
        expect(after.map((s) => s.attempts), everyElement(0));
      },
    );

    test('timeout: the 90 s limit passes', () async {
      await queue(1);
      server.next.add(timedOut);
      start();

      final running = tap();
      await pumpEventQueue();
      server.timeLimit.complete();
      final report = await running;

      expect(report.stop, SyncStop.timedOut);
      expect(server.timeLimits.single, const Duration(seconds: 90));
      expect((await rows()).single.syncState, SyncState.queued);
    });

    test('500 part-way: queued; the resend comes back duplicate', () async {
      await queue(2);
      // The server stored the first step, then failed.
      server.stored[stepIdFor(1)] = 'tx-1';
      server.next.add(refusedWith(500, 'INTERNAL_ERROR'));
      start();

      expect((await tap()).stop, SyncStop.serverProblem);
      expect(
        (await rows()).map((s) => s.syncState),
        everyElement(SyncState.queued),
      );

      final again = await tap();
      expect(again.sent, 2);
      expect((await rows()).first.serverTransactionId, 'tx-1');
    });

    test('retry then success: offline first, then sent', () async {
      await queue(1);
      server.next.add(offline);
      start();

      expect((await tap()).stop, SyncStop.offline);
      expect((await tap()).sent, 1);
    });

    test('429 with Retry-After: no automatic run before it', () async {
      await queue(1);
      server.next.add(
        refusedWith(
          429,
          'TOO_MANY_REQUESTS',
          message: 'Too many sync requests. Please wait a few minutes.',
          retryAfter: '300',
        ),
      );
      start();

      final report = await tap();
      expect(report.stop, SyncStop.tooManyRequests);
      expect(
        report.message,
        'Too many sync requests. Please wait a few minutes.',
      );

      now = now.add(const Duration(minutes: 4));
      expect(await service.syncNow(SyncTrigger.afterSave), isNull);
      now = now.add(const Duration(minutes: 2));
      expect((await service.syncNow(SyncTrigger.afterSave))!.sent, 1);
    });

    test('400 VALIDATION_FAILED: an app problem, nothing changed', () async {
      await queue(1);
      server.next.add(refusedWith(400, 'VALIDATION_FAILED'));
      start();
      expect((await tap()).stop, SyncStop.appProblem);
      expect((await rows()).single.syncState, SyncState.queued);
    });
  });

  group('the session', () {
    test('the server says TOKEN_EXPIRED: password needed, work kept', () async {
      await queue(1);
      server.next.add(refusedWith(401, 'TOKEN_EXPIRED'));
      start();
      final refusals = <String>[];
      container.read(sessionEventsProvider).refusals.listen(refusals.add);

      final report = await tap();
      await pumpEventQueue();

      expect(report.stop, SyncStop.needsPassword);
      // The existing re-login path hears of it (F8).
      expect(refusals, ['TOKEN_EXPIRED']);
      expect((await rows()).single.syncState, SyncState.queued);
    });

    test('the token ran out by the clock: nothing is sent', () async {
      await queue(1);
      now = DateTime.utc(2026, 11, 16, 10, 0, 1);
      start();
      expect((await tap()).stop, SyncStop.needsPassword);
      expect(server.batches, isEmpty);
    });

    test('password needed already: nothing is sent', () async {
      await queue(1);
      start(signedIn: SignedInNeedsPassword(userOf(Role.miner)));
      expect((await tap()).stop, SyncStop.needsPassword);
      expect(server.batches, isEmpty);
    });

    test('signed out: nothing is sent', () async {
      await queue(1);
      start(signedIn: const SignedOut());
      expect((await tap()).stop, SyncStop.notSignedIn);
    });
  });

  group('one run at a time', () {
    test('a second trigger joins the running one', () async {
      await queue(2);
      server.hold = Completer<void>();
      start();

      final first = service.syncNow(SyncTrigger.afterSave);
      final second = service.syncNow(SyncTrigger.tap);
      expect(identical(first, second), isTrue);
      await pumpEventQueue();
      expect(container.read(syncServiceProvider).running, isTrue);

      server.hold!.complete();
      final (a, b) = (await first, await second);
      expect(identical(a, b), isTrue);
      expect(server.batches, hasLength(1));
      expect(container.read(syncServiceProvider).running, isFalse);
    });

    test('resume: at most once every 2 minutes', () async {
      start();
      expect(await service.syncNow(SyncTrigger.resume), isNotNull);
      now = now.add(const Duration(minutes: 1));
      expect(await service.syncNow(SyncTrigger.resume), isNull);
      // After a save it runs anyway (approved point 7).
      expect(await service.syncNow(SyncTrigger.afterSave), isNotNull);
      now = now.add(const Duration(minutes: 1, seconds: 1));
      expect(await service.syncNow(SyncTrigger.resume), isNotNull);
    });

    test(
      'a sign-in runs within the 2 minutes, and counts as the latest',
      () async {
        start();
        expect(await service.syncNow(SyncTrigger.resume), isNotNull);
        now = now.add(const Duration(minutes: 1));
        expect(await service.syncNow(SyncTrigger.signIn), isNotNull);
        // A resume just after the sign-in does not send again.
        now = now.add(const Duration(minutes: 1, seconds: 30));
        expect(await service.syncNow(SyncTrigger.resume), isNull);
      },
    );
  });

  group('the password entered again (found on the A57)', () {
    test(
      'the fresh sign-in sends, even within 2 minutes of the start',
      () async {
        await queue(1);
        start(signedIn: SignedInNeedsPassword(userOf(Role.miner)));

        // At start, before the password: an automatic send stops.
        final atStart = await service.syncNow(SyncTrigger.resume);
        expect(atStart!.stop, SyncStop.needsPassword);
        expect(container.read(syncServiceProvider).last, same(atStart));

        // The password is accepted a minute later. The real controller then
        // becomes SignedIn and announces the sign-in, as below.
        now = now.add(const Duration(minutes: 1));
        auth.setState(signedInAs(Role.miner));
        await pumpEventQueue();
        // The stale "enter your password" is gone, before any new send.
        expect(container.read(syncServiceProvider).last, isNull);

        container.read(signedInEventsProvider).report(userOf(Role.miner));
        await pumpEventQueue();

        final last = container.read(syncServiceProvider).last!;
        expect(last.trigger, SyncTrigger.signIn);
        expect(last.stop, isNull);
        expect(last.sent, 1);
        expect(server.batches, hasLength(1));
      },
    );

    test(
      'a stop for another reason is kept when the session returns',
      () async {
        await queue(1);
        server.next.add(offline);
        start();
        final report = await tap();
        expect(report.stop, SyncStop.offline);

        auth.setState(SignedInNeedsPassword(userOf(Role.miner)));
        await pumpEventQueue();
        auth.setState(signedInAs(Role.miner));
        await pumpEventQueue();

        expect(container.read(syncServiceProvider).last, same(report));
      },
    );
  });

  group('when and why', () {
    test('each report has its start time and its trigger', () async {
      await queue(1);
      start();

      final tapped = await tap();
      expect(tapped.trigger, SyncTrigger.tap);
      expect(tapped.startedAt, now);

      now = now.add(const Duration(minutes: 5));
      final saved = await service.syncNow(SyncTrigger.afterSave);
      expect(saved!.trigger, SyncTrigger.afterSave);
      expect(saved.startedAt, now);
    });
  });

  group('which rows', () {
    test('more than 50: batches of 50, oldest first', () async {
      await queue(120);
      start();

      final report = await tap();

      expect(server.batches.map((b) => b.length), [50, 50, 20]);
      expect(
        stepIdOf(server.batches.first.first['payload']! as String),
        stepIdFor(1),
      );
      expect(report.sent, 120);
      expect(container.read(syncServiceProvider).last, same(report));
    });

    test("another user's rows are never sent", () async {
      await queue(1);
      await queue(1, from: 2, actor: otherMinerId);
      start();

      await tap();

      expect(server.batches.single, hasLength(1));
      expect((await rows(otherMinerId)).single.syncState, SyncState.queued);
    });

    test('a result for another step: that row stays queued', () async {
      await queue(2);
      server.resultFor = (index, stepId) => index == 0
          ? {
              'index': 0,
              'stepId': stepIdFor(7),
              'outcome': 'created',
              'transactionId': 'tx-x',
              'reviewStatus': 'passed',
            }
          : null;
      start();

      final report = await tap();

      expect(report.unmatched, 1);
      expect(report.sent, 1);
      final after = await rows();
      expect(after.first.syncState, SyncState.queued);
      expect(after.last.syncState, SyncState.synced);
    });

    test('saved 72 hours ago: sent like any other', () async {
      await queueSteps(
        steps,
        count: 1,
        start: now.subtract(const Duration(hours: 72)),
      );
      start();
      expect((await tap()).sent, 1);
    });

    test('nothing waiting: no request at all', () async {
      start();
      final report = await tap();
      expect(report.nothingToSend, isTrue);
      expect(server.batches, isEmpty);
    });
  });

  group('the key and the database', () {
    test('another phone\'s key: stop before sending', () async {
      await queue(1);
      start(key: const DeviceKeyOtherDevice());
      expect((await tap()).stop, SyncStop.keyOtherDevice);
      expect(server.batches, isEmpty);
    });

    test('unregistered: the key PUT runs first, then the send', () async {
      await queue(1);
      start(
        key: const DeviceKeyUnregistered(fingerprint),
        keyAfterCheck: const DeviceKeyReady(fingerprint),
      );
      expect((await tap()).sent, 1);
      expect(deviceKey.checks, 1);
    });

    test('the database cannot be opened: saved-work problem', () async {
      start(databaseFails: true);
      final report = await tap();
      expect(report.stop, SyncStop.savedWorkProblem);
      // Only the service's own words; never SQLite's.
      expect(report.message, isNull);
      expect(report.retrySoon, isFalse);
    });
  });

  // The API 26 emulator: the send right after a save met another call's
  // lock and said "cannot be opened". Only a real open failure may say that.
  group('a moment\'s problem on the phone', () {
    for (final (name, error) in <(String, Object)>[
      ('the file busy while opening', const DatabaseBusy('key-check')),
      (
        'a query refused as busy',
        const LocalStepsFailure('count-due', busy: true),
      ),
      ('a query refused otherwise', const LocalStepsFailure('count-due')),
      ('not a database error at all', StateError('unexpected')),
    ]) {
      test('$name: phone busy, then one retry sends it', () async {
        await queue(1);
        final flaky = useFlakyDatabase()..failNext(error);
        start();

        final first = (await service.syncNow(SyncTrigger.afterSave))!;
        expect(first.stop, SyncStop.phoneBusy);
        expect(first.stop, isNot(SyncStop.savedWorkProblem));
        expect(first.retrySoon, isTrue);
        expect(first.message, isNull); // no error text ever reaches it
        expect(server.batches, isEmpty);

        final retried = await reportAfter(first);
        expect(retried.stop, isNull);
        expect(retried.sent, 1);
        expect(retried.trigger, SyncTrigger.afterSave);
        expect(server.batches, hasLength(1));
        expect((await rows()).single.syncState, SyncState.synced);
        expect(flaky.failAt, isEmpty);
      });
    }

    test('a busy moment twice: one retry only, then "tap Send now"', () async {
      await queue(1);
      final flaky = useFlakyDatabase()
        ..failAt[1] = const DatabaseBusy('key-check')
        ..failAt[2] = const DatabaseBusy('key-check');
      start();

      final first = (await service.syncNow(SyncTrigger.afterSave))!;
      final second = await reportAfter(first);
      expect(second.stop, SyncStop.phoneBusy);
      expect(second.retrySoon, isFalse);

      await settle();
      expect(flaky.calls, 2); // no third run
      expect(
        identical(container.read(syncServiceProvider).last, second),
        isTrue,
      );
      expect((await rows()).single.syncState, SyncState.queued);
    });

    test('a real open failure during the run: still saved-work problem, '
        'and no retry', () async {
      await queue(1);
      final flaky = useFlakyDatabase()..failNext(const DatabaseWrongKey());
      start();

      final report = (await service.syncNow(SyncTrigger.afterSave))!;
      expect(report.stop, SyncStop.savedWorkProblem);
      expect(report.retrySoon, isFalse);

      await settle();
      expect(flaky.calls, 1);
      expect(
        identical(container.read(syncServiceProvider).last, report),
        isTrue,
      );
    });

    test('busy while writing the answers: rows unchanged, the retry resends '
        'and the server answers duplicate', () async {
      await queue(1);
      // Calls: 1 count, 2 due, 3 apply.
      final flaky = useFlakyDatabase()
        ..failAt[3] = const LocalStepsFailure('apply', busy: true);
      start();

      final first = (await service.syncNow(SyncTrigger.afterSave))!;
      expect(first.stop, SyncStop.phoneBusy);
      expect((await rows()).single.syncState, SyncState.queued);

      final retried = await reportAfter(first);
      expect(retried.stop, isNull);
      expect(retried.sent, 1);
      expect(server.batches, hasLength(2)); // the same step, sent again
      expect((await rows()).single.syncState, SyncState.synced);
      expect(flaky.failAt, isEmpty);
    });

    test('a tap while the retry waits replaces it', () async {
      await queue(1);
      useFlakyDatabase().failNext(const DatabaseBusy('key-check'));
      // A long wait, so only the tap can be what sends.
      start(busyRetryDelay: const Duration(hours: 1));

      final first = (await service.syncNow(SyncTrigger.afterSave))!;
      expect(first.retrySoon, isTrue);
      final tapped = await tap();
      expect(tapped.sent, 1);
      expect(server.batches, hasLength(1));
    });

    test('debug builds log the stop and the error\'s TYPE only', () async {
      final logged = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          logged.add('$message');
      addTearDown(() => debugPrint = original);

      await queue(1);
      // Its text stands for SQLite's, which repeats statements and values.
      useFlakyDatabase().failNext(StateError('SELECT payload, x\'00ff\''));
      start();
      final first = (await service.syncNow(SyncTrigger.afterSave))!;
      await reportAfter(first); // the retry, so nothing runs after the test

      expect(kDebugMode, isTrue); // tests run as debug
      final stops = logged.where((l) => l.contains('MineChain sync stopped'));
      expect(stops, hasLength(1));
      expect(stops.single, contains('phoneBusy'));
      expect(stops.single, contains('StateError'));
      expect(logged.join('\n'), isNot(contains('payload')));
      expect(logged.join('\n'), isNot(contains('00ff')));
    });
  });

  test('the counts follow what the server said', () async {
    await queue(3);
    server.outcomes[stepIdFor(2)] = {
      'outcome': 'flagged',
      'code': 'GPS_ZONE',
      'message': 'Outside every zone.',
      'transactionId': 'tx-8',
      'reviewStatus': 'flagged',
    };
    server.outcomes[stepIdFor(3)] = {
      'outcome': 'rejected',
      'code': 'PAYLOAD_MALFORMED',
      'message': 'Not in the signed format.',
    };
    start();
    await tap();

    final counts = await steps.countsForActor(minerId, now: now);
    // The flagged one is sent to the server too, and part of that count.
    expect(
      (
        counts.waiting,
        counts.sentToServer,
        counts.underReview,
        counts.rejected,
      ),
      (0, 2, 1, 1),
    );
    expect(counts.needsAttention, 1);
  });
}
