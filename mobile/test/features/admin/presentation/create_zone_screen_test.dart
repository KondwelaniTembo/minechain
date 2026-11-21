// "Create zone" inside the real app and router (GPS zones plan §4.3, T5):
// typed corners and their problems, "Add my location" with the fix policy,
// the live sketch, the exact body sent, the server's messages on the corner
// or field they name, leaving with unsaved work, and fitting small screens
// and large text.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/create_zone_controller.dart';
import 'package:minechain/features/admin/presentation/zone_shape_view.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';
import 'package:minechain/features/registration/data/location_source.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart';
import '../../../fakes/fake_zones_server.dart';
import 'zone_page_helpers.dart';

/// The tests' clock (zone_page_helpers.dart): a reading at this time is
/// fresh.
final now = DateTime.utc(2026, 11, 21, 9);

late FakeLocationSource gps;

Future<void> openCreate(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
  AuthState? auth,
}) async {
  await openZones(
    tester,
    size: size,
    textScale: textScale,
    auth: auth,
    extraOverrides: [locationSourceProvider.overrideWithValue(gps)],
  );
  await tester.tap(find.text(AppText.createZone));
  await tester.pumpAndSettle();
}

Finder get formScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('create-zone')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> tapOnForm(WidgetTester tester, Finder finder) =>
    scrollToAndTap(tester, finder, scrollable: formScrollable);

/// Taps "Add my location". Not settled afterwards: while the GPS looks, a
/// spinner turns, so the screen never goes still (CLAUDE.md, the widget-test
/// rules).
Future<void> startLocating(WidgetTester tester) async {
  await scrollTo(
    tester,
    button(AppText.addMyLocation),
    scrollable: formScrollable,
  );
  await tester.tap(button(AppText.addMyLocation));
  await tester.pump();
  await tester.pump();
}

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);

