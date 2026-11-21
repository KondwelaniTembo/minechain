// The three actions on a zone's page (GPS zones plan §4.4, T4): rename,
// deactivate (with the last-zone pre-warning and the server's warning, Q4)
// and reactivate. Each through the real dialog, repository and ApiClient
// against the fake zones server: the exact body sent, the message, the page
// after the answer, and every refusal keeping the dialog and what was typed.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/errors/api_codes.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/admin/presentation/zones_screen.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';

import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_zones_server.dart';
import 'zone_page_helpers.dart';

Map<String, Object?> bodyOf(http.Request request) => request.body.isEmpty
    ? {}
    : jsonDecode(request.body) as Map<String, Object?>;

/// Taps [label] on the page, then waits for its dialog. The last action's
/// message is cleared first: a snack bar can cover a button near the bottom.
Future<void> startAction(WidgetTester tester, String label) async {
  ScaffoldMessenger.of(tester.element(find.byType(Scaffold).last))
      .removeCurrentSnackBar();
  await tester.pumpAndSettle();
  await tapOnZonePage(tester, pageButton(label));
}

/// Types [text] into the dialog's field and taps its [button].
Future<void> sendDialog(WidgetTester tester, String text, String button) async {
  await tester.enterText(dialogField, text);
  await tester.pumpAndSettle();
  await tester.tap(dialogButton(button));
  await tester.pumpAndSettle();
}

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(dialogField).controller!.text;

String? fieldErrorText(WidgetTester tester) =>
    tester.widget<TextField>(dialogField).decoration!.errorText;

/// The warning dialog after the last active zone goes.
Finder get warningDialog => find.ancestor(
  of: find.text(AppText.noActiveZoneTitle),
  matching: find.byType(AlertDialog),
);

