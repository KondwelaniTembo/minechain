// The anchoring status as the administrator's "Anchoring" screen shows it
// (anchoring status plan, T2), read from GET /admin/anchoring (docs/api.md,
// "Anchoring administration").
//
// Only what the screen shows is kept: no consignment ids, nonces, preflight
// checks or stored error text. A field the docs promise that is missing or of
// the wrong type makes the whole answer unreadable (null), as for the other
// admin views: a half-read status could say "no problems" when there are some.
// A worker state, tick outcome or step type this app does not know is kept as
// unknown instead, so a newer server still shows the rest.
//
// Plain Dart, no Flutter.

import '../../verification/domain/consignment_view.dart' show StepType;

/// `worker.state`. [unknown]: a state added after this app version.
enum WorkerState {
  running,
  paused,
  backoff,
  stopped,
  notStarted,
  disabled,
  unknown,
}

/// `worker.lastTick.outcome`. [unknown]: as for [WorkerState].
enum TickOutcome {
  idle,
  sent,
  waiting,
  refused,
  paused,
  backoff,
  busy,
  stopped,
  error,
  unknown,
}

/// The worker's last tick.
class LastTick {
  const LastTick({required this.at, required this.outcome, required this.code});

  /// In UTC.
  final DateTime at;
  final TickOutcome outcome;

  /// A refusal or error code, or null.
  final String? code;
}

/// Approved steps by `anchor_status` (flagged steps wait for an officer and
/// are not counted).
class AnchoringCounts {
  const AnchoringCounts({
    required this.pending,
    required this.submitted,
    required this.confirmed,
    required this.failed,
  });

  final int pending;
  final int submitted;
  final int confirmed;
  final int failed;
}

/// A sent step not confirmed yet (`inFlight`).
class InFlightStep {
  const InFlightStep({
    required this.stepId,
    required this.type,
    required this.chainTxHash,
    required this.ageSeconds,
    required this.stuck,
    required this.refusalCode,
  });

  final String stepId;

  /// Null for a step type this app does not know.
  final StepType? type;

  /// The transaction last sent for it.
  final String chainTxHash;

  /// How long ago it was last sent, by the server's clock.
  final int ageSeconds;

  /// Not moved for more than 5 minutes: nothing else is sent until it does.
  final bool stuck;

  /// Why the last resend was refused, or null.
  final String? refusalCode;
}

/// A step that failed to anchor (`failed`, the newest 50).
class FailedStep {
  const FailedStep({
    required this.stepId,
    required this.type,
    required this.code,
    required this.attempts,
    required this.updatedAt,
    required this.retryable,
  });

  final String stepId;
  final StepType? type;

  /// From the stored reason; `UNRECOGNISED` when it is not in the server's
  /// format.
  final String code;
  final int attempts;

  /// In UTC.
  final DateTime updatedAt;

  /// On the server's retry allow-list (a retry through the API may work).
  final bool retryable;
}

/// The approved steps waiting to be sent (`pending`).
class WaitingSteps {
  const WaitingSteps({
    required this.oldestAgeSeconds,
    required this.onHeldConsignments,
    required this.behindFailedStep,
  });

  /// How long the oldest has waited; null when none waits.
  final int? oldestAgeSeconds;

  /// On a consignment held by an open alert: an officer must decide first.
  final int onHeldConsignments;

  /// Behind an earlier failed step of their consignment.
  final int behindFailedStep;
}

/// A held consignment with approved steps waiting (`held`).
class HeldConsignment {
  const HeldConsignment({
    required this.qrCode,
    required this.pendingSteps,
    required this.openAlerts,
  });

  final String qrCode;
  final int pendingSteps;
  final int openAlerts;
}

/// Something that needs attention, in the server's own words.
class AnchoringProblem {
  const AnchoringProblem({required this.code, required this.message});

  final String code;
  final String message;
}

class AnchoringStatus {
  const AnchoringStatus({
    required this.state,
    required this.lastTick,
    required this.recorderAddress,
    required this.contractAddress,
    required this.counts,
    required this.inFlight,
    required this.failed,
    required this.waiting,
    required this.held,
    required this.lastConfirmedAt,
    required this.problems,
  });

  final WorkerState state;

  /// Null until the worker's first tick.
  final LastTick? lastTick;

  /// Public on Sepolia; null when anchoring is switched off.
  final String? recorderAddress;
  final String? contractAddress;

  final AnchoringCounts counts;
  final List<InFlightStep> inFlight;
  final List<FailedStep> failed;
  final WaitingSteps waiting;
  final List<HeldConsignment> held;

  /// The block time of the most recently anchored step, in UTC; null when
  /// none is.
  final DateTime? lastConfirmedAt;

  /// Empty when nothing needs attention.
  final List<AnchoringProblem> problems;

  /// Reads the answer, or null when it is not the documented shape.
  static AnchoringStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final worker = json['worker'];
    if (worker is! Map) return null;
    final state = worker['state'];
    if (state is! String) return null;
    final recorder = worker['recorderAddress'];
    final contract = worker['contractAddress'];
    if (!_isNullableText(recorder) || !_isNullableText(contract)) return null;

    final tickJson = worker['lastTick'];
    final LastTick? tick;
    if (tickJson == null) {
      tick = null;
    } else {
      tick = _lastTick(tickJson);
      if (tick == null) return null;
    }

