// The "GPS zones" list inside the real app and router, with the fake zones
// server behind the real repository and ApiClient (GPS zones plan, T2): the
// two lists, every card line, the no-active-zone card, paging, refresh, the
// failure states, and fitting small screens and large text.

import 'dart:io' show HandshakeException, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/zones_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_zones_server.dart';
import 'zone_page_helpers.dart';

void main() {
  setUp(() => zones = FakeZonesServer());

  group('the active list', () {
    testWidgets('opened from the tile; cards by name, every line', (
      tester,
    ) async {
      await openZones(tester);
      expect(zonesApp.path, AppRoutes.adminZones);

      final sent = zones.lists.single;
      expect(sent.url.queryParameters, {
        'status': 'active',
        'limit': '20',
        'offset': '0',
      });
      expect(
        find.text(AppText.zonesCount(status: 'active', shown: 2, total: 2)),
        findsOneWidget,
      );
      // By name: Kasempa North before ZCAS Campus (demo).
      expect(
        tester.getTopLeft(zoneCard(zoneId(1))).dy,
        lessThan(tester.getTopLeft(zoneCard(zoneId(2))).dy),
      );
      expect(inZoneCard(zoneId(1), 'Kasempa North'), findsOneWidget);
      expect(inZoneCard(zoneId(1), 'DEMO-LML-0001'), findsOneWidget);
      expect(inZoneCard(zoneId(1), '3 corners'), findsOneWidget);
      expect(inZoneCard(zoneId(1), 'Created 10 Nov 2026'), findsOneWidget);
      expect(inZoneCard(zoneId(2), AppText.noLicenceNumber), findsOneWidget);
      // The inactive zone is not in this list, and nothing warns.
      expect(zoneCard(zoneId(3)), findsNothing);
      expect(find.byType(NoActiveZoneCard), findsNothing);
    });

    testWidgets('one zone: "1 active zone."', (tester) async {
      zones.zones
        ..clear()
        ..add(zoneJson(1));
      await openZones(tester);
      expect(find.text('1 active zone.'), findsOneWidget);
    });

    testWidgets('the create button is there', (tester) async {
      await openZones(tester);
      expect(
        find.widgetWithText(FloatingActionButton, AppText.createZone),
        findsOneWidget,
      );
    });
  });

  group('the inactive list', () {
    testWidgets('asks for inactive zones and shows them', (tester) async {
      await openZones(tester, list: AppText.zonesInactive);
      expect(zones.lists.last.url.queryParameters['status'], 'inactive');
      expect(inZoneCard(zoneId(3), 'Mumbwa East'), findsOneWidget);
      expect(find.text('1 inactive zone.'), findsOneWidget);
      expect(zoneCard(zoneId(1)), findsNothing);
    });

    testWidgets('empty: its own words', (tester) async {
      zones.zones.removeWhere((z) => z['status'] == 'inactive');
      await openZones(tester, list: AppText.zonesInactive);
      expect(find.text(AppText.noZones('inactive')), findsOneWidget);
    });
  });

  group('no active zone (Q4)', () {
    setUp(() {
      zones = FakeZonesServer([zoneJson(3, status: 'inactive')]);
    });

    testWidgets('the warning card and the empty sentence', (tester) async {
      await openZones(tester);
      expect(find.byType(NoActiveZoneCard), findsOneWidget);
      expect(find.text(AppText.noActiveZone), findsOneWidget);
      expect(find.text(AppText.noZones('active')), findsOneWidget);
    });

    testWidgets('still shown on the inactive list', (tester) async {
      await openZones(tester, list: AppText.zonesInactive);
      expect(find.byType(NoActiveZoneCard), findsOneWidget);
    });

    testWidgets('gone once a zone is active again', (tester) async {
      await openZones(tester);
      zones.zones.single['status'] = 'active';
      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();
      expect(find.byType(NoActiveZoneCard), findsNothing);
    });
  });

  group('paging', () {
    setUp(() {
      zones = FakeZonesServer([
        // Names that sort as their numbers do.
        for (var n = 1; n <= 25; n++)
          zoneJson(n, name: 'Zone ${n.toString().padLeft(2, '0')}'),
      ]);
    });

    testWidgets('"Show more" adds the next page', (tester) async {
      await openZones(tester);
      expect(
        find.text(AppText.zonesCount(status: 'active', shown: 20, total: 25)),
        findsOneWidget,
      );
      await scrollToAndTap(
        tester,
        find.text(AppText.showMore),
        scrollable: zonesScrollable,
      );
      expect(zones.lists.last.url.queryParameters['offset'], '20');
      expect(find.text(AppText.showMore), findsNothing);
      await scrollTo(tester, zoneCard(zoneId(25)), scrollable: zonesScrollable);
      expect(zoneCard(zoneId(25)), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('pulling the list down reads it again', (tester) async {
      await openZones(tester);
      zones.zones.add(zoneJson(9, name: 'Lufwanyama'));
      await tester.fling(
        find.text('Kasempa North'),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(zones.lists, hasLength(2));
      expect(
        find.text(AppText.zonesCount(status: 'active', shown: 3, total: 3)),
        findsOneWidget,
      );
    });

    testWidgets('a failed refresh keeps the list and says why', (tester) async {
      await openZones(tester);
      zones.answers['list'] = (_) => throw const SocketException('test');
      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();
      expect(zoneCard(zoneId(1)), findsOneWidget);
      expect(snack(AppText.noConnection), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('offline: the sentence and "Try again"', (tester) async {
      zones.answers['list'] = (_) => throw const SocketException('test');
      await openZones(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      zones.answers.remove('list');
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );
      expect(zoneCard(zoneId(1)), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      zones.answers['list'] = (_) => throw const HandshakeException('test');
      await openZones(tester);
      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('an odd answer', (tester) async {
      zones.answers['list'] = (_) => json200({'zones': 'none'});
      await openZones(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('token expired: the password first, then the list', (
      tester,
    ) async {
      await openZones(tester, auth: SignedInNeedsPassword(userOf(Role.admin)));
      expect(find.text(AppText.zonesNeedPassword), findsOneWidget);
      expect(zones.received, isEmpty);

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
      expect(zoneCard(zoneId(1)), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the active list: $name', (tester) async {
        await openZones(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          zoneCard(zoneId(2)),
          scrollable: zonesScrollable,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('a long name and the warning card: $name', (tester) async {
        zones = FakeZonesServer([
          zoneJson(
            1,
            name:
                'Kasempa North extension along the river, licence area two '
                '(until November 2026)',
            licenceNumber: 'DEMO-LML-0001-EXTENSION-AREA-TWO-NORTH',
            status: 'inactive',
          ),
        ]);
        await openZones(
          tester,
          list: AppText.zonesInactive,
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          zoneCard(zoneId(1)),
          scrollable: zonesScrollable,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
