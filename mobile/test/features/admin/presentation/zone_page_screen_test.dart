// One zone's page inside the real app and router (GPS zones plan, T3): every
// line, the sketch, the corners in the server's order, the fixed-boundary
// line, the buttons by status, a page opened without a zone, and fitting
// small screens and large text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/domain/gps_zone.dart';
import 'package:minechain/features/admin/presentation/zone_page_screen.dart';
import 'package:minechain/features/admin/presentation/zone_shape_view.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_zones_server.dart';
import 'zone_page_helpers.dart';

/// The campus demo zone's first five corners, from the seed.
const campus = [
  [-15.418327, 28.289494],
  [-15.418544, 28.288],
  [-15.418775, 28.28655],
  [-15.419293, 28.286608],
  [-15.419519, 28.287099],
];

void main() {
  setUp(() {
    zones = FakeZonesServer([
      zoneJson(
        1,
        name: 'ZCAS Campus (demo)',
        licenceNumber: null,
        boundary: campus,
        createdAt: '2026-11-10T09:00:00.000Z',
        updatedAt: '2026-11-12T11:30:00.000Z',
      ),
      zoneJson(2, name: 'Mumbwa East', status: 'inactive'),
    ]);
  });

  ZoneShapePainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.descendant(
                  of: find.byType(ZoneShapeView),
                  matching: find.byType(CustomPaint),
                ),
              )
              .painter!
          as ZoneShapePainter;

  group('an active zone', () {
    testWidgets('every line, in the server\'s words', (tester) async {
      await openZone(tester, zoneId(1));
      expect(zonesApp.path, AppRoutes.adminZone);
      expect(find.text(AppText.zoneTitle), findsOneWidget);
      expect(find.text('ZCAS Campus (demo)'), findsOneWidget);
      expect(find.text(AppText.zoneIsActive), findsOneWidget);
      expect(find.text(AppText.noLicenceNumber), findsOneWidget);
      // The test clock's time zone is the machine's: compare in local time.
      expect(
        find.text(
          AppText.zoneCreatedAt(DateTime.utc(2026, 11, 10, 9).toLocal()),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          AppText.zoneChangedAt(DateTime.utc(2026, 11, 12, 11, 30).toLocal()),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the corners in order, latitude first, as sent', (
      tester,
    ) async {
      await openZone(tester, zoneId(1));
      final expected = [
        '-15.418327, 28.289494',
        '-15.418544, 28.288',
        '-15.418775, 28.28655',
        '-15.419293, 28.286608',
        '-15.419519, 28.287099',
      ];
      for (var i = 0; i < expected.length; i++) {
        final row = find.byType(CornerRow).at(i);
        await scrollTo(tester, row, scrollable: zonePageScrollable);
        expect(
          find.descendant(of: row, matching: find.text(expected[i])),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text('Corner ${i + 1}')),
          findsOneWidget,
        );
      }
    });

    testWidgets('the sketch gets every corner, in order', (tester) async {
      await openZone(tester, zoneId(1));
      final shape = painter(tester);
      expect(shape.corners, [
        for (final [lat, lng] in campus)
          ZoneCorner(lat.toDouble(), lng.toDouble()),
      ]);
      expect(find.bySemanticsLabel(AppText.zoneSketchLabel(5)), findsOneWidget);
      expect(find.text(AppText.zoneSketchNote), findsOneWidget);
    });

    testWidgets('the fixed-boundary line, then Rename and Deactivate', (
      tester,
    ) async {
      await openZone(tester, zoneId(1));
      await scrollTo(
        tester,
        find.text(AppText.zoneFixedBoundary),
        scrollable: zonePageScrollable,
      );
      await scrollTo(
        tester,
        pageButton(AppText.deactivateZone),
        scrollable: zonePageScrollable,
      );
      expect(pageButton(AppText.renameZone), findsOneWidget);
      expect(pageButton(AppText.deactivateZone), findsOneWidget);
      expect(pageButton(AppText.reactivateZone), findsNothing);
    });

    testWidgets('Android back returns to the list too', (tester) async {
      await openZone(tester, zoneId(1));
      await pressAndroidBack(tester);
      expect(zonesApp.path, AppRoutes.adminZones);
    });

    testWidgets('the back arrow returns to the list, which is read again', (
      tester,
    ) async {
      await openZone(tester, zoneId(1));
      final before = zones.lists.length;
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(zonesApp.path, AppRoutes.adminZones);
      expect(zones.lists.length, before + 1);
    });
  });

  group('an inactive zone', () {
    testWidgets('its status, Rename and Reactivate', (tester) async {
      await openZone(tester, zoneId(2), list: AppText.zonesInactive);
      expect(find.text(AppText.zoneIsInactive), findsOneWidget);
      expect(find.text('DEMO-LML-0001'), findsOneWidget);
      // Never changed: no "Changed" line.
      expect(find.textContaining('Changed '), findsNothing);
      await scrollTo(
        tester,
        pageButton(AppText.reactivateZone),
        scrollable: zonePageScrollable,
      );
      expect(pageButton(AppText.renameZone), findsOneWidget);
      expect(pageButton(AppText.deactivateZone), findsNothing);
    });
  });

  group('the sketch painter', () {
    ZoneShapePainter of(List<ZoneCorner> corners) => ZoneShapePainter(
      corners: corners,
      line: Colors.black,
      fill: Colors.grey,
      dot: Colors.black,
      label: Colors.white,
      textScaler: TextScaler.noScaling,
    );

    test('north up, east right, inside the canvas', () {
      const size = Size(400, 300);
      final points = of(const [
        ZoneCorner(-15.0, 28.0), // north-west
        ZoneCorner(-15.0, 28.01), // north-east
        ZoneCorner(-15.01, 28.0), // south-west
      ]).pointsFor(size);
      expect(points, hasLength(3));
      // North-east is right of north-west, at the same height.
      expect(points[1].dx, greaterThan(points[0].dx));
      expect(points[1].dy, closeTo(points[0].dy, 0.001));
      // South-west is below north-west.
      expect(points[2].dy, greaterThan(points[0].dy));
      for (final p in points) {
        expect(p.dx, inInclusiveRange(0, size.width));
        expect(p.dy, inInclusiveRange(0, size.height));
      }
    });

    test('fewer than three corners: nothing to draw', () {
      expect(
        of(const [ZoneCorner(-15, 28), ZoneCorner(-15.1, 28.1)])
            .pointsFor(const Size(400, 300)),
        isEmpty,
      );
    });

    test('three corners in one spot: no division by zero', () {
      final points = of(const [
        ZoneCorner(-15, 28),
        ZoneCorner(-15, 28),
        ZoneCorner(-15, 28),
      ]).pointsFor(const Size(400, 300));
      for (final p in points) {
        expect(p.dx.isFinite && p.dy.isFinite, isTrue);
      }
    });

    testWidgets('the view shows nothing with two corners', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ZoneShapeView(
              corners: [ZoneCorner(-15, 28), ZoneCorner(-15.1, 28.1)],
            ),
          ),
        ),
      );
      expect(
        find.byType(CustomPaint).evaluate().where((e) {
          final w = e.widget as CustomPaint;
          return w.painter is ZoneShapePainter;
        }),
        isEmpty,
      );
    });
  });

  testWidgets('a page opened without a zone sends back to the list', (
    tester,
  ) async {
    await openZones(tester);
    // As if Android had restored the page alone: no zone was opened.
    zonesApp.container.read(appRouterProvider).go(AppRoutes.adminZone);
    await tester.pumpAndSettle();
    expect(find.text(AppText.zonePageGone), findsOneWidget);
    await tester.tap(find.text(AppText.backToZones));
    await tester.pumpAndSettle();
    expect(zonesApp.path, AppRoutes.adminZones);
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('an active zone: $name', (tester) async {
        await openZone(tester, zoneId(1), size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          pageButton(AppText.deactivateZone),
          scrollable: zonePageScrollable,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