    final counts = _counts(json['counts']);
    final waiting = _waiting(json['pending']);
    final inFlight = _list(json['inFlight'], _inFlight);
    final failed = _list(json['failed'], _failed);
    final held = _list(json['held'], _held);
    final problems = _list(json['problems'], _problem);
    if (counts == null ||
        waiting == null ||
        inFlight == null ||
        failed == null ||
        held == null ||
        problems == null) {
      return null;
    }

    final lastConfirmedJson = json['lastConfirmed'];
    DateTime? lastConfirmedAt;
    if (lastConfirmedJson != null) {
      if (lastConfirmedJson is! Map) return null;
      lastConfirmedAt = _time(lastConfirmedJson['anchoredAt']);
      if (lastConfirmedAt == null) return null;
    }

    return AnchoringStatus(
      state: _workerState(state),
      lastTick: tick,
      recorderAddress: recorder as String?,
      contractAddress: contract as String?,
      counts: counts,
      inFlight: inFlight,
      failed: failed,
      waiting: waiting,
      held: held,
      lastConfirmedAt: lastConfirmedAt,
      problems: problems,
    );
  }
}

WorkerState _workerState(String state) => switch (state) {
  'running' => WorkerState.running,
  'paused' => WorkerState.paused,
  'backoff' => WorkerState.backoff,
  'stopped' => WorkerState.stopped,
  'not_started' => WorkerState.notStarted,
  'disabled' => WorkerState.disabled,
  _ => WorkerState.unknown,
};

TickOutcome _outcome(String outcome) => TickOutcome.values.firstWhere(
  (o) => o != TickOutcome.unknown && o.name == outcome,
  orElse: () => TickOutcome.unknown,
);

StepType? _stepType(Object? type) =>
    StepType.values.where((t) => t.name == type).firstOrNull;

bool _isNullableText(Object? value) => value == null || value is String;

/// A whole number of at least 0, or null.
int? _count(Object? value) => value is int && value >= 0 ? value : null;

/// An ISO 8601 time in UTC, or null.
DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// Every row read with [read], or null when the value is not a list or one
/// row is unreadable: a row silently left out could hide the problem.
List<T>? _list<T>(Object? json, T? Function(Object?) read) {
  if (json is! List) return null;
  final rows = <T>[];
  for (final row in json) {
    final value = read(row);
    if (value == null) return null;
    rows.add(value);
  }
  return List.unmodifiable(rows);
}

LastTick? _lastTick(Object? json) {
  if (json is! Map) return null;
  final at = _time(json['at']);
  final outcome = json['outcome'];
  final code = json['code'];
  if (at == null || outcome is! String || !_isNullableText(code)) return null;
  return LastTick(at: at, outcome: _outcome(outcome), code: code as String?);
}

AnchoringCounts? _counts(Object? json) {
  if (json is! Map) return null;
  final pending = _count(json['pending']);
  final submitted = _count(json['submitted']);
  final confirmed = _count(json['confirmed']);
  final failed = _count(json['failed']);
  if (pending == null ||
      submitted == null ||
      confirmed == null ||
      failed == null) {
    return null;
  }
  return AnchoringCounts(
    pending: pending,
    submitted: submitted,
    confirmed: confirmed,
    failed: failed,
  );
}

WaitingSteps? _waiting(Object? json) {
  if (json is! Map) return null;
  final oldest = json['oldestAgeSeconds'];
  final onHeld = _count(json['onHeldConsignments']);
  final behind = _count(json['behindFailedStep']);
  if (oldest != null && _count(oldest) == null) return null;
  if (onHeld == null || behind == null) return null;
  return WaitingSteps(
    oldestAgeSeconds: oldest as int?,
    onHeldConsignments: onHeld,
    behindFailedStep: behind,
  );
}

InFlightStep? _inFlight(Object? json) {
  if (json is! Map) return null;
  final stepId = json['stepId'];
  final hash = json['chainTxHash'];
  final age = _count(json['ageSeconds']);
  final stuck = json['stuck'];
  final refusal = json['lastRefusal'];
  if (stepId is! String || hash is! String || age == null || stuck is! bool) {
    return null;
  }
  String? refusalCode;
  if (refusal != null) {
    if (refusal is! Map || refusal['code'] is! String) return null;
    refusalCode = refusal['code'] as String;
  }
  return InFlightStep(
    stepId: stepId,
    type: _stepType(json['type']),
    chainTxHash: hash,
    ageSeconds: age,
    stuck: stuck,
    refusalCode: refusalCode,
  );
}

FailedStep? _failed(Object? json) {
  if (json is! Map) return null;
  final stepId = json['stepId'];
  final code = json['code'];
  final attempts = _count(json['attempts']);
  final updatedAt = _time(json['updatedAt']);
  final retryable = json['retryable'];
  if (stepId is! String ||
      code is! String ||
      attempts == null ||
      updatedAt == null ||
      retryable is! bool) {
    return null;
  }
  return FailedStep(
    stepId: stepId,
    type: _stepType(json['type']),
    code: code,
    attempts: attempts,
    updatedAt: updatedAt,
    retryable: retryable,
  );
}

HeldConsignment? _held(Object? json) {
  if (json is! Map) return null;
  final qrCode = json['qrCode'];
  final pending = _count(json['pendingSteps']);
  final alerts = _count(json['openAlerts']);
  if (qrCode is! String || pending == null || alerts == null) return null;
  return HeldConsignment(
    qrCode: qrCode,
    pendingSteps: pending,
    openAlerts: alerts,
  );
}

AnchoringProblem? _problem(Object? json) {
  if (json is! Map) return null;
  final code = json['code'];
  final message = json['message'];
  if (code is! String || message is! String) return null;
  return AnchoringProblem(code: code, message: message);
}
