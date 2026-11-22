// The officer's audit trails (reports plan, T4, §4.2–4.3): one consignment
// from "Check a consignment"'s result, one person from an alert's page.
// Through the whole app, with the check or alerts fake answering everything
// outside /reports.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_alerts_server.dart' as alerts;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart' show FakeQrScanner;
import '../../../fakes/fake_report_files.dart';
import '../../../fakes/fake_reports_server.dart';

late FakeReportsServer reports;
late FakeReportFileStore store;
late FakeReportSharer sharer;
late AppHarness app;

final now = DateTime.utc(2026, 11, 21, 12);

const sizes = [
  ('portrait 360x640', Size(360, 640), 1.0),
  ('landscape 640x360', Size(640, 360), 1.0),
  ('portrait, text 2.0', Size(360, 640), 2.0),
  ('landscape, text 2.0', Size(640, 360), 2.0),
];

Map<String, String> lastQuery() => reports.received.last.url.queryParameters;

Finder get anyScrollable => find.byType(Scrollable).first;

/// Whether [finder] is wholly inside the page's visible part (T5b).
bool inSight(WidgetTester tester, Finder finder) {
  final page = tester.getRect(anyScrollable);
  final target = tester.getRect(finder);
  return target.top >= page.top && target.bottom <= page.bottom;
}

