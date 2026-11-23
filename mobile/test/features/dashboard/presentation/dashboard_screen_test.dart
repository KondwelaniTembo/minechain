// The officer's "Dashboard" inside the real app and router, with the fake
// dashboard server behind the real repository and ApiClient (dashboard plan,
// T4): every section, the period and mineral chips, refresh, an answer to an
// older choice dropped, the failure states, and fitting small screens and
// large text.

import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/alerts/domain/alert.dart';
import 'package:minechain/features/alerts/presentation/alert_words.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';
import 'package:minechain/features/dashboard/presentation/dashboard_screen.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart' show json200;
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_dashboard_server.dart';
import '../../admin/presentation/account_page_helpers.dart' show sizes, snack;

late FakeDashboardServer server;
late AppHarness app;

/// Noon on 23 Nov 2026 (UTC): "Last 7 days" is 17–23 Nov.
final today = DateTime.utc(2026, 11, 23, 12);

/// Starts the app as an officer and opens "Dashboard" from the home.
Future<void> openDashboard(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.officer)),
    size: size,
    textScale: textScale,
    overrides: <Override>[
      ...server.overrides(),
      clockProvider.overrideWithValue(() => today),
    ],
  );
  await tapVisible(tester, find.text(AppText.dashboard));
}

Finder get pageScrollable => find
    .descendant(
      of: find.byType(DashboardScreen),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the page until [finder] is on screen.
Future<void> toPart(WidgetTester tester, Finder finder) =>
    scrollTo(tester, finder, scrollable: pageScrollable);

/// A screen tall enough for the whole page, so the list builds every part
/// and an absence below means the part is really left out. On a phone-sized
/// screen the cards under the chips are not built until scrolled to; the
/// "fits small screens" group checks those sizes by scrolling.
const tall = Size(400, 4000);

/// The chart's bars (each has a key starting with "bar-", then its day).
Finder get bars => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('bar-'),
);

Map<String, String> queryOf(http.Request request) =>
    request.url.queryParameters;

Finder chip(String words) => find.widgetWithText(ChoiceChip, words);

