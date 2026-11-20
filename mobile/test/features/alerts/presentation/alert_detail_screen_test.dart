// One alert's page inside the real app and router, with the fake server
// behind the real repository and ApiClient (officer alerts plan, T3): every
// section for open and closed alerts, the other alerts and the hold
// sentence, Q2's "only confirm", 404 and the failures, and fitting small
// screens and large text. The decisions are in alert_decision_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart' show tapVisible;
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show json200, refusal;
import '../../../fakes/fake_alerts_server.dart';
import '../../../fakes/fake_controllers.dart' show userOf;
import 'alert_page_helpers.dart';

void main() {
  setUp(() => server = FakeAlertsServer());

  group('the sections', () {
    testWidgets("MC-2026-LSK-0008's open handoff alert", (tester) async {
      await openAlert(tester);

      expect(app.path, AppRoutes.officerAlert(alertId(1)));
      expect(server.details.single.url.path, '/alerts/${alertId(1)}');
      expect(find.widgetWithText(AppBar, AppText.alertTitle), findsOneWidget);
      expect(find.text(AppText.alertQuantity), findsOneWidget);
      expect(find.text(AppText.severityLine('Medium')), findsOneWidget);
      expect(find.text(AppText.alertIsOpen), findsOneWidget);

      // What the check found.
      await toPart(tester, find.text(AppText.whatTheCheckFound));
      expect(find.text('This handoff: 1.6 kg.'), findsOneWidget);
      expect(
        find.text(
          'The registration: 2 kg. This handoff is 0.4 kg (20%) lighter.',
        ),
        findsOneWidget,
      );

      // The step.
      await toPart(tester, find.text(AppText.theStep));
      expect(find.text('Handoff by transporter patsani'), findsOneWidget);
      await toPart(
        tester,
        find.textContaining('Recorded on the phone: 20 Nov'),
      );
      await toPart(
        tester,
        find.textContaining('Received by the server: 20 Nov'),
      );
      await toPart(tester, find.text(AppText.reviewFlagged));

      // The consignment.
      await toPart(tester, find.text(AppText.qrCodeLine('MC-2026-LSK-0008')));
      await toPart(tester, find.text(AppText.mineralLine('Copper')));
      await toPart(
        tester,
        find.text(AppText.stageLine(AppText.stageRegistered)),
      );
      await toPart(tester, find.text(AppText.consignmentHeld));

      // No other alert; no decision yet; both buttons.
      await toPart(tester, find.text(AppText.noOtherAlerts));
      expect(find.text(AppText.anotherAlertHolds), findsNothing);
      expect(find.text(AppText.theDecision), findsNothing);
      await toPart(tester, button(AppText.confirmProblem));
      expect(button(AppText.clearNoProblem), findsOneWidget);
      expect(find.text(AppText.onlyConfirm), findsNothing);
    });

    testWidgets('other alerts on the consignment, with the hold sentence', (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(
          1,
          type: 'gps_zone',
          stepType: 'registration',
          status: 'dismissed',
          reviewStatus: 'cleared',
          details: {'noActiveZones': true, 'toleranceMetres': 25},
        ),
        alertJson(2),
        alertJson(
          3,
          type: 'duplicate_consignment',
          severity: 'high',
          stepType: 'registration',
          details: {
            'originalTransactionId': stepIdFor(0),
            'originalReviewStatus': 'passed',
            'sameMiner': false,
            'mineral': 'copper',
            'originalMineral': 'copper',
          },
        ),
      ]);
      await openAlert(tester, alert: 2);

      await toPart(tester, find.text(AppText.otherAlerts));
      await toPart(tester, find.text(AppText.alertGpsZone));
      expect(find.textContaining('Cleared, raised 20 Nov'), findsOneWidget);
      await toPart(tester, find.text(AppText.alertDuplicate));
      expect(find.textContaining('Open, raised 20 Nov'), findsOneWidget);
      await toPart(tester, find.text(AppText.anotherAlertHolds));
    });

    testWidgets('no hold sentence when every other alert is closed', (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(
          1,
          type: 'gps_zone',
          stepType: 'registration',
          status: 'reviewed',
          reviewStatus: 'rejected',
          details: {'noActiveZones': true, 'toleranceMetres': 25},
        ),
        alertJson(2),
      ]);
      await openAlert(tester, alert: 2);

      await toPart(tester, find.text(AppText.alertGpsZone));
      expect(find.textContaining('Confirmed, raised'), findsOneWidget);
      await toPart(tester, button(AppText.confirmProblem));
      expect(find.text(AppText.anotherAlertHolds), findsNothing);
    });

    testWidgets('a closed alert shows its decision and notes, no buttons', (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(1, status: 'reviewed', reviewStatus: 'rejected'),
      ]);
      await openAlert(tester, list: AppText.alertsConfirmed);

      expect(find.text(AppText.alertIsConfirmed), findsOneWidget);
      await toPart(tester, find.text(AppText.reviewRejected));
      await toPart(tester, find.text(AppText.consignmentNotHeld));
      await toPart(tester, find.text(AppText.theDecision));
      await toPart(
        tester,
        find.textContaining('Confirmed by officer_chanda, 20 Nov'),
      );
      await toPart(
        tester,
        find.text(AppText.notesLine('Weighed again at the depot.')),
      );
      expect(button(AppText.confirmProblem), findsNothing);
      expect(button(AppText.clearNoProblem), findsNothing);
    });

    testWidgets('Q2: a handoff_order alert can only be confirmed', (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(
          1,
          type: 'handoff_order',
          details: {'consignmentStage': 'purchased', 'stepType': 'handoff'},
          stage: 'purchased',
        ),
      ]);
      await openAlert(tester);

      await toPart(tester, find.text(AppText.handoffAfterPurchase));
      await toPart(tester, find.text(AppText.onlyConfirm));
      await toPart(tester, button(AppText.confirmProblem));
      expect(button(AppText.clearNoProblem), findsNothing);
    });

    testWidgets('an unknown alert type: the fallback, and the decisions', (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(1, type: 'new_check', details: {'anything': 1}),
      ]);
      await openAlert(tester);

      expect(find.text(AppText.alertUnknown), findsWidgets);
      await toPart(tester, find.text(AppText.alertDetailsUnreadable));
      await toPart(tester, button(AppText.confirmProblem));
      expect(button(AppText.clearNoProblem), findsOneWidget);
    });

    testWidgets('the back arrow returns to the list', (tester) async {
      await openAlert(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.officerAlerts);
    });
  });

  group('failures', () {
    testWidgets('404: "no longer exists", and back to the alerts', (
      tester,
    ) async {
      server.detailAnswer = (_) =>
          refusal(404, 'ALERT_NOT_FOUND', 'No alert has this id.');
      await openAlert(tester);

      expect(find.text(AppText.alertGone), findsOneWidget);
      expect(button(AppText.confirmProblem), findsNothing);
      await tapVisible(tester, button(AppText.backToAlerts));
      expect(app.path, AppRoutes.officerAlerts);
    });

    testWidgets('no connection, then Try again', (tester) async {
      server.detailAnswer = (_) => throw http.ClientException('offline');
      await openAlert(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.detailAnswer = null;
      await tapVisible(tester, button(AppText.tryAgain));
      expect(find.text(AppText.alertIsOpen), findsOneWidget);
    });

    testWidgets('a detail without otherAlerts is unreadable', (tester) async {
      server.detailAnswer = (_) => json200({'alert': alertJson(1)});
      await openAlert(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('the session ended after the list: the password first', (
      tester,
    ) async {
      await openList(tester);
      app.auth.setState(SignedInNeedsPassword(userOf(Role.officer)));
      await tester.pump();
      await tapCard(tester, 'MC-2026-LSK-0008');

      expect(find.text(AppText.alertNeedsPassword), findsOneWidget);
      expect(server.details, isEmpty);

      await tapVisible(tester, button(AppText.enterYourPassword));
      await tester.enterText(
        find.descendant(
          of: find.byType(PasswordPromptDialog),
          matching: find.byType(TextField),
        ),
        fakePassword,
      );
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.continueLabel),
      );

      expect(server.details, hasLength(1));
      expect(find.text(AppText.alertIsOpen), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('an open alert with other alerts: $name', (tester) async {
        server = FakeAlertsServer([
          alertJson(1),
          alertJson(
            2,
            type: 'record_tampered',
            severity: 'high',
            details: {
              'source': 'verification',
              'fields': ['weight_mg', 'latitude'],
              'chainTxHash': '0x${'c0' * 32}',
            },
          ),
        ]);
        await openAlert(tester, size: size, textScale: scale);

        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(AppText.anotherAlertHolds));
        expect(tester.takeException(), isNull);
        await toPart(tester, button(AppText.clearNoProblem));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a closed alert: $name', (tester) async {
        server = FakeAlertsServer([alertJson(1, status: 'dismissed')]);
        await openAlert(
          tester,
          list: AppText.alertsCleared,
          size: size,
          textScale: scale,
        );
        await toPart(
          tester,
          find.text(AppText.notesLine('Weighed again at the depot.')),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
