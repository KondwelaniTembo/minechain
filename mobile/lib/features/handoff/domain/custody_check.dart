// What "Take custody" knows about a bag after the scan (transporter handoff
// plan, Q1 and Q2), and the warnings that follow from it.
//
// The check is advice for the screen only: nothing from it goes into the
// signed payload. The bag is physically in the transporter's hands, and the
// server checks the handoff again when it arrives, so a warning never
// blocks the handoff (Q2, option A). Only the two that mean "something is
// already wrong with this consignment" ask for one extra "Record anyway".
//
// "Record purchase" (buyer purchase plan, Q4) is the same page for the
// licensed buyer, chosen by [CustodyStepKind]. Its rules are stricter,
// because money may change hands: every warning needs "Record anyway"
// (Q3), and the buyer's own accepted purchase is refused outright (Q2).
//
// Plain Dart, no Flutter.

import '../../registration/domain/mineral.dart';
import '../../steps/domain/later_step_payload.dart';
import '../../verification/domain/consignment_view.dart';
import '../../verification/domain/verdict.dart';

/// Which custody step the page records: the transporter's handoff ("Take
/// custody") or the buyer's purchase ("Record purchase").
enum CustodyStepKind {
  handoff(LaterStepType.handoff),
  purchase(LaterStepType.purchase);

  const CustodyStepKind(this.stepType);

  /// The step this page signs, and the type the "already recorded on this
  /// phone" refusal (Q4) looks for.
  final LaterStepType stepType;
}

/// Why the consignment could not be checked. Each is "you can still record
/// it": the step is signed and kept on the phone, and checked when sent.
enum UncheckedReason {
  /// No network at all.
  offline,

  /// A slow or failed answer, or a refusal the screen cannot act on.
  failed,

  /// The session has ended; no request was sent.
  needsPassword,
}

/// The answer to the check, as "Take custody" uses it.
sealed class CustodyCheck {
  const CustodyCheck();

  /// The mineral the server knows, or null when the transporter must choose
  /// it from the custody record (Q1).
  Mineral? get knownMineral => null;
}

/// The server answered with the consignment.
final class CustodyChecked extends CustodyCheck {
  const CustodyChecked(this.view);
  final ConsignmentView view;

  @override
  Mineral get knownMineral => view.mineral;

  @override
  String toString() => 'CustodyChecked()';
}

/// 404 CONSIGNMENT_NOT_FOUND: most likely the miner's registration has not
/// been sent yet. The handoff is still recorded; the server defers it until
/// the registration arrives (api.md, `CONSIGNMENT_NOT_FOUND` deferred).
final class CustodyNotOnServer extends CustodyCheck {
  const CustodyNotOnServer();
}

/// No answer to use; [reason] says why.
final class CustodyUnchecked extends CustodyCheck {
  const CustodyUnchecked(this.reason);
  final UncheckedReason reason;
}

/// A sentence the screen shows about the bag before it is recorded.
enum CustodyWarning {
  /// A step does not match the blockchain; the consignment is held.
  mismatch,

  /// An open alert holds the consignment.
  underReview,

  /// The consignment is already bought.
  alreadyBought,

  /// The server does not know the consignment yet.
  notOnServer,
}

/// The warnings for [check], worst first. A mismatch already says the
/// consignment is held, so "under review" is not added to it.
List<CustodyWarning> custodyWarnings(CustodyCheck check) => switch (check) {
  CustodyChecked(:final view) => [
    if (verdictFor(view) == Verdict.mismatch)
      CustodyWarning.mismatch
    else if (view.held)
      CustodyWarning.underReview,
    if (view.stage == ConsignmentStage.purchased) CustodyWarning.alreadyBought,
  ],
  CustodyNotOnServer() => const [CustodyWarning.notOnServer],
  CustodyUnchecked() => const [],
};

/// Whether [warning] needs one "Record anyway" tap before Save.
///
/// A handoff (Q2 of the handoff plan): only a mismatch and a hold.
/// "Already bought" and "not on the server yet" are notes only.
///
/// A purchase: every warning. A 404 may mean the bag is held or already
/// sold to someone else (buyer purchase Q3), and "already bought" (by
/// someone else, since the buyer's own purchase is refused) would be
/// flagged high by the server.
bool needsRecordAnyway(
  CustodyWarning warning, [
  CustodyStepKind kind = CustodyStepKind.handoff,
]) => switch (kind) {
  CustodyStepKind.handoff =>
    warning == CustodyWarning.mismatch || warning == CustodyWarning.underReview,
  CustodyStepKind.purchase => true,
};

/// When the viewer's own accepted purchase was captured, if the server's
/// answer holds one (buyer purchase Q2): a buyer sees a `purchased`
/// consignment only when it is theirs. The earliest, in the phone's signed
/// time (UTC); null when there is none.
DateTime? viewerPurchasedOn(ConsignmentView view) {
  DateTime? first;
  for (final step in view.steps) {
    if (step.type != StepType.purchase || !step.byYou) continue;
    if (first == null || step.capturedAt.isBefore(first)) {
      first = step.capturedAt;
    }
  }
  return first;
}
