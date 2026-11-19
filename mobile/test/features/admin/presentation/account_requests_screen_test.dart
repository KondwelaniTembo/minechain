// The "Account requests" screen inside the real app and router, with the
// fake server behind the real repository and ApiClient: each state, approve,
// reject, refresh, and fitting small screens and large text.

import 'dart:async';
import 'dart:io' show HandshakeException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/account_requests_controller.dart';
import 'package:minechain/features/admin/presentation/account_requests_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/android_back.dart';
import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_admin_server.dart';
import '../../../fakes/fake_controllers.dart';

late FakeAdminServer server;
late AppHarness app;

/// Starts the app as an administrator and opens the screen the way a user
/// does: the "Account requests" tile on the admin home.
Future<void> openRequests(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
  bool settle = true,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.admin)),
    size: size,
    textScale: textScale,
    overrides: server.overrides(),
  );
  if (settle) {
    await tapVisible(tester, find.text(AppText.accountRequests));
  } else {
    // A spinner never stops moving, so pumpAndSettle would wait for ever:
    // draw the page transition frame by frame instead.
    await tester.tap(find.text(AppText.accountRequests));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// The card that shows [name].
Finder card(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(Card));

/// Any Material button (filled, outlined, text) labelled [label]. bySubtype
/// also matches the subclasses that the `.icon` constructors may create.
Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Finder approveIn(String name) =>
    find.descendant(of: card(name), matching: button(AppText.approve));

Finder rejectIn(String name) =>
    find.descendant(of: card(name), matching: button(AppText.reject));

Finder get dialog => find.byType(AlertDialog);

Finder dialogButton(String label) =>
    find.descendant(of: dialog, matching: button(label));

Finder get reasonField =>
    find.descendant(of: dialog, matching: find.byType(TextField));

bool enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

/// The requests list's own Scrollable (the ListView under the
/// RefreshIndicator), named explicitly so a dialog's or a text field's
/// Scrollable is never dragged by mistake.
Finder get requestsList => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

/// Anything in the list may be below the built area (the list is lazy):
/// scroll to it before looking at it or tapping it.
Future<void> toRow(WidgetTester tester, Finder finder, {bool settle = true}) =>
    scrollTo(tester, finder, scrollable: requestsList, settle: settle);

Future<void> tapInList(WidgetTester tester, Finder finder) =>
    scrollToAndTap(tester, finder, scrollable: requestsList);

/// The list's current state, for facts about rows that may not be built.
RequestsLoaded loadedState() =>
    app.container.read(accountRequestsControllerProvider) as RequestsLoaded;

void main() {
  setUp(() => server = FakeAdminServer());

  group('opening', () {
    testWidgets('the admin tile opens /admin/requests', (tester) async {
      await openRequests(tester);

      expect(app.path, AppRoutes.adminRequests);
      expect(find.widgetWithText(AppBar, AppText.accountRequests), findsOne);
    });

    testWidgets('the back arrow returns to the admin home', (tester) async {
      await openRequests(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(app.path, AppRoutes.admin);
    });

    // Mobile (37), Q11: a task covers the whole screen, navigation bar
    // included; back on the home, the bar is there again.
    testWidgets('no navigation bar on this page; back on the home it shows', (
      tester,
    ) async {
      await openRequests(tester);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    // The bar's back-button rule (Account goes Home) must not reach a task
    // page on top: back closes the task, and the app stays open.
    testWidgets('Android back returns to the admin home, the app stays open', (
      tester,
    ) async {
      final exit = AppExitWatch(tester);
      await openRequests(tester);

      await pressAndroidBack(tester);

      expect(app.path, AppRoutes.admin);
      expect(exit.exits, 0);
    });

    testWidgets('another role cannot open it', (tester) async {
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.miner)),
        overrides: server.overrides(),
      );
      app.container.read(appRouterProvider).go(AppRoutes.adminRequests);
      await tester.pumpAndSettle();

      expect(app.path, AppRoutes.miner);
      expect(server.received, isEmpty);
    });
  });

  group('states', () {
    testWidgets('loading', (tester) async {
      server.hold = Completer<void>();
      await openRequests(tester, settle: false);
      await tester.pump();

      expect(find.text(AppText.loadingRequests), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text(AppText.loadingRequests), findsNothing);
    });

    testWidgets('the list: name, username, role, licence, date', (
      tester,
    ) async {
      server = FakeAdminServer([
        pendingUserJson(1),
        pendingUserJson(2, role: 'buyer', licenceNumber: null),
      ]);
      await openRequests(tester);

      expect(find.text(AppText.requestsCount(shown: 2, total: 2)), findsOne);
      expect(find.text('Demo Person 1'), findsOneWidget);
      expect(find.text('demo_user_1'), findsOneWidget);
      expect(
        find.descendant(
          of: card('Demo Person 1'),
          matching: find.text(AppText.minerTitle),
        ),
        findsOneWidget,
      );
      expect(find.text('ZM-ASM-0042'), findsOneWidget);
      // The second card may be below the built area at some sizes.
      await toRow(tester, find.text(AppText.noLicenceNumber));
      expect(
        find.descendant(
          of: card('Demo Person 2'),
          matching: find.text(AppText.noLicenceNumber),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card('Demo Person 2'),
          matching: find.text(AppText.buyerTitle),
        ),
        findsOneWidget,
      );
      // 09:00 UTC on 5 Nov is still 5 Nov in Zambia (UTC+2) and in the
      // test machine's zone unless it is far west of UTC.
      expect(find.textContaining('Requested 5 Nov 2026'), findsWidgets);
    });

    testWidgets('empty', (tester) async {
      server.pending.clear();
      await openRequests(tester);

      expect(find.text(AppText.noRequestsWaiting), findsOneWidget);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('no connection, then Try again', (tester) async {
      server.listAnswer = (_) => throw http.ClientException('offline');
      await openRequests(tester);

      expect(find.text(AppText.noConnection), findsOneWidget);

      server.listAnswer = null;
      await tapInList(
        tester,
        find.widgetWithText(FilledButton, AppText.tryAgain),
      );

      expect(find.text('Demo Person 1'), findsOneWidget);
    });

    testWidgets('a server error shows its sentence', (tester) async {
      server.listAnswer = (_) => http.Response('<html>', 502);
      await openRequests(tester);

      expect(find.text(AppText.badResponse), findsOneWidget);
    });

    testWidgets('an unsafe connection: no "Try again"', (tester) async {
      // What dart:io throws when the chain does not end at a pinned root.
      server.listAnswer = (_) => throw const HandshakeException('test');
      await openRequests(tester);

      expect(find.text(AppText.insecureConnection), findsOneWidget);
      expect(find.widgetWithText(FilledButton, AppText.tryAgain), findsNothing);
    });

    testWidgets('token expired: the password first, then the list', (
      tester,
    ) async {
      await openRequests(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.admin)),
      );

      expect(find.text(AppText.requestsNeedPassword), findsOneWidget);
      expect(server.received, isEmpty);

      await tapInList(
        tester,
        find.widgetWithText(FilledButton, AppText.enterYourPassword),
      );
      expect(find.byType(PasswordPromptDialog), findsOneWidget);
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

      expect(find.text('Demo Person 1'), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('pulling the list down fetches it again', (tester) async {
      await openRequests(tester);
      server.pending.add(pendingUserJson(3));

      await tester.fling(
        find.text('Demo Person 1'),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(server.lists, hasLength(2));
      expect(find.text(AppText.requestsCount(shown: 3, total: 3)), findsOne);
    });

    testWidgets('the refresh button does the same', (tester) async {
      await openRequests(tester);
      server.pending.add(pendingUserJson(3));

      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();

      expect(server.lists, hasLength(2));
      expect(find.text(AppText.requestsCount(shown: 3, total: 3)), findsOne);
      // The third card is below the built area at 360x640.
      await toRow(tester, find.text('Demo Person 3'));
      expect(find.text('Demo Person 3'), findsOneWidget);
    });

    testWidgets('a failed refresh keeps the list and says why', (tester) async {
      await openRequests(tester);
      server.listAnswer = (_) => throw http.ClientException('offline');

      await tester.tap(find.byTooltip(AppText.refreshList));
      await tester.pumpAndSettle();

      expect(find.text('Demo Person 1'), findsOneWidget);
      expect(find.text(AppText.noConnection), findsOneWidget); // snack bar
    });
  });

  group('Show more', () {
    testWidgets('loads the rest under the list', (tester) async {
      server = FakeAdminServer([
        for (var n = 1; n <= 23; n++) pendingUserJson(n),
      ]);
      await openRequests(tester);

      expect(find.text(AppText.requestsCount(shown: 20, total: 23)), findsOne);
      // The button is under the twentieth card, far below the built area.
      await tapInList(tester, button(AppText.showMore));

      // The new rows are reached by scrolling on; the count at the top has
      // been scrolled out of the built area, so it is read from the state.
      await toRow(tester, find.text('demo_user_23'));
      expect(loadedState().requests, hasLength(23));
      expect(loadedState().hasMore, isFalse);
      // At the very end of the list now, where the button would be.
      expect(button(AppText.showMore), findsNothing);
    });

    testWidgets('not shown when everything is loaded', (tester) async {
      await openRequests(tester);
      // Scrolled to the last card, so "not found" cannot just mean "not built
      // yet".
      await toRow(tester, find.text('demo_user_2'));
      expect(button(AppText.showMore), findsNothing);
    });
  });

  group('approve', () {
    testWidgets('asks first, naming the person and the role; Cancel sends '
        'nothing', (tester) async {
      await openRequests(tester);

      await tapInList(tester, approveIn('Demo Person 1'));
      expect(find.text(AppText.approveQuestion), findsOneWidget);
      expect(
        find.text(
          AppText.approveExplanation('Demo Person 1', AppText.minerTitle),
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, AppText.cancel));
      await tester.pumpAndSettle();

      expect(server.approves, isEmpty);
      expect(find.text('Demo Person 1'), findsOneWidget);
    });

    testWidgets('confirmed: the row leaves with a short message', (
      tester,
    ) async {
      await openRequests(tester);

      await tapInList(tester, approveIn('Demo Person 1'));
      await tapVisible(tester, dialogButton(AppText.approve));

      expect(server.approves, hasLength(1));
      expect(find.text(AppText.approved('Demo Person 1')), findsOneWidget);
      expect(card('Demo Person 1'), findsNothing);
      expect(find.text('Demo Person 2'), findsOneWidget);
      expect(find.text(AppText.requestsCount(shown: 1, total: 1)), findsOne);
    });

    testWidgets('while it runs, every button is disabled', (tester) async {
      await openRequests(tester);
      server.hold = Completer<void>();

      await tapInList(tester, approveIn('Demo Person 1'));
      await tester.tap(dialogButton(AppText.approve));
      // Frame by frame (the row's spinner never settles), long enough for
      // the dialog to finish closing: its barrier would catch the drags of
      // the scrolling below.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(enabled(tester, approveIn('Demo Person 1')), isFalse);
      expect(enabled(tester, rejectIn('Demo Person 1')), isFalse);
      // The second card may be below the built area: scroll, without
      // settling, while the request is still held.
      await toRow(tester, rejectIn('Demo Person 2'), settle: false);
      expect(enabled(tester, approveIn('Demo Person 2')), isFalse);
      expect(enabled(tester, rejectIn('Demo Person 2')), isFalse);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNull,
      );

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(enabled(tester, approveIn('Demo Person 2')), isTrue);
    });

    testWidgets('already handled by someone else: the list is updated', (
      tester,
    ) async {
      await openRequests(tester);
      // Another administrator approves Demo Person 1 first.
      server.pending.removeAt(0);

      await tapInList(tester, approveIn('Demo Person 1'));
      await tapVisible(tester, dialogButton(AppText.approve));

      expect(find.text(AppText.requestAlreadyHandled), findsOneWidget);
      expect(card('Demo Person 1'), findsNothing);
      expect(server.lists, hasLength(2));
    });

    testWidgets('refused for another reason: the row stays', (tester) async {
      await openRequests(tester);
      server.approveAnswer = (_) => refusal(
        409,
        ApiCodes.roleNotApprovable,
        'Officer and administrator accounts are created by an administrator, '
        'not approved or rejected.',
      );

      await tapInList(tester, approveIn('Demo Person 1'));
      await tapVisible(tester, dialogButton(AppText.approve));

      expect(
        find.textContaining('created by an administrator'),
        findsOneWidget,
      );
      expect(find.text('Demo Person 1'), findsOneWidget);
    });

    testWidgets('token expired: the password is asked for first', (
      tester,
    ) async {
      await openRequests(tester);
      app.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
      await tester.pump();

      await tapInList(tester, approveIn('Demo Person 1'));

      expect(find.byType(PasswordPromptDialog), findsOneWidget);
      expect(find.text(AppText.approveQuestion), findsNothing);
    });
  });

  group('reject', () {
    Future<void> openReject(WidgetTester tester) async {
      await tapInList(tester, rejectIn('Demo Person 1'));
      expect(find.text(AppText.rejectQuestion), findsOneWidget);
    }

    testWidgets('shows the permanent-reason warning and a counter', (
      tester,
    ) async {
      await openRequests(tester);
      await openReject(tester);

      expect(find.text(AppText.rejectReasonWarning), findsOneWidget);
      expect(find.text('0/$rejectReasonMax'), findsOneWidget);
      await tester.enterText(reasonField, 'Duplicate');
      await tester.pump();
      expect(find.text('9/$rejectReasonMax'), findsOneWidget);
    });

    testWidgets('fewer than 3 characters: refused on the phone', (
      tester,
    ) async {
      await openRequests(tester);
      await openReject(tester);

      // Spaces do not count: the server trims them.
      await tester.enterText(reasonField, '  no  ');
      await tester.tap(dialogButton(AppText.reject));
      await tester.pump();

      expect(find.text(AppText.rejectReasonTooShort), findsOneWidget);
      expect(server.rejects, isEmpty);

      // Typing again takes the sentence away.
      await tester.enterText(reasonField, 'no!');
      await tester.pump();
      expect(find.text(AppText.rejectReasonTooShort), findsNothing);
    });

    testWidgets('typing stops at 500 characters', (tester) async {
      await openRequests(tester);
      await openReject(tester);

      await tester.enterText(reasonField, 'a' * 600);
      await tester.pump();

      expect(
        tester.widget<TextField>(reasonField).controller!.text.length,
        rejectReasonMax,
      );
    });

    testWidgets('3 characters is enough: sent, the row leaves', (tester) async {
      await openRequests(tester);
      await openReject(tester);

      await tester.enterText(reasonField, 'Dup');
      await tapVisible(tester, dialogButton(AppText.reject));

      expect(server.rejects, hasLength(1));
      expect(dialog, findsNothing);
      expect(find.text(AppText.rejected('Demo Person 1')), findsOneWidget);
      expect(card('Demo Person 1'), findsNothing);
    });

    testWidgets("the server's field error shows under the field", (
      tester,
    ) async {
      await openRequests(tester);
      server.rejectAnswer = (_) => http.Response(
        errorAnswer(ApiCodes.validationFailed, 'Some fields are missing.', [
          {'field': 'reason', 'message': 'must be 500 characters or fewer'},
        ]),
        400,
      );
      await openReject(tester);

      await tester.enterText(
        reasonField,
        'Licence number could not be verified',
      );
      await tapVisible(tester, dialogButton(AppText.reject));

      expect(dialog, findsOneWidget); // stays open to fix it
      expect(
        tester.widget<TextField>(reasonField).decoration!.errorText,
        'must be 500 characters or fewer',
      );
      expect(find.text('Demo Person 1'), findsWidgets);
    });

    testWidgets('no connection: stays open with the sentence', (tester) async {
      await openRequests(tester);
      server.rejectAnswer = (_) => throw http.ClientException('offline');
      await openReject(tester);

      await tester.enterText(reasonField, 'Duplicate request');
      await tapVisible(tester, dialogButton(AppText.reject));

      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text(AppText.noConnection)),
        findsOneWidget,
      );
    });

    testWidgets('while sending: the dialog cannot be closed', (tester) async {
      await openRequests(tester);
      await openReject(tester);
      server.hold = Completer<void>();

      await tester.enterText(reasonField, 'Duplicate request');
      await tester.tap(dialogButton(AppText.reject));
      await tester.pump();

      expect(
        tester
            .widget<TextButton>(
              find.descendant(
                of: dialog,
                matching: find.widgetWithText(TextButton, AppText.cancel),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.text(AppText.sending), findsOneWidget);

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await openRequests(tester);
      await openReject(tester);
      await tester.enterText(reasonField, 'Duplicate request');

      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, AppText.cancel),
        ),
      );
      await tester.pumpAndSettle();

      expect(server.rejects, isEmpty);
      expect(find.text('Demo Person 1'), findsOneWidget);
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
        server = FakeAdminServer([
          pendingUserJson(1, fullName: 'Chilufya Mwansa-Kabwe Ngosa'),
          pendingUserJson(2, licenceNumber: null),
          pendingUserJson(3, role: 'transporter'),
        ]);
        await openRequests(tester, size: size, textScale: scale);

        expect(tester.takeException(), isNull);
        // Each card's last part, its buttons, so every row is seen whole.
        // The list is lazy, so scrollTo builds each one on the way down.
        for (final name in [
          'Chilufya Mwansa-Kabwe Ngosa',
          'Demo Person 2',
          'Demo Person 3',
        ]) {
          await toRow(tester, rejectIn(name));
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('the reject dialog with an error: $name', (tester) async {
        await openRequests(tester, size: size, textScale: scale);
        await tapInList(tester, rejectIn('Demo Person 1'));
        // tapVisible: at large text in landscape the button is below the
        // fold of the dialog's scrolling content.
        await tapVisible(tester, dialogButton(AppText.reject));

        expect(find.text(AppText.rejectReasonTooShort), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(dialogButton(AppText.reject));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('the empty state: $name', (tester) async {
        server.pending.clear();
        await openRequests(tester, size: size, textScale: scale);
        expect(find.text(AppText.noRequestsWaiting), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
