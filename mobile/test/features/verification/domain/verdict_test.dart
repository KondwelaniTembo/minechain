// verdictFor: each verdict, and that the worst one wins (plan section 4).

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/verification/domain/consignment_view.dart';
import 'package:minechain/features/verification/domain/verdict.dart';

CheckedStep step(CheckResult check) => CheckedStep(
  id: 's-${check.name}',
  type: StepType.registration,
  byYou: false,
  actor: const StepActor(role: Role.miner, username: null),
  weightMg: '1000',
  location: null,
  zoneName: null,
  capturedAt: DateTime.utc(2026, 11, 19),
  receivedAt: DateTime.utc(2026, 11, 19),
  anchorStatus: AnchorStatus.confirmed,
  chainTxHashShown: true,
  chainTxHash: null,
  check: check,
  mismatchFields: null,
  mismatchReason: null,
  reviewStatus: null,
  alerts: null,
);

ConsignmentView view(List<CheckResult> checks, {bool held = false}) =>
    ConsignmentView(
      id: 'c1',
      qrCode: 'MC-2026-LSK-0001',
      mineral: Mineral.gold,
      stage: ConsignmentStage.inTransit,
      held: held,
      weightsHidden: false,
      steps: [for (final c in checks) step(c)],
    );

void main() {
  const m = CheckResult.match;
  const x = CheckResult.mismatch;
  const n = CheckResult.notAnchoredYet;
  const u = CheckResult.chainUnavailable;

  test('every step matches: verified', () {
    expect(verdictFor(view([m, m, m])), Verdict.verified);
  });

  test('one step not anchored yet', () {
    expect(verdictFor(view([m, n])), Verdict.notAnchoredYet);
  });

  test('the blockchain could not be asked: never tampering', () {
    expect(verdictFor(view([m, u])), Verdict.chainUnavailable);
  });

  test('held with every step matching: under review', () {
    expect(verdictFor(view([m, m], held: true)), Verdict.underReview);
  });

  test('one mismatch among matches', () {
    expect(verdictFor(view([m, x, m])), Verdict.mismatch);
  });

  test('nothing listed and nothing holding it', () {
    expect(verdictFor(view([])), Verdict.nothingToCheck);
  });

  test('nothing listed but held: under review', () {
    expect(verdictFor(view([], held: true)), Verdict.underReview);
  });

  group('the worst wins, whatever the step order', () {
    final cases = <String, (List<CheckResult>, bool, Verdict)>{
      'mismatch beats held': ([m, x], true, Verdict.mismatch),
      'mismatch beats unavailable and pending': (
        [u, n, x],
        false,
        Verdict.mismatch,
      ),
      'held beats unavailable': ([u], true, Verdict.underReview),
      'held beats not anchored': ([n], true, Verdict.underReview),
      'unavailable beats not anchored, either order': (
        [n, u],
        false,
        Verdict.chainUnavailable,
      ),
      'unavailable beats not anchored, other order': (
        [u, n],
        false,
        Verdict.chainUnavailable,
      ),
    };
    cases.forEach((name, c) {
      test(name, () => expect(verdictFor(view(c.$1, held: c.$2)), c.$3));
    });
  });
}
