// The officer's "Alerts" list inside the real app and router, with the fake
// server behind the real repository and ApiClient (officer alerts plan, T2):
// the cards, the three lists (Q1), paging, refreshing, each failure, and
// fitting small screens and large text.

import 'dart:async';
import 'dart:io' show HandshakeException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/alerts/presentation/alerts_list_controller.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_alerts_server.dart';
import '../../../fakes/fake_controllers.dart';

late FakeAlertsServer server;
late AppHarness app;

/// Starts the app as an officer and opens the list the way an officer does:
/// the "Alerts" tile on the officer home.
Future<void> openAlerts(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
  bool settle = true,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.officer)),
    size: size,
    textScale: textScale,
    overrides: server.overrides(),
  );
  if (settle) {
    await tapVisible(tester, find.text(AppText.alerts));
  } else {
    // A spinner never stops moving: draw the page transition frame by frame.
    await tester.tap(find.text(AppText.alerts));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Finder get alertsList => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> toRow(WidgetTester tester, Finder finder) =>
    scrollTo(tester, finder, scrollable: alertsList);

Future<void> tapInList(WidgetTester tester, Finder finder) =>
    scrollToAndTap(tester, finder, scrollable: alertsList);

/// The card whose QR line names [qrCode].
Finder cardOf(String qrCode) =>
    find.ancestor(of: find.textContaining(qrCode), matching: find.byType(Card));

Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

void main() {
  setUp(() => server = FakeAlertsServer());

  group('opening', () {
    testWidgets('the officer tile opens /officer/alerts, the open list', (
      tester,
    ) async {
      await openAlerts(tester);

      expect(app.path, AppRoutes.officerAlerts);
      expect(find.widgetWithText(AppBar, AppText.alerts), findsOneWidget);
      expect(server.lists.single.url.queryParameters['status'], 'open');
      expect(
        tester.widget<ChoiceChip>(chip(AppText.alertsOpen)).selected,
        true,
      );
    });

    testWidgets('the back arrow returns to the officer home', (tester) async {
      await openAlerts(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.officer);
    });

    for (final role in [Role.admin, Role.buyer]) {
      testWidgets('${role.name} cannot open it, nor one alert', (tester) async {
        app = await AppHarness.pump(
          tester,
          FakeAuthController(signedInAs(role)),
          overrides: server.overrides(),
        );
        final router = app.container.read(appRouterProvider);
        router.go(AppRoutes.officerAlerts);
        await tester.pumpAndSettle();
        expect(app.path, isNot(startsWith(AppRoutes.officer)));

        router.go(AppRoutes.officerAlert(alertId(1)));
        await tester.pumpAndSettle();
        expect(app.path, isNot(startsWith(AppRoutes.officer)));
        expect(server.received, isEmpty);
      });
    }
  });

  group('states', () {
    testWidgets('loading', (tester) async {
      server.hold = Completer<void>();
      await openAlerts(tester, settle: false);
      await tester.pump();

      expect(find.text(AppText.loadingAlerts), findsOneWidget);

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text(AppText.loadingAlerts), findsNothing);
    });

    testWidgets('a card: finding, severity word, consignment, who, when, '
        'held', (tester) async {
      await openAlerts(tester);

      final card = cardOf('MC-2026-LSK-0008');
      Finder inCard(Finder f) => find.descendant(of: card, matching: f);
      expect(
        find.text(
          AppText.alertsCount(status: AppText.statusOpen, shown: 1, total: 1),
        ),
        findsOneWidget,
      );
      expect(inCard(find.text(AppText.alertQuantity)), findsOneWidget);
      // Never colour alone: an icon AND the word.
      expect(inCard(find.text('Medium')), findsOneWidget);
      expect(inCard(find.byIcon(Icons.warning_amber)), findsOneWidget);
      expect(inCard(find.text('MC-2026-LSK-0008, Copper')), findsOneWidget);
      expect(
        inCard(find.text('Handoff by transporter patsani')),
        findsOneWidget,
      );
      // 12:01 UTC is 20 Nov in Zambia and in most zones the tests run in.
      expect(inCard(find.textContaining('Raised 20 Nov')), findsOneWidget);
      expect(inCard(find.text(AppText.holdsConsignment)), findsOneWidget);
    });

    testWidgets("cards in the server's order, each type's heading", (
      tester,
    ) async {
      server = FakeAlertsServer([
        alertJson(1, qrCode: 'MC-2026-LSK-0001'),
        alertJson(
          2,
          type: 'gps_zone',
          stepType: 'registration',
          role: 'miner',
          username: 'mutale_banda',
          qrCode: 'MC-2026-LSK-0002',
          consignmentId: '5c0d7e21-0000-4000-8000-000000000002',
          details: {'noActiveZones': true, 'toleranceMetres': 25},
        ),
        alertJson(
          3,
          type: 'handoff_order',
          severity: 'high',
          stepType: 'purchase',
          role: 'buyer',
          username: 'buyer_one',
          qrCode: 'MC-2026-LSK-0003',
          consignmentId: '5c0d7e21-0000-4000-8000-000000000003',
          details: {'consignmentStage': 'purchased', 'stepType': 'purchase'},
        ),
      ]);
      await openAlerts(tester);

      final top = tester.getTopLeft(cardOf('MC-2026-LSK-0001')).dy;
      await toRow(tester, cardOf('MC-2026-LSK-0002'));
      expect(
        find.descendant(
          of: cardOf('MC-2026-LSK-0002'),
          matching: find.text('Registration by miner mutale_banda'),
        ),
        findsOneWidget,
      );
      expect(find.text(AppText.alertGpsZone), findsOneWidget);
      await toRow(tester, find.text(AppText.alertHandoffOrder));
      final third = cardOf('MC-2026-LSK-0003');
      expect(
        find.descendant(of: third, matching: find.text('High')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: third, matching: find.byIcon(Icons.error)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: third,
          matching: find.text('Purchase by buyer buyer_one'),
        ),
        findsOneWidget,
      );
      expect(tester.getTopLeft(third).dy, greaterThan(top));
    });

    testWidgets('empty', (tester) async {
      server.alerts.clear();
      await openAlerts(tester);

      expect(find.text(AppText.noOpenAlerts), findsOneWidget);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('no connection, then Try again', (tester) async {
      server.listAnswer = (_) => throw http.ClientException('offline');
      await openAlerts(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.listAnswer = null;
      await tapInList(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );
      expect(cardOf('MC-2026-LSK-0008'), findsOneWidget);
    });

    testWidgets('an unreadable answer shows its sentence', (tester) async {
      server.listAnswer = (_) => http.Response('<html>', 502);
      await openAlerts(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      server.listAnswer = (_) => throw const HandshakeException('test');
      await openAlerts(tester);

      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('token expired: the password first, then the list', (
      tester,
    ) async {
      await openAlerts(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.officer)),
      );

      expect(find.text(AppText.alertsNeedPassword), findsOneWidget);
      expect(server.received, isEmpty);

      await tapInList(
        tester,
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
      );
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

      expect(cardOf('MC-2026-LSK-0008'), findsOneWidget);
    });
  });

  group('the three lists (Q1)', () {
    setUp(() {
      server = FakeAlertsServer([
        alertJson(1),
        alertJson(
          2,
          status: 'reviewed',
          reviewStatus: 'rejected',
          qrCode: 'MC-2026-LSK-0002',
          consignmentId: '5c0d7e21-0000-4000-8000-000000000002',
        ),
        alertJson(
          3,
          status: 'dismissed',
          reviewStatus: 'cleared',
          qrCode: 'MC-2026-LSK-0003',
          consignmentId: '5c0d7e21-0000-4000-8000-000000000003',
        ),
      ]);
    });

    testWidgets('"Confirmed" asks for reviewed alerts and shows the '
        'decision', (tester) async {
      await openAlerts(tester);
      await tester.tap(chip(AppText.alertsConfirmed));
      await tester.pumpAndSettle();

      expect(server.lists.last.url.queryParameters['status'], 'reviewed');
      final card = cardOf('MC-2026-LSK-0002');
      expect(card, findsOneWidget);
      expect(cardOf('MC-2026-LSK-0008'), findsNothing);
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining('Confirmed by officer_chanda, 20 Nov'),
        ),
        findsOneWidget,
      );
      // Alone on its consignment and closed: nothing holds it.
      expect(
        find.descendant(
          of: card,
          matching: find.text(AppText.holdsConsignment),
        ),
        findsNothing,
      );
      expect(
        find.text(
          AppText.alertsCount(
            status: AppText.statusConfirmed,
            shown: 1,
            total: 1,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('"Cleared" asks for dismissed alerts', (tester) async {
      await openAlerts(tester);
      await tester.tap(chip(AppText.alertsCleared));
      await tester.pumpAndSettle();

      expect(server.lists.last.url.queryParameters['status'], 'dismissed');
      expect(
        find.descendant(
          of: cardOf('MC-2026-LSK-0003'),
          matching: find.textContaining('Cleared by officer_chanda'),
        ),
        findsOneWidget,
      );
    });

    // T5b, found on the A57 (0008): a cleared handoff alert said "Holds this
    // consignment" while the purchase alert on the same consignment was
    // open. Only an open alert holds anything.
    testWidgets('a closed alert on a held consignment never says it holds '
        'it', (tester) async {
      server = FakeAlertsServer([
        alertJson(1, status: 'dismissed', reviewStatus: 'cleared'),
        alertJson(2, stepType: 'purchase', role: 'buyer', username: 'kay'),
      ]);
      await openAlerts(tester);
      // The open one does.
      expect(
        find.descendant(
          of: cardOf('MC-2026-LSK-0008'),
          matching: find.text(AppText.holdsConsignment),
        ),
        findsOneWidget,
      );

      await tester.tap(chip(AppText.alertsCleared));
      await tester.pumpAndSettle();

      final card = cardOf('MC-2026-LSK-0008');
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining('Cleared by officer_chanda'),
        ),
        findsOneWidget,
      );
      // The consignment is held (alert 2 is open), but not by this alert.
      expect(
        find.descendant(
          of: card,
          matching: find.text(AppText.holdsConsignment),
        ),
        findsNothing,
      );
    });

    testWidgets('back to "Open" reads the open list again', (tester) async {
      await openAlerts(tester);
      await tester.tap(chip(AppText.alertsCleared));
      await tester.pumpAndSettle();
      await tester.tap(chip(AppText.alertsOpen));
      await tester.pumpAndSettle();

      expect(server.lists.map((r) => r.url.queryParameters['status']), [
        'open',
        'dismissed',
        'open',
      ]);
      expect(cardOf('MC-2026-LSK-0008'), findsOneWidget);
    });

    testWidgets('each list has its own empty sentence', (tester) async {
      server.alerts.clear();
      await openAlerts(tester);
      expect(find.text(AppText.noOpenAlerts), findsOneWidget);

      await tester.tap(chip(AppText.alertsConfirmed));
      await tester.pumpAndSettle();
      expect(find.text(AppText.noConfirmedAlerts), findsOneWidget);

      await tester.tap(chip(AppText.alertsCleared));
      await tester.pumpAndSettle();
      expect(find.text(AppText.noClearedAlerts), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('pulling the list down reads it again', (tester) async {
      await openAlerts(tester);
      server.alerts.add(alertJson(2, qrCode: 'MC-2026-LSK-0009'));

      await tester.fling(
        find.text(AppText.alertQuantity).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(server.lists, hasLength(2));
      expect(
        find.text(
          AppText.alertsCount(status: AppText.statusOpen, shown: 2, total: 2),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the refresh button does the same', (tester) async {
      await openAlerts(tester);
      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();
      expect(server.lists, hasLength(2));
    });

    testWidgets('a failed refresh keeps the list and says why', (tester) async {
      await openAlerts(tester);
      server.listAnswer = (_) => throw http.ClientException('offline');

      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();

      expect(cardOf('MC-2026-LSK-0008'), findsOneWidget);
      expect(find.text(AppText.noConnection), findsOneWidget); // snack bar
    });

    testWidgets('coming back from an alert reads the list again', (
      tester,
    ) async {
      await openAlerts(tester);
      await tapInList(tester, cardOf('MC-2026-LSK-0008'));
      expect(app.path, AppRoutes.officerAlert(alertId(1)));

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(app.path, AppRoutes.officerAlerts);
      expect(server.lists, hasLength(2));
    });
  });

  group('Show more', () {
    testWidgets('loads the rest under the list', (tester) async {
      server = FakeAlertsServer([for (var n = 1; n <= 23; n++) alertJson(n)]);
      await openAlerts(tester);

      expect(find.text('Showing 20 of 23 alerts.'), findsOneWidget);
      await tapInList(tester, find.text(AppText.showMore));

      expect(server.lists.last.url.queryParameters['offset'], '20');
      expect(find.text(AppText.showMore), findsNothing);
      // The rows are far below the built area: read the list's state.
      final loaded = app.container.read(
        alertsListControllerProvider(AlertStatus.open),
      ) as AlertsLoaded;
      expect(loaded.alerts.map((a) => a.id), [
        for (var n = 1; n <= 23; n++) alertId(n),
      ]);
      expect(loaded.total, 23);
    });

    testWidgets('not shown when everything is loaded', (tester) async {
      await openAlerts(tester);
      expect(find.text(AppText.showMore), findsNothing);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('the list: $name', (tester) async {
        server = FakeAlertsServer([
          alertJson(1),
          alertJson(
            2,
            type: 'record_tampered',
            severity: 'high',
            qrCode: 'MC-2026-LSK-0002',
            details: {
              'source': 'verification',
              'fields': ['weight_mg'],
              'chainTxHash': '0x${'c0' * 32}',
            },
          ),
        ]);
        await openAlerts(tester, size: size, textScale: scale);

        expect(tester.takeException(), isNull);
        // Each card's last line, so every card is seen whole.
        await toRow(tester, find.text(AppText.holdsConsignment).last);
        expect(tester.takeException(), isNull);
        await toRow(tester, cardOf('MC-2026-LSK-0002'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the empty state: $name', (tester) async {
        server.alerts.clear();
        await openAlerts(tester, size: size, textScale: scale);
        expect(find.text(AppText.noOpenAlerts), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