void main() {
  setUp(() => zones = FakeZonesServer());

  group('rename', () {
    testWidgets('the name filled in; the new one sent trimmed and shown', (
      tester,
    ) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      expect(inDialog(find.text(AppText.renameZoneTitle)), findsOneWidget);
      expect(fieldText(tester), 'Kasempa North');

      await sendDialog(
        tester,
        '  Kasempa North (until Nov 2026) ',
        AppText.save,
      );

      expect(bodyOf(zones.actions('rename').single), {
        'name': 'Kasempa North (until Nov 2026)',
      });
      expect(dialog, findsNothing);
      expect(
        snack(AppText.zoneRenamedDone('Kasempa North (until Nov 2026)')),
        findsOneWidget,
      );
      expect(find.text('Kasempa North (until Nov 2026)'), findsWidgets);
    });

    testWidgets('the same name is not sent and says nothing', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      await sendDialog(tester, ' Kasempa North ', AppText.save);
      expect(zones.actions('rename'), isEmpty);
      expect(dialog, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a change of letter case only is sent', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      await sendDialog(tester, 'KASEMPA NORTH', AppText.save);
      expect(bodyOf(zones.actions('rename').single), {'name': 'KASEMPA NORTH'});
    });

    testWidgets('under 3 characters is not sent', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      await sendDialog(tester, ' K2 ', AppText.save);
      expect(zones.actions('rename'), isEmpty);
      expect(fieldErrorText(tester), AppText.zoneNameTooShort);
    });

    testWidgets("ZONE_NAME_TAKEN: the server's sentence under the field, the "
        'name kept', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      // Mumbwa East is inactive, and still holds its name.
      await sendDialog(tester, 'mumbwa east', AppText.save);
      expect(dialog, findsOneWidget);
      expect(fieldErrorText(tester), zoneNameTakenMessage);
      expect(fieldText(tester), 'mumbwa east');
    });

    testWidgets('offline: the dialog stays and says so', (tester) async {
      zones.answers['rename'] = (_) => throw const SocketException('test');
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.renameZone);
      await sendDialog(tester, 'Kasempa North Two', AppText.save);
      expect(inDialog(find.text(AppText.noConnection)), findsOneWidget);
      expect(fieldText(tester), 'Kasempa North Two');
    });
  });

  group('deactivate', () {
    testWidgets('a reason, sent trimmed; the zone inactive; no warning while '
        'another is active', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      expect(
        inDialog(find.text(AppText.deactivateZoneQuestion)),
        findsOneWidget,
      );
      // Two zones are active: no pre-warning.
      expect(
        inDialog(find.text(AppText.deactivateZoneExplanation('Kasempa North'))),
        findsOneWidget,
      );
      expect(inDialog(find.text(AppText.rejectReasonWarning)), findsOneWidget);

      await sendDialog(tester, '  Licence revoked ', AppText.deactivateZone);

      expect(bodyOf(zones.actions('deactivate').single), {
        'reason': 'Licence revoked',
      });
      expect(dialog, findsNothing);
      expect(warningDialog, findsNothing);
      expect(
        snack(AppText.zoneDeactivatedDone('Kasempa North')),
        findsOneWidget,
      );
      expect(find.text(AppText.zoneIsInactive), findsOneWidget);
      expect(pageButton(AppText.deactivateZone), findsNothing);
      expect(pageButton(AppText.reactivateZone), findsOneWidget);
    });

    testWidgets('the only active zone: warned before, and the server\'s '
        'warning after, which must be closed (Q4)', (tester) async {
      zones = FakeZonesServer([
        zoneJson(1, name: 'Kasempa North'),
        zoneJson(3, name: 'Mumbwa East', status: 'inactive'),
      ]);
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      expect(
        inDialog(
          find.text(
            '${AppText.deactivateZoneExplanation('Kasempa North')} '
            '${AppText.onlyActiveZone}',
          ),
        ),
        findsOneWidget,
      );

      await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);

      expect(warningDialog, findsOneWidget);
      expect(
        find.descendant(
          of: warningDialog,
          matching: find.text(noActiveZonesMessage),
        ),
        findsOneWidget,
      );
      // Not closed by a tap outside it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(warningDialog, findsOneWidget);

      await tester.tap(find.text(AppText.iUnderstand));
      await tester.pumpAndSettle();
      expect(warningDialog, findsNothing);

      // Back on the list: the warning card.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(NoActiveZoneCard), findsOneWidget);
    });

    testWidgets('a warning without a readable message: our sentence', (
      tester,
    ) async {
      zones.answers['deactivate'] = (request) {
        final zone = zones.byId(zoneId(1))!..['status'] = 'inactive';
        return json200({'zone': zone, 'warning': 'none left'});
      };
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);
      expect(
        find.descendant(
          of: warningDialog,
          matching: find.text(AppText.noActiveZone),
        ),
        findsOneWidget,
      );
    });

    testWidgets("another administrator acted first: the server's sentence, "
        'and back to the list, read again', (tester) async {
      const message =
          'Only an active zone can be deactivated. This zone is inactive.';
      zones.answers['deactivate'] = (_) =>
          refusal(409, ApiCodes.invalidStatusTransition, message);
      await openZone(tester, zoneId(1));
      final listsBefore = zones.lists.length;
      await startAction(tester, AppText.deactivateZone);
      await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);

      expect(dialog, findsNothing);
      expect(snack(message), findsOneWidget);
      expect(zonesApp.path, AppRoutes.adminZones);
      expect(zones.lists.length, listsBefore + 1);
    });

    testWidgets('ZONE_NOT_FOUND: our sentence, the reason kept', (
      tester,
    ) async {
      zones.answers['deactivate'] = (_) =>
          refusal(404, ApiCodes.zoneNotFound, 'No GPS zone has this id.');
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);
      expect(inDialog(find.text(AppText.zoneNotFound)), findsOneWidget);
      expect(fieldText(tester), 'Licence revoked');
    });

    testWidgets('a reason under 3 characters is not sent', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      await sendDialog(tester, ' no ', AppText.deactivateZone);
      expect(zones.actions('deactivate'), isEmpty);
      expect(fieldErrorText(tester), AppText.rejectReasonTooShort);
    });

    testWidgets('offline: the dialog stays and says so', (tester) async {
      zones.answers['deactivate'] = (_) => throw const SocketException('test');
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);
      expect(inDialog(find.text(AppText.noConnection)), findsOneWidget);
      expect(fieldText(tester), 'Licence revoked');
    });

    testWidgets('a double tap sends once', (tester) async {
      await openZone(tester, zoneId(1));
      zones.hold = Completer<void>();
      await startAction(tester, AppText.deactivateZone);
      await tester.enterText(dialogField, 'Licence revoked');
      await tester.pump();
      await tester.tap(dialogButton(AppText.deactivateZone));
      await tester.pump();
      expect(inDialog(find.text(AppText.sending)), findsOneWidget);
      await tester.tap(inDialog(find.text(AppText.sending)));
      await tester.pump();

      zones.hold!.complete();
      await tester.pumpAndSettle();
      expect(zones.actions('deactivate'), hasLength(1));
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await openZone(tester, zoneId(1));
      await startAction(tester, AppText.deactivateZone);
      await tester.enterText(dialogField, 'Licence revoked');
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(zones.actions('deactivate'), isEmpty);
      expect(find.text(AppText.zoneIsActive), findsOneWidget);
    });
  });

  group('reactivate', () {
    testWidgets('asks, sends no body, then the zone is active', (tester) async {
      await openZone(tester, zoneId(3), list: AppText.zonesInactive);
      await startAction(tester, AppText.reactivateZone);
      expect(
        inDialog(find.text(AppText.reactivateZoneExplanation('Mumbwa East'))),
        findsOneWidget,
      );
      await tester.tap(dialogButton(AppText.reactivateZone));
      await tester.pumpAndSettle();

      expect(zones.actions('reactivate').single.body, isEmpty);
      expect(snack(AppText.zoneReactivatedDone('Mumbwa East')), findsOneWidget);
      expect(find.text(AppText.zoneIsActive), findsOneWidget);
      expect(pageButton(AppText.deactivateZone), findsOneWidget);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await openZone(tester, zoneId(3), list: AppText.zonesInactive);
      await startAction(tester, AppText.reactivateZone);
      await tester.tap(dialogButton(AppText.cancel));
      await tester.pumpAndSettle();
      expect(zones.actions('reactivate'), isEmpty);
      expect(find.text(AppText.zoneIsInactive), findsOneWidget);
    });

    testWidgets('offline: the zone stays inactive and says so', (tester) async {
      zones.answers['reactivate'] = (_) => throw const SocketException('test');
      await openZone(tester, zoneId(3), list: AppText.zonesInactive);
      await startAction(tester, AppText.reactivateZone);
      await tester.tap(dialogButton(AppText.reactivateZone));
      await tester.pumpAndSettle();
      expect(snack(AppText.noConnection), findsOneWidget);
      expect(find.text(AppText.zoneIsInactive), findsOneWidget);
    });
  });

  // As for accounts (Admin accounts T6b): the session ran out while a dialog
  // was open. The password is asked for on top of it, and the same text is
  // sent again; nothing is typed twice.
  group('the session runs out while a dialog is open', () {
    void expireOnce(String action) {
      zones.answers[action] = (request) {
        zones.answers.remove(action);
        zonesApp.auth.setState(SignedInNeedsPassword(userOf(Role.admin)));
        return refusal(401, ApiCodes.tokenExpired, 'Token expired.');
      };
    }

    final prompt = find.byType(PasswordPromptDialog);

    // Not pumpAndSettle: the dialog's "Sending…" spinner keeps turning under
    // the prompt.
    Future<void> tapToPrompt(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> enterPassword(WidgetTester tester) async {
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
    }

    testWidgets('rename: the password, then the same name is sent', (
      tester,
    ) async {
      await openZone(tester, zoneId(1));
      expireOnce('rename');
      await startAction(tester, AppText.renameZone);
      await tester.enterText(dialogField, 'Kasempa North Two');
      await tester.pumpAndSettle();
      await tapToPrompt(tester, dialogButton(AppText.save));

      expect(prompt, findsOneWidget);
      await enterPassword(tester);

      final sent = zones.actions('rename');
      expect(sent, hasLength(2));
      expect(bodyOf(sent.last), {'name': 'Kasempa North Two'});
      expect(
        snack(AppText.zoneRenamedDone('Kasempa North Two')),
        findsOneWidget,
      );
    });

    testWidgets('deactivate: Cancel on the password keeps the dialog and the '
        'reason', (tester) async {
      await openZone(tester, zoneId(1));
      expireOnce('deactivate');
      await startAction(tester, AppText.deactivateZone);
      await tester.enterText(dialogField, 'Licence revoked');
      await tester.pumpAndSettle();
      await tapToPrompt(tester, dialogButton(AppText.deactivateZone));

      await tester.tap(
        find.descendant(of: prompt, matching: find.text(AppText.cancel)),
      );
      await tester.pumpAndSettle();
      expect(inDialog(find.text(AppText.sessionExpired)), findsOneWidget);
      expect(fieldText(tester), 'Licence revoked');

      await tapToPrompt(tester, dialogButton(AppText.deactivateZone));
      await enterPassword(tester);
      expect(zones.actions('deactivate'), hasLength(2));
      expect(
        snack(AppText.zoneDeactivatedDone('Kasempa North')),
        findsOneWidget,
      );
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the deactivate dialog with an error: $name', (tester) async {
        zones.answers['deactivate'] = (_) =>
            throw const SocketException('test');
        await openZone(tester, zoneId(1), size: size, textScale: scale);
        await startAction(tester, AppText.deactivateZone);
        await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);
        expect(tester.takeException(), isNull);
        expect(inDialog(find.text(AppText.noConnection)), findsOneWidget);
      });

      testWidgets('the warning dialog: $name', (tester) async {
        zones = FakeZonesServer([zoneJson(1, name: 'Kasempa North')]);
        await openZone(tester, zoneId(1), size: size, textScale: scale);
        await startAction(tester, AppText.deactivateZone);
        await sendDialog(tester, 'Licence revoked', AppText.deactivateZone);
        expect(tester.takeException(), isNull);
        expect(warningDialog, findsOneWidget);
        await tester.ensureVisible(find.text(AppText.iUnderstand));
        await tester.tap(find.text(AppText.iUnderstand));
        await tester.pumpAndSettle();
        expect(warningDialog, findsNothing);
      });
    }
  });
}
