// "Check a consignment", T5: what each viewer sees on the result page. The
// fixtures start from the officer's full step and are cut down by
// stepFor(), column by column from api.md's "What each viewer sees", so a
// test here fails if the page draws a field the server would not send, or
// misses one it does.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/verification/domain/verdict.dart';
import 'package:minechain/features/verification/presentation/check_result_view.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_registration.dart' show FakeQrScanner;
import 'check_page_helpers.dart';

final Map<String, Object?> registration = checkedStepJson();
final Map<String, Object?> handoff = checkedStepJson(
  type: 'handoff',
  role: 'transporter',
  n: 2,
);
final Map<String, Object?> purchase = checkedStepJson(
  type: 'purchase',
  role: 'buyer',
  n: 3,
);

Map<String, Object?> alert(int n, String status) => {
  'id': 'a1b2c3d4-0000-4000-8000-${n.toString().padLeft(12, '0')}',
  'type': 'quantity_discrepancy',
  'status': status,
};

/// What api.md says each viewer gets, as the lines the page draws.
typedef Expected = ({
  bool weight,
  bool location,
  bool username,
  bool hash,
  bool officerDetails,
  bool weighFirst,
});

const Map<Viewer, Expected> table = {
  Viewer.officer: (
    weight: true,
    location: true,
    username: true,
    hash: true,
    officerDetails: true,
    weighFirst: false,
  ),
  Viewer.owningBuyer: (
    weight: true,
    location: true,
    username: true,
    hash: true,
    officerDetails: false,
    weighFirst: false,
  ),
  Viewer.otherBuyer: (
    weight: true,
    location: false,
    username: true,
    hash: true,
    officerDetails: false,
    weighFirst: false,
  ),
  Viewer.transporterHandedOff: (
    weight: true,
    location: false,
    username: false,
    hash: true,
    officerDetails: false,
    weighFirst: false,
  ),
  Viewer.blindTransporter: (
    weight: false,
    location: false,
    username: false,
    hash: false,
    officerDetails: false,
    weighFirst: true,
  ),
};

/// The answer each viewer can really get: the owning buyer only after their
/// purchase, any other buyer only in transit.
Map<String, Object?> typicalAnswer(Viewer viewer) =>
    viewer == Viewer.owningBuyer
    ? answerFor(viewer, [
        registration,
        handoff,
        purchase..['byYou'] = true,
      ], stage: 'purchased')
    : answerFor(viewer, [registration, handoff]);

