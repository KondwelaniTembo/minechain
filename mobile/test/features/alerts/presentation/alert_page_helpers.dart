// TEST ONLY: shared steps for the alert page and decision tests (officer
// alerts plan, T3 and T4): open the list as an officer, open one alert the
// way an officer does (a tap on its card), and find things on the page or in
// the decision dialog.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/alerts/presentation/alert_detail_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_alerts_server.dart';
import '../../../fakes/fake_controllers.dart';

late FakeAlertsServer server;
late AppHarness app;

/// The four sizes every screen is checked at.
const sizes = [
  ('portrait 360x640', Size(360, 640), 1.0),
  ('landscape 640x360', Size(640, 360), 1.0),
  ('portrait, text 2.0', Size(360, 640), 2.0),
  ('landscape, text 2.0', Size(640, 360), 2.0),
];

/// Starts the app as an officer and opens the alerts list from the home.
/// [list] picks "Confirmed" or "Cleared" instead of "Open".
Future<void> openList(
  WidgetTester tester, {
  AuthState? auth,
  String? list,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.officer)),
    size: size,
    textScale: textScale,
    overrides: server.overrides(),
  );
  await tapVisible(tester, find.text(AppText.alerts));
  if (list != null) {
    await tester.tap(find.widgetWithText(ChoiceChip, list));
    await tester.pumpAndSettle();
  }
}

Finder get listScrollable => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

/// Taps the card that names [qrCode].
Future<void> tapCard(WidgetTester tester, String qrCode) => scrollToAndTap(
  tester,
  find.ancestor(of: find.textContaining(qrCode), matching: find.byType(Card)),
  scrollable: listScrollable,
);

/// Opens the list, then alert number [alert] (as in alertJson) from its card.
Future<void> openAlert(
  WidgetTester tester, {
  int alert = 1,
  String? list,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await openList(tester, list: list, size: size, textScale: textScale);
  // The card's heading, its first text: in landscape at text 2.0 the card is
  // taller than the screen, so its centre may be off it.
  await scrollToAndTap(
    tester,
    find
        .descendant(
          of: find.byKey(ValueKey(alertId(alert))),
          matching: find.byType(Text),
        )
        .first,
    scrollable: listScrollable,
  );
}

/// The alert page's own Scrollable, never a dialog's or a text field's.
Finder get pageScrollable => find
    .descendant(
      of: find.byType(AlertDetailScreen),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the page down until [finder] is on screen.
Future<void> toPart(WidgetTester tester, Finder finder) =>
    scrollTo(tester, finder, scrollable: pageScrollable);

/// Any Material button labelled [label].
Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Finder get dialog => find.byType(AlertDialog);

Finder dialogButton(String label) =>
    find.descendant(of: dialog, matching: button(label));

Finder get notesField =>
    find.descendant(of: dialog, matching: find.byType(TextField));

bool enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

/// Opens the decision dialog from the page's button [label].
Future<void> startDecision(WidgetTester tester, String label) async {
  await toPart(tester, button(label));
  await tester.tap(button(label));
  await tester.pumpAndSettle();
}
