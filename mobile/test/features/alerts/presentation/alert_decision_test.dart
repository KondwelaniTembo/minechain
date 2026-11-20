// "Confirm problem" and "Clear, no problem" inside the real app and router,
// with the fake server behind the real repository and ApiClient (officer
// alerts plan §4.3, T4): the notes rules, exactly what is sent, each answer's
// message back on the list, and every refusal, with the notes kept.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/app_harness.dart' show tapVisible;
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_alerts_server.dart';
import '../../../fakes/fake_controllers.dart' show userOf;
import 'alert_page_helpers.dart';

const notes = 'Weighed again at the depot, 1.6 kg confirmed';

/// Types [text] into the notes and settles.
Future<void> typeNotes(WidgetTester tester, String text) async {
  await tester.enterText(notesField, text);
  await tester.pumpAndSettle();
}

/// The dialog's decision button, scrolled into view and tapped.
Future<void> send(WidgetTester tester, String label) =>
    tapVisible(tester, dialogButton(label));

void main() {
  setUp(() => server = FakeAlertsServer());

  group('the dialog', () {
    testWidgets('"Confirm problem": what it does, the warning, a counter', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);

      expect(find.text(AppText.confirmQuestion), findsOneWidget);
      expect(find.text(AppText.confirmExplains), findsOneWidget);
      expect(find.text(AppText.decisionNotesWarning), findsOneWidget);
      expect(find.text(AppText.decisionNotesHint), findsOneWidget);
      expect(find.text('0/500'), findsOneWidget);
    });

    testWidgets('"Clear, no problem" says what it does', (tester) async {
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);

      expect(find.text(AppText.clearQuestion), findsOneWidget);
      expect(find.text(AppText.clearExplains), findsOneWidget);
    });

    testWidgets('under 3 characters after trimming, the button stays off', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      final confirm = dialogButton(AppText.confirmProblem);

      expect(enabled(tester, confirm), isFalse);
      expect(find.text(AppText.decisionNotesTooShort), findsOneWidget);
      await typeNotes(tester, 'ab');
      expect(enabled(tester, confirm), isFalse);
      await typeNotes(tester, '   ab   ');
      expect(enabled(tester, confirm), isFalse);

      await typeNotes(tester, 'abc');
      expect(enabled(tester, confirm), isTrue);
      expect(find.text(AppText.decisionNotesTooShort), findsNothing);
      expect(server.reviews, isEmpty);
    });

    testWidgets('typing stops at 500 characters', (tester) async {
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);

      await typeNotes(tester, 'x' * 600);

      expect(
        tester.widget<TextField>(notesField).controller!.text,
        hasLength(500),
      );
      expect(find.text('500/500'), findsOneWidget);
    });

    testWidgets('Cancel sends nothing, and the alert stays open', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);

      await tapVisible(tester, dialogButton(AppText.cancel));

      expect(dialog, findsNothing);
      expect(server.dismissals, isEmpty);
      expect(app.path, AppRoutes.officerAlert(alertId(1)));
    });
  });

  group('what is sent', () {
    testWidgets('confirm: POST .../review with exactly the trimmed notes', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, '  $notes\n');
      await send(tester, AppText.confirmProblem);

      final sent = server.reviews.single;
      expect(sent.url.path, '/alerts/${alertId(1)}/review');
      expect(sent.headers['authorization'], 'Bearer $fakeToken');
      expect(jsonDecode(sent.body), {'notes': notes});
      expect(server.dismissals, isEmpty);
    });

    testWidgets('clear: POST .../dismiss with the notes', (tester) async {
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.clearNoProblem);

      final sent = server.dismissals.single;
      expect(sent.url.path, '/alerts/${alertId(1)}/dismiss');
      expect(jsonDecode(sent.body), {'notes': notes});
      expect(server.reviews, isEmpty);
    });

    testWidgets('a double tap sends once', (tester) async {
      server.hold = Completer<void>();
      await openAlertHeld(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);

      await tester.ensureVisible(dialogButton(AppText.confirmProblem));
      await tester.pump();
      await tester.tap(dialogButton(AppText.confirmProblem));
      await tester.pump();
      // The button now shows "Sending…" and is off; a second tap on where
      // it was does nothing.
      expect(find.text(AppText.sending), findsOneWidget);
      await tester.tap(find.text(AppText.sending));
      await tester.pump();

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(server.reviews, hasLength(1));
    });

    testWidgets('while sending, neither the dialog nor the page can close', (
      tester,
    ) async {
      server.hold = Completer<void>();
      await openAlertHeld(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await tester.ensureVisible(dialogButton(AppText.clearNoProblem));
      await tester.pump();
      await tester.tap(dialogButton(AppText.clearNoProblem));
      await tester.pump();

      expect(enabled(tester, dialogButton(AppText.cancel)), isFalse);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(dialog, findsOneWidget);

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  });

  group("each answer's message, back on the list", () {
    testWidgets('cleared and moved on: no longer held, on its way', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.clearNoProblem);

      expect(app.path, AppRoutes.officerAlerts);
      expect(
        find.text(
          'Cleared. MC-2026-LSK-0008 is no longer held. Stage: On its way.',
        ),
        findsOneWidget,
      );
      // The list was read again, and the alert has left it.
      expect(server.lists, hasLength(2));
      expect(find.text(AppText.noOpenAlerts), findsOneWidget);
    });

    testWidgets('cleared, still held by another open alert', (tester) async {
      server = FakeAlertsServer([
        alertJson(1),
        alertJson(
          2,
          type: 'gps_zone',
          stepType: 'registration',
          details: {'noActiveZones': true, 'toleranceMetres': 25},
        ),
      ]);
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.clearNoProblem);

      expect(
        find.text(
          'Cleared. MC-2026-LSK-0008 is still held: another alert on it is '
          'open. Stage: On its way.',
        ),
        findsOneWidget,
      );
      expect(find.text(AppText.alertGpsZone), findsOneWidget);
      expect(find.text(AppText.alertQuantity), findsNothing);
    });

    testWidgets('confirmed: never on the blockchain, no longer held', (
      tester,
    ) async {
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(
        find.text(
          'Confirmed. The step will never go on the blockchain. '
          'MC-2026-LSK-0008 is no longer held. Stage: Registered.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an answer with nothing readable still says it is done', (
      tester,
    ) async {
      server.reviewAnswer = (_) => http.Response(
        jsonEncode({'ok': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(app.path, AppRoutes.officerAlerts);
      expect(find.text(AppText.confirmedDone), findsOneWidget);
    });

    testWidgets('the decision is then in the "Cleared" list', (tester) async {
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.clearNoProblem);

      await tester.tap(find.widgetWithText(ChoiceChip, AppText.alertsCleared));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cleared by officer_chanda'), findsOneWidget);
    });
  });

  group('refusals', () {
    testWidgets('409: another officer decided first; the page shows it', (
      tester,
    ) async {
      await openAlert(tester);
      // Another officer clears it while this one is typing.
      server.alerts[0] = alertJson(1, status: 'dismissed');
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(dialog, findsNothing);
      expect(find.text(AppText.alertAlreadyDecided), findsOneWidget);
      expect(server.details, hasLength(2)); // read again
      // The other officer's decision, further down the page.
      await toPart(tester, find.textContaining('Cleared by officer_chanda'));
      expect(button(AppText.confirmProblem), findsNothing);

      // Back on the list, which is read again: the alert is no longer open.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(server.lists, hasLength(2));
      expect(find.text(AppText.noOpenAlerts), findsOneWidget);
    });

    testWidgets("409 cannot be cleared: the server's sentence, notes kept, "
        '"Confirm problem" still there', (tester) async {
      const message =
          'This step cannot be cleared: the consignment already has an '
          'accepted purchase. Confirm the problem instead.';
      server.dismissAnswer = (_) =>
          http.Response(errorAnswer('STEP_CANNOT_BE_CLEARED', message), 409);
      await openAlert(tester);
      await startDecision(tester, AppText.clearNoProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.clearNoProblem);

      expect(dialog, findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(tester.widget<TextField>(notesField).controller!.text, notes);

      await tapVisible(tester, dialogButton(AppText.cancel));
      expect(app.path, AppRoutes.officerAlert(alertId(1)));
      await toPart(tester, button(AppText.confirmProblem));
      expect(enabled(tester, button(AppText.confirmProblem)), isTrue);
    });

    testWidgets('429: too many decisions, notes kept', (tester) async {
      server.reviewAnswer = (_) => http.Response(
        errorAnswer('TOO_MANY_REQUESTS', 'Too many alert decisions.'),
        429,
        headers: {'retry-after': '120'},
      );
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(find.text(AppText.tooManyTries), findsOneWidget);
      expect(tester.widget<TextField>(notesField).controller!.text, notes);
    });

    testWidgets('Q3 offline: "not sent", notes kept, nothing queued', (
      tester,
    ) async {
      server.reviewAnswer = (_) => throw http.ClientException('offline');
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(find.text(AppText.decisionNotSent), findsOneWidget);
      expect(tester.widget<TextField>(notesField).controller!.text, notes);
      expect(server.reviews, hasLength(1));

      // Sending again once the network is back works as normal.
      server.reviewAnswer = null;
      await send(tester, AppText.confirmProblem);
      expect(server.reviews, hasLength(2));
      expect(app.path, AppRoutes.officerAlerts);
    });

    testWidgets("the server's field error shows under the notes", (
      tester,
    ) async {
      server.reviewAnswer = (_) => http.Response(
        errorAnswer('VALIDATION_FAILED', 'Some fields are missing.', [
          {'field': 'notes', 'message': 'must be 3-500 characters'},
        ]),
        400,
      );
      await openAlert(tester);
      await startDecision(tester, AppText.confirmProblem);
      await typeNotes(tester, notes);
      await send(tester, AppText.confirmProblem);

      expect(find.text('must be 3-500 characters'), findsOneWidget);
      await typeNotes(tester, '$notes.');
      expect(find.text('must be 3-500 characters'), findsNothing);
    });

    testWidgets('an ended session: the password before the notes', (
      tester,
    ) async {
      await openAlert(tester);
      app.auth.setState(SignedInNeedsPassword(userOf(Role.officer)));
      await tester.pump();

      await startDecision(tester, AppText.confirmProblem);
      expect(find.byType(PasswordPromptDialog), findsOneWidget);
      expect(find.text(AppText.confirmQuestion), findsNothing);

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
      expect(find.text(AppText.confirmQuestion), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the dialog with a refusal: $name', (tester) async {
        server.dismissAnswer = (_) => http.Response(
          errorAnswer(
            'STEP_CANNOT_BE_CLEARED',
            'This step cannot be cleared: the consignment already has an '
                'accepted registration. Confirm the problem instead.',
          ),
          409,
        );
        await openAlert(tester, size: size, textScale: scale);
        await startDecision(tester, AppText.clearNoProblem);
        expect(tester.takeException(), isNull);
        await typeNotes(tester, notes);
        await send(tester, AppText.clearNoProblem);

        expect(tester.takeException(), isNull);
        await tester.ensureVisible(dialogButton(AppText.clearNoProblem));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// [openAlert] while the server holds its answers: the list and the detail
/// are let through one at a time, then the hold is put back for the
/// decision.
Future<void> openAlertHeld(WidgetTester tester) async {
  final held = server.hold!;
  server.hold = null;
  await openAlert(tester);
  server.hold = held;
}
