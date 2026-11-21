// TEST ONLY: shared steps for the "Accounts" page tests (admin accounts plan,
// T2–T5): open the list as an administrator the way a user does (the
// "Accounts" tile), pick a status, open one account from its card, and find
// things in the list, on the page or in a dialog.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_accounts_server.dart';
import '../../../fakes/fake_controllers.dart';

late FakeAccountsServer server;
late AppHarness app;

/// "Now" in every page test: before the fake codes' expiry (24 Nov, 09:00
/// UTC), after the "expired" one used in the list tests (20 Nov).
final fixedNow = DateTime.utc(2026, 11, 21, 9);

/// The four sizes every screen is checked at.
const sizes = [
  ('portrait 360x640', Size(360, 640), 1.0),
  ('landscape 640x360', Size(640, 360), 1.0),
  ('portrait, text 2.0', Size(360, 640), 2.0),
  ('landscape, text 2.0', Size(640, 360), 2.0),
];

/// Starts the app as an administrator and opens "Accounts" from the home.
/// [list] picks another chip than "Active".
Future<void> openAccounts(
  WidgetTester tester, {
  AuthState? auth,
  String? list,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.admin)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      clockProvider.overrideWithValue(() => fixedNow),
    ],
  );
  await tapVisible(tester, find.text(AppText.accounts));
  if (list != null) await pickList(tester, list);
}

Future<void> pickList(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await tester.pumpAndSettle();
}

Finder get listScrollable => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

/// The card with [id]'s key.
Finder cardOf(String id) => find.byKey(ValueKey(id));

/// Opens the list (on [list]), then the account [id] from its card. The
/// card's first text is tapped: at text 2.0 in landscape a card can be
/// taller than the screen, so its centre may be off it.
Future<void> openAccount(
  WidgetTester tester,
  String id, {
  String? list,
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await openAccounts(
    tester,
    list: list,
    auth: auth,
    size: size,
    textScale: textScale,
  );
  // To the card first: a lazy list has not built it yet, and a `.first`
  // finder throws while nothing matches.
  await scrollTo(tester, cardOf(id), scrollable: listScrollable);
  await scrollToAndTap(
    tester,
    find.descendant(of: cardOf(id), matching: find.byType(Text)).first,
    scrollable: listScrollable,
  );
}

/// The account page's own Scrollable, never a dialog's or a text field's.
Finder get pageScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('account-page')),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the account page to [finder] and taps it.
Future<void> tapOnPage(WidgetTester tester, Finder finder) =>
    scrollToAndTap(tester, finder, scrollable: pageScrollable);

/// A button on the account page by its words.
Finder pageButton(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);

/// The open dialog.
Finder get dialog => find.byType(AlertDialog);

/// Something inside the open dialog.
Finder inDialog(Finder finder) => find.descendant(of: dialog, matching: finder);

/// The dialog's text field.
Finder get dialogField => inDialog(find.byType(TextField));

/// A dialog button by its words.
Finder dialogButton(String label) => inDialog(
  find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  ),
);

/// The snack bar's message.
Finder snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));
