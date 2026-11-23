// AnchoringStatus.fromJson (anchoring status plan, T2): api.md's example
// read in full, every state and outcome in words the screen can use, the
// nulls the docs allow, and any answer that is not the documented shape read
// as unreadable rather than half-shown.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/admin/domain/anchoring_status.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart'
    show StepType;

import '../../../fakes/fake_anchoring_server.dart';

void main() {
  AnchoringStatus read(Map<String, Object?> json) =>
      AnchoringStatus.fromJson(json)!;

  group("api.md's example (a step stuck behind a fee above the cap)", () {
    final status = read(stuckExampleJson());

    test('the worker', () {
      expect(status.state, WorkerState.running);
      expect(status.lastTick!.outcome, TickOutcome.waiting);
      expect(status.lastTick!.at, DateTime.utc(2026, 11, 12, 9, 59, 45));
      expect(status.lastTick!.code, isNull);
      expect(status.recorderAddress, fakeRecorder);
      expect(status.contractAddress, fakeContract);
    });

    test('the counts and the waiting steps', () {
      expect(status.counts.pending, 2);
      expect(status.counts.submitted, 1);
      expect(status.counts.confirmed, 41);
      expect(status.counts.failed, 0);
      expect(status.waiting.oldestAgeSeconds, 1200);
      expect(status.waiting.onHeldConsignments, 0);
      expect(status.waiting.behindFailedStep, 0);
    });

    test('the stuck step', () {
      final step = status.inFlight.single;
      expect(step.stepId, anchorStepId(1));
      expect(step.type, StepType.handoff);
      expect(step.chainTxHash, fakeTxHash);
      expect(step.ageSeconds, 600);
      expect(step.stuck, isTrue);
      expect(step.refusalCode, 'FEE_TOO_HIGH');
    });

    test('the problem and the last anchored step', () {
      expect(status.problems.single.code, 'STUCK_SUBMITTED');
      expect(status.problems.single.message, startsWith('A sent step'));
      expect(status.lastConfirmedAt, DateTime.utc(2026, 11, 12, 9, 49, 36));
      expect(status.failed, isEmpty);
      expect(status.held, isEmpty);
    });
  });

  test('a healthy worker: nothing waiting, no problems', () {
    final status = read(anchoringStatusJson());

    expect(status.problems, isEmpty);
    expect(status.inFlight, isEmpty);
    expect(status.waiting.oldestAgeSeconds, isNull);
    expect(status.lastTick!.outcome, TickOutcome.idle);
  });

  test('switched off: no tick, no addresses, nothing anchored yet', () {
    final status = read(
      anchoringStatusJson(
        state: 'disabled',
        lastTick: null,
        recorderAddress: null,
        contractAddress: null,
        lastConfirmedAt: null,
      ),
    );

    expect(status.state, WorkerState.disabled);
    expect(status.lastTick, isNull);
    expect(status.recorderAddress, isNull);
    expect(status.contractAddress, isNull);
    expect(status.lastConfirmedAt, isNull);
  });

  group('every worker state', () {
    const states = {
      'running': WorkerState.running,
      'paused': WorkerState.paused,
      'backoff': WorkerState.backoff,
      'stopped': WorkerState.stopped,
      'not_started': WorkerState.notStarted,
      'disabled': WorkerState.disabled,
      // A state added to the server later: the rest still shows.
      'sleeping': WorkerState.unknown,
    };
    for (final MapEntry(key: name, value: state) in states.entries) {
      test(name, () {
        expect(read(anchoringStatusJson(state: name)).state, state);
      });
    }
  });

  group('every tick outcome', () {
    const outcomes = [
      'idle',
      'sent',
      'waiting',
      'refused',
      'paused',
      'backoff',
      'busy',
      'stopped',
      'error',
    ];
    for (final name in outcomes) {
      test(name, () {
        final tick = read(
          anchoringStatusJson(
            lastTick: {
              'at': '2026-11-23T00:41:00.000Z',
              'outcome': name,
              'code': name == 'error' ? 'INTERNAL_ERROR' : null,
              'stepId': null,
            },
          ),
        ).lastTick!;
        expect(tick.outcome.name, name);
      });
    }

    test('an outcome this app does not know', () {
      final tick = read(
        anchoringStatusJson(
          lastTick: {
            'at': '2026-11-23T00:41:00.000Z',
            'outcome': 'dreaming',
            'code': null,
            'stepId': null,
          },
        ),
      ).lastTick!;
      expect(tick.outcome, TickOutcome.unknown);
    });
  });

  test('failed and held rows', () {
    final status = read(
      anchoringStatusJson(
        counts: const {
          'pending': 3,
          'submitted': 0,
          'confirmed': 41,
          'failed': 2,
        },
        failed: [
          failedJson(4),
          failedJson(5, code: 'UNRECOGNISED', retryable: false, attempts: 1),
        ],
        held: [heldJson('MC-2026-LSK-0001', pendingSteps: 2, openAlerts: 3)],
        oldestAgeSeconds: 90,
        onHeldConsignments: 2,
        behindFailedStep: 1,
      ),
    );

    final first = status.failed.first;
    expect(first.stepId, anchorStepId(4));
    expect(first.type, StepType.registration);
    expect(first.code, 'RPC_UNAVAILABLE');
    expect(first.attempts, 3);
    expect(first.updatedAt, DateTime.utc(2026, 11, 22, 21));
    expect(first.retryable, isTrue);
    expect(status.failed.last.retryable, isFalse);

    final held = status.held.single;
    expect(held.qrCode, 'MC-2026-LSK-0001');
    expect(held.pendingSteps, 2);
    expect(held.openAlerts, 3);
    expect(status.waiting.onHeldConsignments, 2);
    expect(status.waiting.behindFailedStep, 1);
  });

  test('a step type this app does not know is kept, with no type', () {
    final status = read(
      anchoringStatusJson(inFlight: [inFlightJson(1, type: 'export')]),
    );
    expect(status.inFlight.single.type, isNull);
  });

  test('a sent step with no refusal', () {
    final status = read(
      anchoringStatusJson(
        inFlight: [inFlightJson(1, stuck: false, refusalCode: null)],
      ),
    );
    expect(status.inFlight.single.refusalCode, isNull);
    expect(status.inFlight.single.stuck, isFalse);
  });

  group('not the documented shape: unreadable, never half-read', () {
    final cases = <String, Map<String, Object?> Function()>{
      'no worker': () => anchoringStatusJson()..remove('worker'),
      'a worker state that is not text': () =>
          anchoringStatusJson()..['worker'] = {'state': 3},
      'a count below 0': () => anchoringStatusJson(
        counts: const {
          'pending': -1,
          'submitted': 0,
          'confirmed': 0,
          'failed': 0,
        },
      ),
      'a count as text': () => anchoringStatusJson(
        counts: const {
          'pending': '2',
          'submitted': 0,
          'confirmed': 0,
          'failed': 0,
        },
      ),
      'inFlight not a list': () =>
          anchoringStatusJson()..['inFlight'] = {'stepId': 'x'},
      'a failed row without its code': () =>
          anchoringStatusJson(failed: [failedJson(4)..remove('code')]),
      'a held row without its QR code': () =>
          anchoringStatusJson(held: [heldJson('x')..remove('qrCode')]),
      'a problem whose message is not text': () => anchoringStatusJson(
        problems: const [
          {'code': 'FAILED_STEPS', 'message': 7},
        ],
      ),
      'lastConfirmed without its time': () =>
          anchoringStatusJson()..['lastConfirmed'] = {'stepId': 'x'},
      'a tick with a time that is not a time': () => anchoringStatusJson(
        lastTick: const {'at': 'soon', 'outcome': 'idle', 'code': null},
      ),
      'no pending summary': () => anchoringStatusJson()..remove('pending'),
    };
    for (final MapEntry(key: name, value: json) in cases.entries) {
      test(name, () => expect(AnchoringStatus.fromJson(json()), isNull));
    }

    test('not a map at all', () {
      expect(AnchoringStatus.fromJson(const [1, 2]), isNull);
      expect(AnchoringStatus.fromJson(null), isNull);
    });
  });
}
