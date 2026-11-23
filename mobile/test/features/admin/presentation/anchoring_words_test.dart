// The anchoring status in words (anchoring status plan, T3): lengths of
// time, step names, the state's tone, and the singular and plural lines.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/domain/anchoring_status.dart';
import 'package:minechain/features/admin/presentation/anchoring_words.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart'
    show StepType;

import '../../../fakes/fake_anchoring_server.dart';

void main() {
  test('a length of time in its largest whole unit', () {
    expect(AppText.age(1), '1 second');
    expect(AppText.age(59), '59 seconds');
    expect(AppText.age(60), '1 minute');
    expect(AppText.age(600), '10 minutes');
    expect(AppText.age(1200), '20 minutes');
    expect(AppText.age(3599), '59 minutes');
    expect(AppText.age(3600), '1 hour');
    expect(AppText.age(7300), '2 hours');
    expect(AppText.age(86400), '1 day');
    expect(AppText.age(3 * 86400 + 5), '3 days');
  });

  test("a step's name: its type and the first block of its id (Q3)", () {
    expect(stepName(StepType.handoff, anchorStepId(1)), 'Handoff 9d4e5f60');
    expect(
      stepName(StepType.registration, anchorStepId(2)),
      'Registration 9d4e5f60',
    );
    expect(stepName(StepType.purchase, anchorStepId(3)), 'Purchase 9d4e5f60');
    expect(stepName(null, anchorStepId(4)), 'Step 9d4e5f60');
  });

  test('every state has words and a tone; only running is good', () {
    for (final state in WorkerState.values) {
      expect(workerStateWords(state), isNotEmpty);
    }
    expect(workerStateTone(WorkerState.running), StateTone.good);
    expect(workerStateTone(WorkerState.paused), StateTone.warning);
    expect(workerStateTone(WorkerState.backoff), StateTone.warning);
    expect(workerStateTone(WorkerState.stopped), StateTone.bad);
    expect(workerStateTone(WorkerState.notStarted), StateTone.bad);
    expect(workerStateTone(WorkerState.disabled), StateTone.neutral);
    expect(workerStateTone(WorkerState.unknown), StateTone.neutral);
  });

  test('every tick outcome has words', () {
    for (final outcome in TickOutcome.values) {
      expect(tickOutcomeWords(outcome), isNotEmpty);
    }
  });

  test('singular and plural lines', () {
    expect(
      AppText.onHeldConsignments(1),
      '1 on a held consignment: an officer must decide first',
    );
    expect(
      AppText.onHeldConsignments(2),
      '2 on held consignments: an officer must decide first',
    );
    expect(AppText.behindFailedSteps(1), '1 behind a failed step');
    expect(AppText.behindFailedSteps(3), '3 behind failed steps');
    expect(AppText.heldWaiting(1, 1), '1 step waiting, 1 open alert');
    expect(AppText.heldWaiting(2, 3), '2 steps waiting, 3 open alerts');
    expect(AppText.attempts(1), '1 attempt');
    expect(AppText.attempts(3), '3 attempts');
  });
}