void main() {
  setUp(() => server = FakeDashboardServer());

  group('opened from the tile', () {
    testWidgets('the last 7 days, every mineral: every section', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);

      expect(app.path, AppRoutes.officerDashboard);
      expect(server.received.single.url.path, '/dashboard');
      expect(queryOf(server.received.single), {
        'from': '2026-11-17',
        'to': '2026-11-23',
      });
      expect(
        find.text(
          AppText.dashboardDays(
            DateTime.utc(2026, 11, 17),
            DateTime.utc(2026, 11, 23),
          ),
        ),
        findsOneWidget,
      );
      // Right now.
      expect(find.text('8 open alerts'), findsOneWidget);
      expect(find.text(AppText.stageRegistered), findsOneWidget);
      expect(find.text(AppText.stageInTransit), findsOneWidget);
      expect(find.text(AppText.stagePurchased), findsOneWidget);
      // Volumes: 21 steps, the weight in kilograms, a bar per day.
      expect(find.text('21 steps recorded'), findsOneWidget);
      expect(find.text('18.5 kg registered'), findsOneWidget);
      expect(find.text(AppText.stepsPerDay), findsOneWidget);
      expect(bars, findsNWidgets(7));
      expect(find.text(AppText.stepRegistrations), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      // By mineral, every weight in kilograms.
      expect(find.text('12 steps, 6.5 kg registered'), findsOneWidget);
      expect(find.text('9 steps, 12 kg registered'), findsOneWidget);
      // Where.
      expect(find.text('ZCAS Campus (demo)'), findsOneWidget);
      expect(find.text(AppText.outsideEveryZone), findsOneWidget);
      // Anomalies: only the rules that fired, then every severity.
      expect(find.text('5 raised, 3 still open'), findsOneWidget);
      expect(
        find.text(alertHeading(AlertType.quantityDiscrepancy)),
        findsOneWidget,
      );
      expect(find.text(alertHeading(AlertType.invalidSignature)), findsNothing);
      expect(find.text(severityWord(AlertSeverity.high)), findsOneWidget);
      expect(find.text(severityWord(AlertSeverity.low)), findsOneWidget);
    });

    testWidgets('each bar has its day and count for screen readers', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);

      final bar = tester.widget<Semantics>(
        find.byKey(
          ValueKey('bar-${DateTime.utc(2026, 11, 20).toIso8601String()}'),
        ),
      );
      expect(bar.properties.label, '20 Nov: 8 steps');
    });

    testWidgets('an empty period: one line, no empty cards', (tester) async {
      server.build = (from, to, mineral) =>
          emptyDashboardJson(from: from, to: to, mineral: mineral);
      await openDashboard(tester, size: tall);

      expect(
        find.text('No steps were recorded in the last 7 days.'),
        findsOneWidget,
      );
      expect(find.text('No open alerts'), findsOneWidget);
      expect(bars, findsNothing);
      expect(find.text(AppText.byMineralHeading), findsNothing);
      expect(find.text(AppText.whereHeading), findsNothing);
      expect(find.text(AppText.anomaliesHeading), findsNothing);
    });

    testWidgets('a deactivated zone and a mineral this app does not know', (
      tester,
    ) async {
      server.build = (from, to, mineral) => dashboardJson(
        from: from,
        to: to,
        byMineral: const [
          {'mineral': 'lithium', 'steps': 2, 'registeredWeightMg': '900'},
        ],
        byZone: [
          {
            'zoneId': dashboardZoneId(2),
            'zoneName': 'Old Site',
            'active': false,
            'steps': 3,
          },
        ],
        outsideZones: 0,
      );
      await openDashboard(tester, size: tall);

      expect(find.text('lithium'), findsOneWidget);
      expect(find.text('2 steps, 0.0009 kg registered'), findsOneWidget);
      expect(find.text(AppText.zoneDeactivated('Old Site')), findsOneWidget);
      expect(find.text(AppText.outsideEveryZone), findsNothing);
    });
  });

  group('choices', () {
    testWidgets('30 days: a bar per day; 12 months: a bar per week', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);

      await tester.tap(chip(AppText.last30Days));
      await tester.pumpAndSettle();
      expect(queryOf(server.received.last), {
        'from': '2026-10-25',
        'to': '2026-11-23',
      });
      expect(find.text(AppText.stepsPerDay), findsOneWidget);
      expect(bars, findsNWidgets(30));

      await tester.tap(chip(AppText.last12Months));
      await tester.pumpAndSettle();
      expect(queryOf(server.received.last), {
        'from': '2025-11-24',
        'to': '2026-11-23',
      });
      expect(find.text(AppText.stepsPerWeek), findsOneWidget);
      expect(bars, findsNWidgets(53));
      expect(server.received, hasLength(3));
    });

    // T5b: the phone check read "24 Nov … 23 Nov" on 12 months as a period
    // running backwards.
    testWidgets('the chart\'s dates have their years only when they differ', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      expect(find.text('17 Nov'), findsOneWidget);
      expect(find.text('23 Nov'), findsOneWidget);

      await tester.tap(chip(AppText.last12Months));
      await tester.pumpAndSettle();
      expect(find.text('24 Nov 2025'), findsOneWidget);
      expect(find.text('23 Nov 2026'), findsOneWidget);
      expect(find.text('23 Nov'), findsNothing);
    });

    testWidgets('a mineral, then "Any" again; the period is kept', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      await tester.tap(chip(AppText.last30Days));
      await tester.pumpAndSettle();

      await tapVisible(tester, chip(AppText.cobalt));
      expect(queryOf(server.received.last), {
        'from': '2026-10-25',
        'to': '2026-11-23',
        'mineral': 'cobalt',
      });

      await tapVisible(tester, chip(AppText.filterAny));
      expect(queryOf(server.received.last), {
        'from': '2026-10-25',
        'to': '2026-11-23',
      });
    });

    testWidgets('the chosen chip again reads nothing', (tester) async {
      await openDashboard(tester, size: tall);

      await tester.tap(chip(AppText.last7Days));
      await tester.pumpAndSettle();
      expect(server.received, hasLength(1));
    });

    testWidgets('while a new choice loads, the last answer stays with a bar', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      server.hold = Completer<void>();
      await tester.tap(chip(AppText.last30Days));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('21 steps recorded'), findsOneWidget);
      expect(
        tester.widget<ChoiceChip>(chip(AppText.last30Days)).selected,
        isTrue,
      );

      server.hold!.complete();
      server.hold = null;
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('an answer to an older choice that comes last is dropped', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      final waiting = <Completer<void>>[];
      server.answer = (request) async {
        final gate = Completer<void>();
        waiting.add(gate);
        await gate.future;
        final q = request.url.queryParameters;
        return json200(dashboardJson(from: q['from']!, to: q['to']!));
      };

      await tester.tap(chip(AppText.last30Days));
      await tester.pump();
      await tester.tap(chip(AppText.last12Months));
      await tester.pump();
      expect(waiting, hasLength(2));

      // The newer answer first, then the older one.
      waiting[1].complete();
      await tester.pumpAndSettle();
      waiting[0].complete();
      await tester.pumpAndSettle();

      expect(find.text(AppText.stepsPerWeek), findsOneWidget);
      expect(
        find.text(
          AppText.dashboardDays(
            DateTime.utc(2025, 11, 24),
            DateTime.utc(2026, 11, 23),
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ChoiceChip>(chip(AppText.last12Months)).selected,
        isTrue,
      );
    });
  });

  group('refresh', () {
    testWidgets('the button reads the same choice again', (tester) async {
      await openDashboard(tester, size: tall);
      server.build = (from, to, mineral) =>
          dashboardJson(from: from, to: to, openAlerts: 1);
      await tester.tap(find.byTooltip(AppText.refreshDashboard));
      await tester.pumpAndSettle();

      expect(server.received, hasLength(2));
      expect(queryOf(server.received[1]), queryOf(server.received[0]));
      expect(find.text('1 open alert'), findsOneWidget);
    });

    testWidgets('pulling the page down reads it again', (tester) async {
      // A phone-sized screen: on the tall one the drag has no room.
      await openDashboard(tester);
      await tester.fling(
        find.text(AppText.dashboardPeriod),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(server.received, hasLength(2));
    });

    testWidgets('a failed refresh keeps the answer and says why', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      server.answer = (_) => throw const SocketException('test');
      await tester.tap(find.byTooltip(AppText.refreshDashboard));
      await tester.pumpAndSettle();

      expect(find.text('21 steps recorded'), findsOneWidget);
      expect(snack(AppText.noConnection), findsOneWidget);
    });

    testWidgets('a failed new choice keeps the last answer and its chip', (
      tester,
    ) async {
      await openDashboard(tester, size: tall);
      server.answer = (_) => throw const SocketException('test');
      await tester.tap(chip(AppText.last30Days));
      await tester.pumpAndSettle();

      expect(find.text('21 steps recorded'), findsOneWidget);
      expect(
        tester.widget<ChoiceChip>(chip(AppText.last7Days)).selected,
        isTrue,
      );
      expect(snack(AppText.noConnection), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('offline: the sentence and "Try again"', (tester) async {
      server.answer = (_) => throw const SocketException('test');
      await openDashboard(tester, size: tall);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.answer = null;
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );
      expect(find.text('21 steps recorded'), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      server.answer = (_) => throw const HandshakeException('test');
      await openDashboard(tester, size: tall);
      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('an answer that is not the documented shape', (tester) async {
      server.answer = (_) => json200({'period': 'last week'});
      await openDashboard(tester, size: tall);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('token expired: the password first, then the dashboard', (
      tester,
    ) async {
      await openDashboard(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.officer)),
        size: tall,
      );
      expect(find.text(AppText.dashboardNeedsPassword), findsOneWidget);
      expect(server.received, isEmpty);

      await tapVisible(
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
      expect(find.text('21 steps recorded'), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('7 days top to bottom: $name', (tester) async {
        await openDashboard(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(AppText.stepsPerDay));
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text('ZCAS Campus (demo)'));
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(severityWord(AlertSeverity.low)));
        expect(tester.takeException(), isNull);
      });

      // The chip is chosen first, at the top: scrollTo only scrolls down.
      testWidgets('12 months, a bar per week: $name', (tester) async {
        await openDashboard(tester, size: size, textScale: scale);
        await scrollToAndTap(
          tester,
          chip(AppText.last12Months),
          scrollable: pageScrollable,
        );
        await tester.pumpAndSettle();
        await toPart(tester, find.text(AppText.stepsPerWeek));
        expect(tester.takeException(), isNull);
        await toPart(tester, find.text(severityWord(AlertSeverity.low)));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
