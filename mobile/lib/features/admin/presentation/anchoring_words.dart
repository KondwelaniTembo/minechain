// The anchoring status in the screen's words (anchoring status plan, T3).
// The sentences live in AppText; this file only chooses between them.

import '../../../core/text/app_text.dart';
import '../../verification/domain/consignment_view.dart' show StepType;
import '../domain/anchoring_status.dart';

String workerStateWords(WorkerState state) => switch (state) {
  WorkerState.running => AppText.workerRunning,
  WorkerState.paused => AppText.workerPaused,
  WorkerState.backoff => AppText.workerBackoff,
  WorkerState.stopped => AppText.workerStopped,
  WorkerState.notStarted => AppText.workerNotStarted,
  WorkerState.disabled => AppText.workerDisabled,
  WorkerState.unknown => AppText.workerUnknown,
};

/// How the state card looks: fine, needs watching, or needs a person.
enum StateTone { good, warning, bad, neutral }

StateTone workerStateTone(WorkerState state) => switch (state) {
  WorkerState.running => StateTone.good,
  WorkerState.paused || WorkerState.backoff => StateTone.warning,
  WorkerState.stopped || WorkerState.notStarted => StateTone.bad,
  WorkerState.disabled || WorkerState.unknown => StateTone.neutral,
};

String tickOutcomeWords(TickOutcome outcome) => switch (outcome) {
  TickOutcome.idle => AppText.tickIdle,
  TickOutcome.sent => AppText.tickSent,
  TickOutcome.waiting => AppText.tickWaiting,
  TickOutcome.refused => AppText.tickRefused,
  TickOutcome.paused => AppText.tickPaused,
  TickOutcome.backoff => AppText.tickBackoff,
  TickOutcome.busy => AppText.tickBusy,
  TickOutcome.stopped => AppText.tickStopped,
  TickOutcome.error => AppText.tickError,
  TickOutcome.unknown => AppText.tickUnknown,
};

/// "Handoff 9d4e5f60": the step's type and the first block of its id, enough
/// to find it in a report or ask about it (Q3).
String stepName(StepType? type, String stepId) {
  final word = switch (type) {
    StepType.registration => AppText.stepRegistration,
    StepType.handoff => AppText.stepHandoff,
    StepType.purchase => AppText.stepPurchase,
    null => AppText.stepOfUnknownType,
  };
  final shortId = stepId.split('-').first;
  return AppText.stepAndId(word, shortId);
}
