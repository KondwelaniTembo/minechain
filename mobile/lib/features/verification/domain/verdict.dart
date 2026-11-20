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
  /// and the viewer is not an officer, or every step listed for an officer
  /// is rejected), and nothing holds it.
  nothingToCheck,

  /// Every listed step that is not rejected matches the blockchain.
  verified,
}

Verdict verdictFor(ConsignmentView view) {
  // A mismatch on any listed step counts, a rejected one included: a stored
  // record that no longer matches its signature is tampering either way.
  if (view.steps.any((s) => s.check == CheckResult.mismatch)) {
    return Verdict.mismatch;
  }
  if (view.held) return Verdict.underReview;
  // A rejected step (listed for officers only) is never sent to the
  // blockchain, so counting it would leave "not on the blockchain yet" on
  // the page for ever. Without it, an officer gets the same verdict as
  // everyone else, who is never shown the step (T5 on the A57, 0008).
  final accepted = view.steps.where(
    (s) => s.reviewStatus != ReviewStatus.rejected,
  );
  final results = {for (final step in accepted) step.check};
  if (results.contains(CheckResult.chainUnavailable)) {
    return Verdict.chainUnavailable;
  }
  if (results.contains(CheckResult.notAnchoredYet)) {
    return Verdict.notAnchoredYet;
  }
  if (accepted.isEmpty) return Verdict.nothingToCheck;
  return Verdict.verified;
}
