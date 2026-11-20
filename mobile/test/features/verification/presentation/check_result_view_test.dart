// "Check a consignment", T4: the result page (plan §4). The banner for each
// verdict, the consignment, and the step cards for the common view (every
// field a buyer in transit or a transporter after their handoff sees).
// Role differences (blind transporter, officer extras) are in
// check_result_roles_test.dart (T5).
//
// The whole app runs with the real router, a fake camera and a fake server
// whose answer each test sets, so the page is reached exactly as a user
// reaches it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/verification/domain/verdict.dart';
import 'package:minechain/features/verification/presentation/check_result_view.dart';

import '../../../core/theme/app_theme_test.dart' show contrast;
import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_registration.dart' show FakeQrScanner;
import 'check_page_helpers.dart';

/// A step as a buyer in transit sees it: no coordinates and no officer
/// fields (api.md, "What each viewer sees").
Map<String, Object?> buyerStep({
  String type = 'registration',
  String role = 'miner',
  String check = 'match',
  int n = 1,
}) => checkedStepJson(type: type, role: role, check: check, n: n)
  ..remove('location')
  ..remove('reviewStatus')
  ..remove('alerts');

/// A step not yet on the chain: pending, no hash, not anchored yet.
Map<String, Object?> pendingStep({int n = 2}) => buyerStep(
  type: 'handoff',
  role: 'transporter',
  n: n,
  check: 'not_anchored_yet',
)..['anchor'] = {'status': 'pending', 'chainTxHash': null};

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
  });

  group('the banner, worst first', () {
    final cases = <(String, Map<String, Object?>, Verdict)>[
      (
        'a mismatching step outranks the rest',
        consignmentAnswerJson(
          held: true,
          steps: [
            buyerStep(check: 'mismatch'),
            pendingStep(),
          ],
        ),
        Verdict.mismatch,
      ),
      (
        'held, every step matches',
        consignmentAnswerJson(held: true, steps: [buyerStep()]),
        Verdict.underReview,
      ),
      (
        'chain unavailable outranks not anchored yet',
        consignmentAnswerJson(
          steps: [
            buyerStep(check: 'chain_unavailable'),
            pendingStep(),
          ],
        ),
        Verdict.chainUnavailable,
      ),
      (
        'a step not on the blockchain yet',
        consignmentAnswerJson(steps: [buyerStep(), pendingStep()]),
        Verdict.notAnchoredYet,
      ),
      (
        'no step listed',
        consignmentAnswerJson(stage: 'registered', steps: []),
        Verdict.nothingToCheck,
      ),
      (
        'every step matches',
        consignmentAnswerJson(
          steps: [
            buyerStep(),
            buyerStep(type: 'handoff', role: 'transporter', n: 2),
          ],
        ),
        Verdict.verified,
      ),
    ];

    for (final (name, answer, verdict) in cases) {
      testWidgets('$name: ${verdict.name}', (tester) async {
        await showAnswer(tester, answer);

        expect(find.text(verdictText(verdict)), findsOneWidget);
        // Only one banner, and it comes first.
        final banner = find.byType(VerdictBanner);
        expect(banner, findsOneWidget);
        expect(
          tester.getTopLeft(banner).dy,
          lessThan(tester.getTopLeft(find.text(knownQrCode)).dy),
        );
      });
    }

    testWidgets('no step listed: no "Custody steps" heading', (tester) async {
      await showAnswer(tester, consignmentAnswerJson(steps: []));
      expect(find.text(AppText.custodySteps), findsNothing);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('the banner is read out by TalkBack when it appears', (
      tester,
    ) async {
      await showAnswer(tester, consignmentAnswerJson());
      expect(
        tester.getSemantics(find.byType(VerdictBanner)),
        isSemantics(isLiveRegion: true),
      );
    });
  });

  group('the consignment', () {
    for (final (stage, word) in [
      ('registered', AppText.stageRegistered),
      ('in_transit', AppText.stageInTransit),
      ('purchased', AppText.stagePurchased),
    ]) {
      testWidgets('stage $stage: "$word"', (tester) async {
        await showAnswer(
          tester,
          consignmentAnswerJson(stage: stage, steps: [buyerStep()]),
        );
        expect(find.text(knownQrCode), findsOneWidget);
        expect(find.text(AppText.gold), findsOneWidget);
        expect(find.text(AppText.stageLine(word)), findsOneWidget);
      });
    }
  });

  group('the step cards', () {
    testWidgets('one card per step, in the order the server sent them', (
      tester,
    ) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(
          stage: 'purchased',
          steps: [
            buyerStep(),
            buyerStep(type: 'handoff', role: 'transporter', n: 2),
            buyerStep(type: 'purchase', role: 'buyer', n: 3),
          ],
        ),
      );

      final headlines = [
        AppText.registeredBy('miner demo_miner_1'),
        AppText.handedOffTo('transporter demo_transporter_2'),
        AppText.boughtBy('buyer demo_buyer_3'),
      ];
      expect(find.byType(Card), findsNWidgets(3));
      final tops = [
        for (final h in headlines) tester.getTopLeft(find.text(h)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
    });

    testWidgets('a step\'s details: weight in the mineral\'s unit, zone, '
        'time on the phone\'s clock, its check and the hash', (tester) async {
      await showAnswer(tester, consignmentAnswerJson(steps: [buyerStep()]));

      // 1 500 000 mg of gold is 1500 g, exact from the text.
      expect(find.text(AppText.weightLine('1500 g')), findsOneWidget);
      expect(find.text(AppText.zoneLine('ZCAS Campus (demo)')), findsOneWidget);
      expect(
        find.text(AppText.recordedAt(DateTime.utc(2026, 11, 10, 8).toLocal())),
        findsOneWidget,
      );
      expect(find.text(AppText.stepMatches), findsOneWidget);
      expect(find.text(AppText.blockchainTransaction), findsOneWidget);

      // Selectable, so it can be copied into Etherscan (Q4).
      final hash = find.byType(SelectableText);
      expect(hash, findsOneWidget);
      expect(tester.widget<SelectableText>(hash).data, fakeTxHash);
    });

    testWidgets('kilogram minerals are shown in kg', (tester) async {
      final answer = consignmentAnswerJson(steps: [buyerStep()]);
      (answer['consignment']! as Map)['mineral'] = 'copper';
      await showAnswer(tester, answer);
      expect(find.text(AppText.weightLine('1.5 kg')), findsOneWidget);
    });

    testWidgets('each step\'s own check, in words', (tester) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(
          held: true,
          steps: [
            buyerStep(check: 'mismatch'),
            buyerStep(
              type: 'handoff',
              role: 'transporter',
              n: 2,
              check: 'chain_unavailable',
            ),
            pendingStep(n: 3),
          ],
        ),
      );
      expect(find.text(AppText.stepMismatch), findsOneWidget);
      expect(find.text(AppText.stepChainUnavailable), findsOneWidget);
      expect(find.text(AppText.stepNotAnchoredYet), findsOneWidget);
    });

    testWidgets('nothing sent yet: said so, no hash', (tester) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(steps: [buyerStep(), pendingStep()]),
      );
      expect(find.text(AppText.notSentYet), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('your own step says "you"', (tester) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(
          steps: [
            buyerStep(),
            buyerStep(type: 'handoff', role: 'transporter', n: 2)
              ..['byYou'] = true,
          ],
        ),
        role: Role.transporter,
      );
      expect(find.text(AppText.handedOffTo(AppText.you)), findsOneWidget);
    });

    testWidgets('no username sent: the role alone', (tester) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(
          steps: [
            buyerStep()..['actor'] = {'role': 'miner'},
          ],
        ),
      );
      expect(find.text(AppText.registeredBy('a miner')), findsOneWidget);
    });

    testWidgets('zoneName null: outside every licensed zone', (tester) async {
      await showAnswer(
        tester,
        consignmentAnswerJson(steps: [buyerStep()..['zoneName'] = null]),
      );
      expect(find.text(AppText.outsideEveryZone), findsOneWidget);
      expect(find.textContaining('Zone:'), findsNothing);
    });

    testWidgets('fields left out of the answer are not drawn at all', (
      tester,
    ) async {
      final step = buyerStep()..remove('weightMg');
      (step['anchor']! as Map).remove('chainTxHash');
      await showAnswer(tester, consignmentAnswerJson(steps: [step]));

      expect(find.textContaining('Weight:'), findsNothing);
      expect(find.text(AppText.blockchainTransaction), findsNothing);
      // Absent is "not for you", never "not sent yet".
      expect(find.text(AppText.notSentYet), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('a long result, $name, text 2.0', (tester) async {
        await showAnswer(
          tester,
          consignmentAnswerJson(
            stage: 'purchased',
            held: true,
            steps: [
              buyerStep(check: 'mismatch'),
              buyerStep(type: 'handoff', role: 'transporter', n: 2),
              pendingStep(n: 3),
            ],
          ),
          size: size,
          textScale: 2.0,
        );
        expect(tester.takeException(), isNull);
        // "Scan again" sits below every card and can still be reached.
        await tapVisible(tester, find.text(AppText.scanAgain));
        expect(find.text('fake camera'), findsOneWidget);
      });
    }
  });

  group('banner colours are readable (WCAG AA, 4.5:1)', () {
    for (final (name, theme) in [
      ('light', AppTheme.light),
      ('dark', AppTheme.dark),
    ]) {
      for (final verdict in Verdict.values) {
        test('$name, ${verdict.name}', () {
          final c = verdictColours(verdict, theme.colorScheme);
          expect(
            contrast(c.foreground, c.background),
            greaterThanOrEqualTo(4.5),
          );
        });
      }

      // A step's check line is drawn on the card's sand.
      test('$name, a step\'s check line on a card', () {
        final s = theme.colorScheme;
        for (final colour in [s.tertiary, s.error, s.onSurface]) {
          expect(
            contrast(colour, s.secondaryContainer),
            greaterThanOrEqualTo(4.5),
          );
        }
      });
    }
  });
}