bool enabled(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(button(label).first).onPressed != null;

Future<void> typeName(WidgetTester tester, String name) =>
    typeInto(tester, find.byKey(const ValueKey('zone-name')), name);

/// Types one corner through the dialog and taps Add.
Future<void> typeCorner(WidgetTester tester, String text) async {
  await tapOnForm(tester, button(AppText.typeACorner));
  await tester.enterText(dialogField, text);
  await tester.pumpAndSettle();
  await tester.tap(dialogButton(AppText.addCorner));
  await tester.pumpAndSettle();
}

Future<void> typeTriangle(WidgetTester tester) async {
  await typeCorner(tester, '-13.45, 25.82');
  await typeCorner(tester, '-13.47, 25.86');
  await typeCorner(tester, '-13.49, 25.81');
}

/// The corner row [number] (from 1).
Finder corner(int number) => find.byKey(ValueKey('corner-${number - 1}'));

Finder inCorner(int number, String text) =>
    find.descendant(of: corner(number), matching: find.text(text));

String? errorUnder(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).decoration!.errorText;

CreateZoneController controller() =>
    zonesApp.container.read(createZoneControllerProvider.notifier);

void main() {
  setUp(() {
    zones = FakeZonesServer();
    gps = FakeLocationSource();
  });

  group('typed corners', () {
    testWidgets('a triangle: the exact body, then back on the Active list '
        'with the new zone', (tester) async {
      await openCreate(tester);
      expect(zonesApp.path, AppRoutes.adminCreateZone);
      await typeName(tester, '  Kafue Gorge ');
      await typeInto(
        tester,
        find.byKey(const ValueKey('zone-licence')),
        ' DEMO-LML-0009 ',
      );
      await typeTriangle(tester);

      expect(inCorner(1, '-13.45, 25.82'), findsOneWidget);
      expect(inCorner(3, '-13.49, 25.81'), findsOneWidget);
      expect(find.byType(ZoneShapeView), findsOneWidget);

      await tapOnForm(tester, button(AppText.createZone).last);

      expect(
        zones.creates.single.body,
        '{"name":"Kafue Gorge","licenceNumber":"DEMO-LML-0009",'
        '"boundary":[[-13.45,25.82],[-13.47,25.86],[-13.49,25.81]]}',
      );
      expect(zonesApp.path, AppRoutes.adminZones);
      expect(snack(AppText.zoneCreated('Kafue Gorge')), findsOneWidget);
      expect(find.text('Kafue Gorge'), findsOneWidget);
    });

    testWidgets('no licence number: the field is left out', (tester) async {
      await openCreate(tester);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await tapOnForm(tester, button(AppText.createZone).last);
      final body = jsonDecode(zones.creates.single.body) as Map;
      expect(body.keys, ['name', 'boundary']);
    });

    final problems = {
      '-15.418327': AppText.cornerNotTwoNumbers,
      '-15.4183274, 28.289494': AppText.cornerTooManyDecimals,
      '-95, 28': AppText.cornerLatitudeRange,
      '-15, 190': AppText.cornerLongitudeRange,
    };
    problems.forEach((typed, sentence) {
      testWidgets('"$typed": the dialog stays and says why', (tester) async {
        await openCreate(tester);
        await typeCorner(tester, typed);
        expect(dialog, findsOneWidget);
        expect(inDialog(find.text(sentence)), findsOneWidget);
        expect(corner(1), findsNothing);
      });
    });

    testWidgets('a corrected corner is added and the dialog closes', (
      tester,
    ) async {
      await openCreate(tester);
      await typeCorner(tester, '-15.41, 28.28, 3');
      expect(dialog, findsOneWidget);
      await tester.enterText(dialogField, '-15.41, 28.28');
      await tester.pumpAndSettle();
      await tester.tap(dialogButton(AppText.addCorner));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(inCorner(1, '-15.41, 28.28'), findsOneWidget);
    });

    testWidgets('Create needs a name and 3 corners; no sketch before 3', (
      tester,
    ) async {
      await openCreate(tester);
      expect(find.text(AppText.noCornersYet), findsOneWidget);
      await typeCorner(tester, '-13.45, 25.82');
      await typeCorner(tester, '-13.47, 25.86');
      await typeName(tester, 'Kafue Gorge');
      expect(find.byType(ZoneShapeView), findsNothing);
      expect(enabled(tester, AppText.createZone), isFalse);

      await typeCorner(tester, '-13.49, 25.81');
      expect(enabled(tester, AppText.createZone), isTrue);

      await typeName(tester, '');
      expect(enabled(tester, AppText.createZone), isFalse);
    });

    testWidgets('a name under 3 characters is not sent', (tester) async {
      await openCreate(tester);
      await typeName(tester, ' K2 ');
      await typeTriangle(tester);
      await tapOnForm(tester, button(AppText.createZone).last);
      expect(zones.creates, isEmpty);
      expect(errorUnder(tester, 'zone-name'), AppText.zoneNameTooShort);
    });

    testWidgets('a corner can be removed', (tester) async {
      await openCreate(tester);
      await typeTriangle(tester);
      await tapOnForm(tester, find.byTooltip(AppText.removeCorner(2)));
      expect(inCorner(1, '-13.45, 25.82'), findsOneWidget);
      expect(inCorner(2, '-13.49, 25.81'), findsOneWidget);
      expect(corner(3), findsNothing);
    });

    testWidgets('at 100 corners nothing more can be added', (tester) async {
      await openCreate(tester);
      for (var i = 0; i < 100; i++) {
        controller().addTyped('-13.${i.toString().padLeft(2, '0')}, 25.8');
      }
      await tester.pumpAndSettle();
      // A 101st is refused even if asked for.
      controller().addTyped('-14, 26');
      await tester.pumpAndSettle();
      expect(
        zonesApp.container.read(createZoneControllerProvider).corners,
        hasLength(100),
      );
      await scrollTo(
        tester,
        find.text(AppText.maxCornersReached),
        scrollable: formScrollable,
      );
      expect(enabled(tester, AppText.addMyLocation), isFalse);
      expect(enabled(tester, AppText.typeACorner), isFalse);
    });
  });

  group('"Add my location" (Q1)', () {
    testWidgets('the location is not asked for until the tap', (tester) async {
      await openCreate(tester);
      expect(gps.accessChecks, 0);
      await startLocating(tester);
      expect(gps.accessChecks, 1);
      expect(gps.listening, isTrue);
    });

    testWidgets('a usable reading is added, rounded to 6 places, and the GPS '
        'stops', (tester) async {
      await openCreate(tester);
      await startLocating(tester);
      gps.emit(reading(now));
      await tester.pumpAndSettle();

      // reading(): -15.4190123, 28.2881049.
      expect(inCorner(1, '-15.419012, 28.288105'), findsOneWidget);
      expect(gps.listening, isFalse);
      expect(find.byKey(const ValueKey('locating')), findsNothing);
    });

    testWidgets('too inaccurate, stale or fake: not added, and why', (
      tester,
    ) async {
      await openCreate(tester);
      await startLocating(tester);

      gps.emit(reading(now, accuracyM: 40));
      await tester.pump();
      expect(find.text(AppText.findingLocation(40)), findsOneWidget);

      gps.emit(reading(now.subtract(const Duration(minutes: 2))));
      await tester.pump();
      expect(corner(1), findsNothing);

      gps.emit(reading(now, mocked: true));
      await tester.pump();
      expect(find.text(AppText.fakeLocation), findsOneWidget);
      expect(corner(1), findsNothing);

      // Stop: nothing added, the buttons back.
      await tester.tap(find.text(AppText.stopLocating));
      await tester.pumpAndSettle();
      expect(gps.listening, isFalse);
      expect(corner(1), findsNothing);
      expect(button(AppText.addMyLocation), findsOneWidget);
    });

    testWidgets('location refused for good: the sentence and the settings', (
      tester,
    ) async {
      gps.access = LocationAccess.deniedForever;
      await openCreate(tester);
      await startLocating(tester);
      expect(find.text(AppText.locationRefused), findsOneWidget);
      await tester.tap(find.text(AppText.openSettings));
      await tester.pump();
      expect(gps.appSettingsOpened, 1);
    });

    testWidgets('location off: its own words', (tester) async {
      gps.access = LocationAccess.serviceOff;
      await openCreate(tester);
      await startLocating(tester);
      expect(find.text(AppText.zoneLocationOff), findsOneWidget);
    });

    testWidgets('Create and "Type a corner" are off while looking', (
      tester,
    ) async {
      await openCreate(tester);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await startLocating(tester);
      expect(enabled(tester, AppText.createZone), isFalse);
      expect(enabled(tester, AppText.typeACorner), isFalse);
    });
  });

  group("the server's messages", () {
    testWidgets('on the corner they name; the shape under the list', (
      tester,
    ) async {
      zones.answers['create'] = (_) => boundaryRefusal({
        'boundary.3': 'repeats the first corner; list each corner once',
        'boundary.1.0': 'must have at most 6 decimal places',
        'boundary': 'must enclose at least 100 square metres',
      });
      await openCreate(tester);
      await typeName(tester, 'Closed ring');
      await typeTriangle(tester);
      await typeCorner(tester, '-13.45, 25.82');
      await tapOnForm(tester, button(AppText.createZone).last);

      expect(
        inCorner(4, 'repeats the first corner; list each corner once'),
        findsOneWidget,
      );
      expect(inCorner(2, 'must have at most 6 decimal places'), findsOneWidget);
      expect(
        find.text('must enclose at least 100 square metres'),
        findsOneWidget,
      );
      expect(zonesApp.path, AppRoutes.adminCreateZone);

      // Removing a corner moves the others: the old messages go.
      await tapOnForm(tester, find.byTooltip(AppText.removeCorner(4)));
      expect(
        find.text('repeats the first corner; list each corner once'),
        findsNothing,
      );
      expect(
        find.text('must enclose at least 100 square metres'),
        findsNothing,
      );
    });

    testWidgets('a swapped corner: "is outside Zambia" on it', (tester) async {
      const outside =
          'is outside Zambia; each corner must be [latitude, longitude], '
          'latitude first';
      zones.answers['create'] = (_) => boundaryRefusal({'boundary.0': outside});
      await openCreate(tester);
      await typeName(tester, 'Swapped');
      await typeCorner(tester, '25.82, -13.45');
      await typeCorner(tester, '-13.47, 25.86');
      await typeCorner(tester, '-13.49, 25.81');
      await tapOnForm(tester, button(AppText.createZone).last);
      expect(inCorner(1, outside), findsOneWidget);
    });

    testWidgets("ZONE_NAME_TAKEN: the server's sentence under the name", (
      tester,
    ) async {
      await openCreate(tester);
      await typeName(tester, 'mumbwa east');
      await typeTriangle(tester);
      await tapOnForm(tester, button(AppText.createZone).last);
      expect(errorUnder(tester, 'zone-name'), zoneNameTakenMessage);
      expect(zonesApp.path, AppRoutes.adminCreateZone);
    });

    testWidgets('a refusal about no field shown: above the button', (
      tester,
    ) async {
      zones.answers['create'] = (_) =>
          refusal(403, ApiCodes.forbidden, 'Forbidden.');
      await openCreate(tester);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await tapOnForm(tester, button(AppText.createZone).last);
      expect(find.text(AppText.notAllowed), findsOneWidget);
    });

    testWidgets('the session ran out: the password, then the same zone', (
      tester,
    ) async {
      zones.answers['create'] = (request) {
        zones.answers.remove('create');
        zonesApp.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
        return refusal(401, ApiCodes.tokenExpired, 'Token expired.');
      };
      await openCreate(tester);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await tapOnForm(tester, button(AppText.createZone).last);

      final prompt = find.byType(PasswordPromptDialog);
      expect(prompt, findsOneWidget);
      await tester.enterText(
        find.descendant(of: prompt, matching: find.byType(TextField)),
        fakePassword,
      );
      await tester.tap(
        find.descendant(
          of: prompt,
          matching: find.widgetWithText(FilledButton, AppText.continueLabel),
        ),
      );
      await tester.pumpAndSettle();

      expect(zones.creates, hasLength(2));
      expect(zones.creates.last.body, zones.creates.first.body);
      expect(zonesApp.path, AppRoutes.adminZones);
    });
  });

  group('leaving', () {
    testWidgets('with nothing typed: straight back', (tester) async {
      await openCreate(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(zonesApp.path, AppRoutes.adminZones);
    });

    testWidgets('with a corner: asks first; Stay keeps it, Leave goes', (
      tester,
    ) async {
      await openCreate(tester);
      await typeCorner(tester, '-13.45, 25.82');

      await pressAndroidBack(tester);
      expect(inDialog(find.text(AppText.leaveZoneQuestion)), findsOneWidget);
      await tester.tap(dialogButton(AppText.stay));
      await tester.pumpAndSettle();
      expect(inCorner(1, '-13.45, 25.82'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton(AppText.leave));
      await tester.pumpAndSettle();
      expect(zonesApp.path, AppRoutes.adminZones);
      expect(zones.creates, isEmpty);
    });
  });

  testWidgets('no corner, name or reading in any log line', (tester) async {
    final logged = <String>[];
    final before = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };
    // Put back inside the test: the framework checks it is unchanged before
    // any tear-down runs.
    try {
      await openCreate(tester);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await startLocating(tester);
      gps.emit(reading(now));
      await tester.pumpAndSettle();
      await tapOnForm(tester, button(AppText.createZone).last);
    } finally {
      debugPrint = before;
    }
    expect(zones.creates, hasLength(1));

    final all = logged.join('\n');
    for (final secret in ['Kafue', '13.45', '25.82', '15.419', '28.288']) {
      expect(all, isNot(contains(secret)), reason: secret);
    }
  });

  group('the remove button sits on the corner\'s line (T6b)', () {
    // Wide enough for "Corner 1" and its coordinates on one line in the test
    // font, whose letters are all as wide as they are tall; the A57 fits
    // them in 360 dp. At large text the two wrap, which is checked for
    // overflow only, below.
    const wide = Size(480, 800);

    /// How far the remove icon's middle is from the corner text's middle.
    double offset(WidgetTester tester, int number, String text) {
      final icon = find.descendant(
        of: corner(number),
        matching: find.byIcon(Icons.remove_circle_outline),
      );
      return (tester.getCenter(icon).dy -
              tester.getCenter(inCorner(number, text)).dy)
          .abs();
    }

    testWidgets('level with the coordinates', (tester) async {
      await openCreate(tester, size: wide);
      await typeTriangle(tester);
      expect(offset(tester, 1, AppText.cornerNumber(1)), lessThan(1));
      expect(offset(tester, 1, '-13.45, 25.82'), lessThan(1));
      expect(offset(tester, 3, '-13.49, 25.81'), lessThan(1));
    });

    testWidgets('still level with the coordinates when an error is under '
        'them', (tester) async {
      zones.answers['create'] = (_) =>
          boundaryRefusal({'boundary.3': 'repeats the first corner'});
      await openCreate(tester, size: wide);
      await typeName(tester, 'Kafue Gorge');
      await typeTriangle(tester);
      await typeCorner(tester, '-13.45, 25.82');
      await tapOnForm(tester, button(AppText.createZone).last);
      expect(inCorner(4, 'repeats the first corner'), findsOneWidget);
      expect(offset(tester, 4, '-13.45, 25.82'), lessThan(1));
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('four corners, the sketch and a message: $name', (
        tester,
      ) async {
        zones.answers['create'] = (_) => boundaryRefusal({
          'boundary.3':
              'repeats the first corner; list each corner once, '
              'without repeating the first corner at the end',
        });
        await openCreate(tester, size: size, textScale: scale);
        await typeName(tester, 'Kafue Gorge');
        await typeTriangle(tester);
        await typeCorner(tester, '-13.45, 25.82');
        await tapOnForm(tester, button(AppText.createZone).last);
        expect(tester.takeException(), isNull);
        await scrollTo(
          tester,
          find.byType(ZoneShapeView),
          scrollable: formScrollable,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('looking for the location: $name', (tester) async {
        gps.access = LocationAccess.deniedOnce;
        await openCreate(tester, size: size, textScale: scale);
        await startLocating(tester);
        expect(tester.takeException(), isNull);
        expect(find.text(AppText.zoneLocationNeeded), findsOneWidget);
      });
    }
  });
}
