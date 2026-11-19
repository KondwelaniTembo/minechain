// The one-line answer at the top of a consignment check: can this record be
// trusted? (plan section 4). One pure function, so the order of the rules is
// tested once here and the screen only draws the result.
//
// Worst first: a single mismatching step makes the whole record suspect,
// whatever the other steps say. "Could not reach the blockchain" is never
// shown as tampering (api.md, "The chain check"), and it outranks "not on the
// blockchain yet" because then the app cannot even tell which steps are on
// it.
//
// Plain Dart, no Flutter.

import 'consignment_view.dart';

enum Verdict {
  /// A step's stored record differs from its signature, its hash or the
  /// blockchain. The server has raised an alert and holds the consignment.
  mismatch,

  /// An open alert holds the consignment (and no step mismatches).
  underReview,

  /// The server could not ask the blockchain this time, for some step.
  chainUnavailable,

  /// At least one step is not confirmed on the blockchain yet.
  notAnchoredYet,

  /// No step is listed for this viewer (every step is flagged or rejected,
  /// and the viewer is not an officer), and nothing holds it.
  nothingToCheck,

  /// Every listed step matches the blockchain.
  verified,
}

Verdict verdictFor(ConsignmentView view) {
  final results = {for (final step in view.steps) step.check};
  if (results.contains(CheckResult.mismatch)) return Verdict.mismatch;
  if (view.held) return Verdict.underReview;
  if (results.contains(CheckResult.chainUnavailable)) {
    return Verdict.chainUnavailable;
  }
  if (results.contains(CheckResult.notAnchoredYet)) {
    return Verdict.notAnchoredYet;
  }
  if (view.steps.isEmpty) return Verdict.nothingToCheck;
  return Verdict.verified;
}