Matcher shown(bool yes, int count) => yes ? findsNWidgets(count) : findsNothing;

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
    purchase['byYou'] = false;
  });

  group('each viewer, as api.md\'s table says', () {
    table.forEach((viewer, expected) {
      testWidgets(viewer.name, (tester) async {
        final answer = typicalAnswer(viewer);
        final steps = (answer['steps']! as List).length;
        await showAnswer(tester, answer, role: viewer.role);

        // Every step matches and is confirmed: verified for everyone, the
        // blind transporter too (the check needs no weight on the phone).
        expect(find.text(AppText.verdictVerified), findsOneWidget);
        expect(find.byType(Card), findsNWidgets(steps));

        expect(
          find.text(AppText.weightLine('1500 g')),
          shown(expected.weight, steps),
        );
        expect(
          find.text(AppText.locationLine('-15.419012', '28.288105')),
          shown(expected.location, steps),
        );
        expect(
          find.text(AppText.registeredBy('miner demo_miner_1')),
          shown(expected.username, 1),
        );
        expect(
          find.text(AppText.registeredBy('a miner')),
          shown(!expected.username, 1),
        );
        expect(find.byType(SelectableText), shown(expected.hash, steps));
        expect(
          find.text(AppText.reviewPassed),
          shown(expected.officerDetails, steps),
        );
        expect(
          find.text(AppText.alertsLine(0, 0)),
          shown(expected.officerDetails, steps),
        );
        expect(find.text(AppText.weighFirst), shown(expected.weighFirst, 1));

        // Never shown to anyone: the hash is absent, not "not sent yet".
        expect(find.text(AppText.notSentYet), findsNothing);
        // The weight is shown in its unit, never as the raw milligrams.
        expect(find.textContaining('1500000'), findsNothing);
      });
    });

    testWidgets('owning buyer: their own purchase says "you"', (tester) async {
      await showAnswer(
        tester,
        typicalAnswer(Viewer.owningBuyer),
        role: Viewer.owningBuyer.role,
      );
      expect(find.text(AppText.boughtBy(AppText.you)), findsOneWidget);
    });
  });

  group('blind transporter', () {
    testWidgets('"weigh it first" sits with the consignment, before the '
        'steps', (tester) async {
      await showAnswer(
        tester,
        answerFor(Viewer.blindTransporter, [registration]),
        role: Viewer.blindTransporter.role,
      );
      final line = tester.getTopLeft(find.text(AppText.weighFirst)).dy;
      expect(line, greaterThan(tester.getTopLeft(find.text(knownQrCode)).dy));
      expect(line, lessThan(tester.getTopLeft(find.byType(Card)).dy));
    });

    testWidgets('a step not anchored yet: no "not sent yet" either', (
      tester,
    ) async {
      final pending = checkedStepJson(
        type: 'handoff',
        role: 'transporter',
        n: 2,
        check: 'not_anchored_yet',
      )..['anchor'] = {'status': 'pending', 'chainTxHash': null};
      await showAnswer(
        tester,
        answerFor(Viewer.blindTransporter, [registration, pending]),
        role: Viewer.blindTransporter.role,
      );
      expect(find.text(verdictText(Verdict.notAnchoredYet)), findsOneWidget);
      expect(find.text(AppText.notSentYet), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  // Added after the A57 check of 20 Nov: a transporter scanned a consignment
  // whose registration is under review and saw "Under review", "weigh it
  // first" and nothing else.
  group('held with no step listed', () {
    testWidgets('blind transporter: says the steps are hidden, and does not '
        'ask them to weigh', (tester) async {
      await showAnswer(
        tester,
        answerFor(Viewer.blindTransporter, [], stage: 'registered', held: true),
        role: Viewer.blindTransporter.role,
      );
      expect(find.text(verdictText(Verdict.underReview)), findsOneWidget);
      expect(find.text(AppText.stepsHiddenWhileHeld), findsOneWidget);
      expect(find.text(AppText.weighFirst), findsNothing);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('held with steps listed: no "hidden" line, and still no '
        '"weigh it first"', (tester) async {
      await showAnswer(
        tester,
        answerFor(Viewer.blindTransporter, [registration], held: true),
        role: Viewer.blindTransporter.role,
      );
      expect(find.text(AppText.stepsHiddenWhileHeld), findsNothing);
      expect(find.text(AppText.weighFirst), findsNothing);
      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('no step and not held ("nothing to check"): no "hidden" '
        'line', (tester) async {
      await showAnswer(
        tester,
        answerFor(Viewer.otherBuyer, [], stage: 'in_transit'),
      );
      expect(find.text(verdictText(Verdict.nothingToCheck)), findsOneWidget);
      expect(find.text(AppText.stepsHiddenWhileHeld), findsNothing);
    });
  });

  group('officer', () {
    testWidgets('flagged and rejected steps are listed, with their review '
        'status and alerts', (tester) async {
      final flagged =
          checkedStepJson(
              type: 'handoff',
              role: 'transporter',
              n: 2,
              check: 'not_anchored_yet',
            )
            ..['anchor'] = {'status': 'pending', 'chainTxHash': null}
            ..['reviewStatus'] = 'flagged'
            ..['alerts'] = [alert(1, 'open')];
      final rejected =
          checkedStepJson(
              type: 'handoff',
              role: 'transporter',
              n: 3,
              check: 'not_anchored_yet',
            )
            ..['anchor'] = {'status': 'pending', 'chainTxHash': null}
            ..['reviewStatus'] = 'rejected'
            ..['alerts'] = [alert(2, 'reviewed'), alert(3, 'dismissed')];
      final cleared =
          checkedStepJson(type: 'handoff', role: 'transporter', n: 4)
            ..['reviewStatus'] = 'cleared'
            ..['alerts'] = [alert(4, 'dismissed')];

      await showAnswer(
        tester,
        answerFor(Viewer.officer, [
          registration,
          flagged,
          rejected,
          cleared,
        ], held: true),
        role: Viewer.officer.role,
      );

      expect(find.text(verdictText(Verdict.underReview)), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(4));
      expect(find.text(AppText.reviewPassed), findsOneWidget);
      expect(find.text(AppText.reviewFlagged), findsOneWidget);
      expect(find.text(AppText.reviewRejected), findsOneWidget);
      expect(find.text(AppText.reviewCleared), findsOneWidget);
      expect(find.text(AppText.alertsLine(0, 0)), findsOneWidget);
      expect(find.text(AppText.alertsLine(1, 1)), findsOneWidget);
      expect(find.text(AppText.alertsLine(2, 0)), findsOneWidget);
      expect(find.text(AppText.alertsLine(1, 0)), findsOneWidget);
      // A flagged step may still go on the blockchain; a rejected one never.
      expect(find.text(AppText.stepNotAnchoredYet), findsOneWidget);
      expect(find.text(AppText.stepRejectedNeverAnchored), findsOneWidget);
      expect(find.text(AppText.notSentYet), findsOneWidget);
    });

    // T5b, found on the A57 (MC-2026-LSK-0008): the rejected purchase said
    // "Not on the blockchain yet" and "Not sent to the blockchain yet", and
    // the verdict stayed "not on the blockchain yet". It never goes.
    testWidgets('a rejected step says it is never put on the blockchain, '
        'and the rest is verified', (tester) async {
      final cleared =
          checkedStepJson(type: 'handoff', role: 'transporter', n: 2)
            ..['reviewStatus'] = 'cleared'
            ..['alerts'] = [alert(1, 'dismissed')];
      final rejected =
          checkedStepJson(
              type: 'purchase',
              role: 'buyer',
              n: 3,
              check: 'not_anchored_yet',
            )
            ..['anchor'] = {'status': 'pending', 'chainTxHash': null}
            ..['reviewStatus'] = 'rejected'
            ..['alerts'] = [alert(2, 'reviewed')];

      await showAnswer(
        tester,
        answerFor(Viewer.officer, [registration, cleared, rejected]),
        role: Viewer.officer.role,
      );

      expect(find.text(verdictText(Verdict.verified)), findsOneWidget);
      expect(find.text(verdictText(Verdict.notAnchoredYet)), findsNothing);
      final purchaseCard = find.ancestor(
        of: find.text(AppText.reviewRejected),
        matching: find.byType(Card),
      );
      Finder inPurchase(Finder f) =>
          find.descendant(of: purchaseCard, matching: f);
      expect(
        inPurchase(find.text(AppText.stepRejectedNeverAnchored)),
        findsOneWidget,
      );
      expect(find.text(AppText.stepNotAnchoredYet), findsNothing);
      expect(find.text(AppText.notSentYet), findsNothing);
      // The two accepted steps keep their check and their hash.
      expect(find.text(AppText.stepMatches), findsNWidgets(2));
      expect(find.text(AppText.blockchainTransaction), findsNWidgets(2));
    });

    testWidgets('a mismatch: the names of what differs and the reason, '
        'never values', (tester) async {
      final edited = checkedStepJson(check: 'mismatch')
        ..['check'] = {
          'result': 'mismatch',
          'fields': ['weight_mg', 'event.weightMilligrams'],
        };
      final missing =
          checkedStepJson(
              type: 'handoff',
              role: 'transporter',
              n: 2,
              check: 'mismatch',
            )
            ..['check'] = {
              'result': 'mismatch',
              'fields': ['chain_tx_hash'],
              'reason': 'TX_NOT_FOUND',
            };
      await showAnswer(
        tester,
        answerFor(Viewer.officer, [edited, missing], held: true),
        role: Viewer.officer.role,
      );

      expect(find.text(verdictText(Verdict.mismatch)), findsOneWidget);
      expect(
        find.text(AppText.whatDiffers('weight_mg, event.weightMilligrams')),
        findsOneWidget,
      );
      expect(find.text(AppText.whatDiffers('chain_tx_hash')), findsOneWidget);
      expect(find.text(AppText.mismatchReason('TX_NOT_FOUND')), findsOneWidget);
    });

    testWidgets('anyone else sees the mismatch, but not what differs', (
      tester,
    ) async {
      final edited = checkedStepJson(check: 'mismatch')
        ..['check'] = {
          'result': 'mismatch',
          'fields': ['weight_mg'],
          'reason': 'TX_NOT_FOUND',
        };
      await showAnswer(
        tester,
        answerFor(Viewer.otherBuyer, [edited], held: true),
        role: Viewer.otherBuyer.role,
      );
      expect(find.text(verdictText(Verdict.mismatch)), findsOneWidget);
      expect(find.text(AppText.stepMismatch), findsOneWidget);
      expect(find.textContaining('What differs'), findsNothing);
      expect(find.textContaining('TX_NOT_FOUND'), findsNothing);
    });
  });

  test('the alerts line', () {
    expect(AppText.alertsLine(0, 0), 'No alerts');
    expect(AppText.alertsLine(1, 1), '1 alert, 1 open');
    expect(AppText.alertsLine(3, 0), '3 alerts, 0 open');
  });

  group('fits small screens and large text', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      for (final viewer in [Viewer.officer, Viewer.blindTransporter]) {
        testWidgets('${viewer.name}, $name, text 2.0', (tester) async {
          final edited = checkedStepJson(check: 'mismatch')
            ..['check'] = {
              'result': 'mismatch',
              'fields': ['weight_mg', 'event.weightMilligrams', 'signature'],
              'reason': 'TX_NOT_FOUND',
            }
            ..['alerts'] = [alert(1, 'open')];
          await showAnswer(
            tester,
            answerFor(viewer, [edited, handoff], held: true),
            role: viewer.role,
            size: size,
            textScale: 2.0,
          );
          expect(tester.takeException(), isNull);
          await tapVisible(tester, find.text(AppText.scanAgain));
          expect(find.text('fake camera'), findsOneWidget);
        });
      }
    }
  });
}