void main() {
  setUp(() {
    reports = FakeReportsServer();
    store = FakeReportFileStore();
    sharer = FakeReportSharer();
  });

  group('one consignment, from the check result', () {
    late FakeCheckServer check;
    late FakeQrScanner camera;

    Future<void> checkAs(
      WidgetTester tester,
      Role role, {
      Size size = const Size(360, 640),
      double textScale = 1.0,
      String tile = AppText.checkConsignment,
    }) async {
      reports.role = role.name;
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(role)),
        size: size,
        textScale: textScale,
        overrides: [
          ...reports.overrides(others: check.client),
          ...reportFileOverrides(store, sharer),
          qrScannerBuilderProvider.overrideWithValue(camera.builder),
          clockProvider.overrideWithValue(() => now),
        ],
      );
      await tapVisible(tester, find.text(tile));
      camera.scan(knownQrCode);
      await tester.pumpAndSettle();
    }

    setUp(() {
      check = FakeCheckServer();
      camera = FakeQrScanner();
    });

    testWidgets('the officer downloads it, by the consignment\'s id', (
      tester,
    ) async {
      await checkAs(tester, Role.officer);
      await tapVisible(tester, find.text(AppText.downloadAuditTrail));
      expect(reports.received.single.url.path, '/reports/audit-trail');
      expect(lastQuery(), {'consignmentId': knownConsignmentId});
      expect(
        find.text('minechain-audit-trail-consignment-$knownConsignmentId.csv'),
        findsOneWidget,
      );
      expect(find.text(AppText.reportRows(3)), findsOneWidget);
      expect(find.text(AppText.reportShared), findsOneWidget);
      expect(sharer.shared, hasLength(1));
    });

    for (final role in [Role.transporter, Role.buyer]) {
      testWidgets('no button for the ${role.name}', (tester) async {
        await checkAs(tester, role);
        expect(find.text(AppText.scanAgain), findsOneWidget);
        expect(find.text(AppText.downloadAuditTrail), findsNothing);
      });
    }

    testWidgets('the officer\'s "Audit trail" tile opens the check', (
      tester,
    ) async {
      await checkAs(tester, Role.officer, tile: AppText.auditTrail);
      expect(app.path, AppRoutes.officerCheck);
      expect(find.text(AppText.downloadAuditTrail), findsOneWidget);
    });

    testWidgets('the card comes into sight, "Share again" too (T5b)', (
      tester,
    ) async {
      await checkAs(tester, Role.officer);
      await tapVisible(tester, find.text(AppText.downloadAuditTrail));
      expect(inSight(tester, find.text(AppText.shareAgain)), isTrue);
    });

    testWidgets('a consignment the server does not know', (tester) async {
      reports.answers['audit-trail'] = (_) =>
          refusal(404, 'CONSIGNMENT_NOT_FOUND', 'No consignment has this id.');
      await checkAs(tester, Role.officer);
      await tapVisible(tester, find.text(AppText.downloadAuditTrail));
      expect(find.text(AppText.reportConsignmentNotFound), findsOneWidget);
      expect(find.text(AppText.tryAgain), findsNothing);
    });

    testWidgets('"Scan again" leaves the card behind with the old result', (
      tester,
    ) async {
      await checkAs(tester, Role.officer);
      await tapVisible(tester, find.text(AppText.downloadAuditTrail));
      await tapVisible(tester, find.text(AppText.scanAgain));
      expect(find.text(AppText.shareAgain), findsNothing);
    });

    for (final (name, size, scale) in sizes) {
      testWidgets('fits: $name', (tester) async {
        await checkAs(tester, Role.officer, size: size, textScale: scale);
        await tapVisible(tester, find.text(AppText.downloadAuditTrail));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.shareAgain));
      });
    }
  });

  group('one person, from an alert', () {
    late alerts.FakeAlertsServer alertServer;

    Future<void> openAlert(
      WidgetTester tester, {
      Size size = const Size(360, 640),
      double textScale = 1.0,
    }) async {
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.officer)),
        size: size,
        textScale: textScale,
        overrides: [
          ...reports.overrides(others: alertServer.client),
          ...reportFileOverrides(store, sharer),
          clockProvider.overrideWithValue(() => now),
        ],
      );
      await tapVisible(tester, find.text(AppText.alerts));
      await tapVisible(
        tester,
        find
            .descendant(
              of: find.byKey(ValueKey(alerts.alertId(1))),
              matching: find.byType(Text),
            )
            .first,
      );
    }

    Finder personButton() => find.text(AppText.downloadPersonTrail('patsani'));

    Future<void> toButton(WidgetTester tester) => scrollTo(
      tester,
      personButton(),
      scrollable: find.byType(Scrollable).first,
    );

    setUp(() => alertServer = alerts.FakeAlertsServer());

    testWidgets('the dialog\'s default period, then the download by the '
        'actor\'s id', (tester) async {
      await openAlert(tester);
      await toButton(tester);
      await tapVisible(tester, personButton());
      expect(find.text(AppText.personTrailTitle('patsani')), findsOneWidget);
      expect(
        find.text(AppText.reportFrom(DateTime(2026, 10, 23))),
        findsOneWidget,
      );
      await tapVisible(tester, find.text(AppText.download));

      expect(reports.received.single.url.path, '/reports/audit-trail');
      expect(lastQuery(), {
        'actorId': knownActorId,
        'from': '2026-10-23',
        'to': '2026-11-21',
      });
      expect(
        find.text(
          'minechain-audit-trail-user-$knownActorId-2026-10-23-to-2026-11-21.csv',
        ),
        findsOneWidget,
      );
      expect(find.text(AppText.reportShared), findsOneWidget);
    });

    testWidgets('the card comes into sight after the dialog (T5b)', (
      tester,
    ) async {
      await openAlert(tester);
      await toButton(tester);
      await tapVisible(tester, personButton());
      await tapVisible(tester, find.text(AppText.download));
      expect(inSight(tester, find.text(AppText.shareAgain)), isTrue);
    });

    testWidgets('Cancel downloads nothing', (tester) async {
      await openAlert(tester);
      await toButton(tester);
      await tapVisible(tester, personButton());
      await tapVisible(tester, find.text(AppText.cancel));
      expect(find.byType(AlertDialog), findsNothing);
      expect(reports.received, isEmpty);
    });

    testWidgets('more than 366 days: the sentence, and Download is off', (
      tester,
    ) async {
      await openAlert(tester);
      await toButton(tester);
      await tapVisible(tester, personButton());
      await tapVisible(
        tester,
        find.text(AppText.reportFrom(DateTime(2026, 10, 23))),
      );
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '01/01/2025');
      await tester.enterText(fields.at(1), '11/21/2026');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text(AppText.periodTooLong), findsOneWidget);
      final download = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, AppText.download),
      );
      expect(download.onPressed, isNull);
      expect(reports.received, isEmpty);
    });

    testWidgets('a person the server does not know', (tester) async {
      reports.answers['audit-trail'] = (_) =>
          refusal(404, 'USER_NOT_FOUND', 'No user has this id.');
      await openAlert(tester);
      await toButton(tester);
      await tapVisible(tester, personButton());
      await tapVisible(tester, find.text(AppText.download));
      expect(find.text(AppText.reportPersonNotFound), findsOneWidget);
    });

    testWidgets('the decisions are still there', (tester) async {
      await openAlert(tester);
      await toButton(tester);
      await scrollTo(
        tester,
        find.text(AppText.confirmProblem),
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(AppText.clearNoProblem), findsOneWidget);
    });

    for (final (name, size, scale) in sizes) {
      testWidgets('fits: $name', (tester) async {
        await openAlert(tester, size: size, textScale: scale);
        await toButton(tester);
        await tapVisible(tester, personButton());
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text(AppText.download));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.shareAgain));
      });
    }
  });
}
