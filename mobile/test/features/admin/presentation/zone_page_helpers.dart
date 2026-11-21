// TEST ONLY: shared steps for the "GPS zones" page tests (GPS zones plan,
// T2–T5): open the list as an administrator the way a user does (the "GPS
// zones" tile), pick a status, open one zone from its card, and find things
// in the list, on the page or in a dialog.
//
// The dialog and snack-bar finders are the accounts helpers' own, shared.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_zones_server.dart';

export 'account_page_helpers.dart'
    show dialog, dialogButton, dialogField, inDialog, pageButton, sizes, snack;

late FakeZonesServer zones;
late AppHarness zonesApp;

/// Starts the app as an administrator and opens "GPS zones" from the home.
/// [list] picks "Inactive".
Future<void> openZones(
  WidgetTester tester, {
  AuthState? auth,
  String? list,
  Size size = const Size(360, 640),
  double textScale = 1.0,
  List<Override> extraOverrides = const [],
}) async {
  zonesApp = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.admin)),
    size: size,
    textScale: textScale,
    overrides: [
      ...zones.overrides(),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 21, 9)),
      ...extraOverrides,
    ],
  );
  await tapVisible(tester, find.text(AppText.gpsZones));
  if (list != null) {
    await tester.tap(find.widgetWithText(ChoiceChip, list));
    await tester.pumpAndSettle();
  }
}

/// Opens the list (on [list]), then the zone [id] from its card.
Future<void> openZone(
  WidgetTester tester,
  String id, {
  String? list,
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await openZones(
    tester,
    list: list,
    auth: auth,
    size: size,
    textScale: textScale,
  );
  await scrollTo(tester, zoneCard(id), scrollable: zonesScrollable);
  await scrollToAndTap(
    tester,
    find.descendant(of: zoneCard(id), matching: find.byType(Text)).first,
    scrollable: zonesScrollable,
  );
}

/// The list's own Scrollable.
Finder get zonesScrollable => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

/// The card with [id]'s key.
Finder zoneCard(String id) => find.byKey(ValueKey(id));

/// A text inside the card [id].
Finder inZoneCard(String id, String text) =>
    find.descendant(of: zoneCard(id), matching: find.text(text));

/// The zone page's own Scrollable, never a dialog's or a text field's.
Finder get zonePageScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('zone-page')),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the zone page to [finder] and taps it.
Future<void> tapOnZonePage(WidgetTester tester, Finder finder) =>
    scrollToAndTap(tester, finder, scrollable: zonePageScrollable);
