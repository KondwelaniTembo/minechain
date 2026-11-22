// "Reports" (reports plan, T3, §4.1): the transactions report for the
// officer, the buyer and the administrator, through the whole app (real
// router, real screens) with the fake server, store and share sheet.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';
import 'package:minechain/features/reports/data/report_sharer.dart';
import 'package:minechain/features/reports/presentation/report_widgets.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_report_files.dart';
import '../../../fakes/fake_reports_server.dart';

late FakeReportsServer server;
late FakeReportFileStore store;
late FakeReportSharer sharer;
late AppHarness app;

const sizes = [
  ('portrait 360x640', Size(360, 640), 1.0),
  ('landscape 640x360', Size(640, 360), 1.0),
  ('portrait, text 2.0', Size(360, 640), 2.0),
  ('landscape, text 2.0', Size(640, 360), 2.0),
];

/// 21 Nov 2026, 12:00 UTC: the default period is 23 Oct to 21 Nov.
final now = DateTime.utc(2026, 11, 21, 12);
const defaultQuery = {'from': '2026-10-23', 'to': '2026-11-21'};
const defaultName = 'minechain-transactions-2026-10-23-to-2026-11-21.csv';

/// Starts the app as [role] (or [auth]) and opens "Reports" from the home.
Future<void> openReports(
  WidgetTester tester, {
  Role role = Role.officer,
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  server.role = role.name;
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(role)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      ...reportFileOverrides(store, sharer),
      clockProvider.overrideWithValue(() => now),
    ],
  );
  await tapVisible(tester, find.text(AppText.reports));
}

Finder chip(String words) => find.widgetWithText(ChoiceChip, words);

/// The chip [words] inside the filter labelled [filter] ("Any" is in each).
Finder chipIn(String filter, String words) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is ReportFilterChips && widget.label == filter,
  ),
  matching: chip(words),
);

Future<void> download(WidgetTester tester) =>
    tapVisible(tester, find.text(AppText.downloadAndShare));

Map<String, String> lastQuery() => server.received.last.url.queryParameters;

/// Whether [finder] is wholly inside the page's visible part, with no
/// scrolling by the test (T5b).
bool inSight(WidgetTester tester, Finder finder) {
  final page = tester.getRect(find.byType(Scrollable).first);
  final target = tester.getRect(finder);
  return target.top >= page.top && target.bottom <= page.bottom;
}

/// Picks [from] to [to] in the date range picker, typed in its input mode
/// (US form, as the test's locale is en_US).
Future<void> pickPeriod(WidgetTester tester, String from, String to) async {
  await tapVisible(
    tester,
    find.text(AppText.reportFrom(DateTime(2026, 10, 23))),
  );
  await tester.tap(find.byIcon(Icons.edit_outlined));
  await tester.pumpAndSettle();
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), from);
  await tester.enterText(fields.at(1), to);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    server = FakeReportsServer();
    store = FakeReportFileStore();
    sharer = FakeReportSharer();
  });

  group('the way in', () {
    final paths = {
      Role.officer: AppRoutes.officerReports,
      Role.buyer: AppRoutes.buyerReports,
      Role.admin: AppRoutes.adminReports,
    };
    paths.forEach((role, path) {
      testWidgets('the ${role.name} home\'s "Reports" opens $path', (
        tester,
      ) async {
        await openReports(tester, role: role);
        expect(app.path, path);
        expect(find.text(AppText.downloadAndShare), findsOneWidget);
      });
    });

    testWidgets('a miner sent to /buyer/reports goes home', (tester) async {
      app = await AppHarness.pump(
        tester,
        FakeAuthController(signedInAs(Role.miner)),
        overrides: [
          ...server.overrides(),
          ...reportFileOverrides(store, sharer),
        ],
      );
      app.container.read(appRouterProvider).go(AppRoutes.buyerReports);
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.miner);
      expect(server.received, isEmpty);
    });
  });

  group('the form', () {
    testWidgets('the default period is the 30 days ending today', (
      tester,
    ) async {
      await openReports(tester);
      expect(
        find.text(AppText.reportFrom(DateTime(2026, 10, 23))),
        findsOneWidget,
      );
      expect(
        find.text(AppText.reportTo(DateTime(2026, 11, 21))),
        findsOneWidget,
      );
      expect(find.text(AppText.reportUtcNote), findsOneWidget);
    });

    testWidgets('"Any" everywhere sends the period only', (tester) async {
      await openReports(tester);
      await download(tester);
      expect(server.received.single.url.path, '/reports/transactions');
      expect(lastQuery(), defaultQuery);
    });

    testWidgets('each filter is sent as the API spells it', (tester) async {
      await openReports(tester);
      await tapVisible(tester, chip('Gold'));
      await tapVisible(tester, chip(AppText.stepHandoffs));
      await tapVisible(tester, chip(AppText.filterReviewFlagged));
      await tapVisible(tester, chip(AppText.chainConfirmed));
      await download(tester);
      expect(lastQuery(), {
        ...defaultQuery,
        'mineral': 'gold',
        'type': 'handoff',
        'reviewStatus': 'flagged',
        'anchorStatus': 'confirmed',
      });

      // Back to "Any" leaves the filter out again.
      await tapVisible(
        tester,
        chipIn(AppText.filterMineral, AppText.filterAny),
      );
      await download(tester);
      expect(lastQuery().containsKey('mineral'), isFalse);
      expect(lastQuery()['type'], 'handoff');
    });

    testWidgets('a picked period is sent', (tester) async {
      await openReports(tester);
      await pickPeriod(tester, '11/01/2026', '11/02/2026');
      expect(
        find.text(AppText.reportFrom(DateTime(2026, 11, 1))),
        findsOneWidget,
      );
      expect(
        find.text(AppText.reportTo(DateTime(2026, 11, 2))),
        findsOneWidget,
      );
      await download(tester);
      expect(lastQuery(), {'from': '2026-11-01', 'to': '2026-11-02'});
    });

    testWidgets('more than 366 days is refused here, and nothing is sent', (
      tester,
    ) async {
      await openReports(tester);
      await pickPeriod(tester, '01/01/2025', '11/21/2026');
      expect(find.text(AppText.periodTooLong), findsOneWidget);
      await download(tester);
      expect(server.received, isEmpty);
    });

    testWidgets('the buyer has no review filter, and is told the file is '
        'theirs only', (tester) async {
      await openReports(tester, role: Role.buyer);
      expect(find.text(AppText.reportsBuyerNote), findsOneWidget);
      expect(find.text(AppText.filterReview), findsNothing);
      expect(chip(AppText.filterReviewFlagged), findsNothing);
      await download(tester);
      expect(lastQuery(), defaultQuery);
    });

    testWidgets('the officer and the administrator have it', (tester) async {
      await openReports(tester, role: Role.admin);
      expect(find.text(AppText.reportsBuyerNote), findsNothing);
      expect(find.text(AppText.filterReview), findsOneWidget);
    });
  });

  group('the result', () {
    testWidgets('the card: the file, its rows, the time, and the share', (
      tester,
    ) async {
      await openReports(tester);
      await download(tester);
      expect(find.text(defaultName), findsOneWidget);
      expect(find.text(AppText.reportRows(3)), findsOneWidget);
      expect(
        find.text(AppText.reportDownloadedAt(now.toLocal())),
        findsOneWidget,
      );
      expect(find.text(AppText.reportShared), findsOneWidget);
      expect(sharer.shared.single.path, '/cache/reports/$defaultName');
    });

    testWidgets('no rows says so', (tester) async {
      server.rows = 0;
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.reportRows(0)), findsOneWidget);
    });

    testWidgets('closed without sharing: "Not shared yet", then "Share '
        'again" shares the same file', (tester) async {
      sharer.outcome = ShareOutcome.dismissed;
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.reportNotShared), findsOneWidget);

      sharer.outcome = ShareOutcome.shared;
      await tapVisible(tester, find.text(AppText.shareAgain));
      expect(find.text(AppText.reportShared), findsOneWidget);
      expect(sharer.shared, hasLength(2));
      expect(server.received, hasLength(1));
    });

    testWidgets('a share menu that fails says so, and keeps the file', (
      tester,
    ) async {
      sharer.error = Exception('no activity');
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.reportShareFailed), findsOneWidget);
      expect(find.text(defaultName), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a double tap downloads once', (tester) async {
      server.hold = Completer<void>();
      await openReports(tester);
      await tester.ensureVisible(find.text(AppText.downloadAndShare));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppText.downloadAndShare));
      await tester.pump();
      expect(find.text(AppText.downloading), findsOneWidget);
      // Changed by T5b: the card now scrolls into view, and a page ignores
      // taps while it scrolls, so the second tap comes after the 300 ms
      // (the scroll starts one frame later, after the card is laid out, and
      // the page takes taps again a frame after it ends). No pumpAndSettle:
      // the bar keeps moving until the download ends.
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // The button is disabled now; the controller ignores a tap anyway.
      await tester.tap(find.text(AppText.downloading));
      await tester.pump();
      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(server.received, hasLength(1));
      expect(sharer.shared, hasLength(1));
    });
  });

  group('failures', () {
    testWidgets('too large: the sentence, no "Try again", the form kept', (
      tester,
    ) async {
      server.answers['transactions'] = tooLarge;
      await openReports(tester);
      await tapVisible(tester, chip('Gold'));
      await download(tester);
      expect(find.text(AppText.reportTooLarge), findsOneWidget);
      expect(find.text(AppText.tryAgain), findsNothing);
      final gold = tester.widget<ChoiceChip>(chip('Gold'));
      expect(gold.selected, isTrue);
      expect(sharer.shared, isEmpty);
    });

    testWidgets('too many downloads: the server\'s sentence and the wait', (
      tester,
    ) async {
      server.counted = 20;
      await openReports(tester);
      await download(tester);
      expect(
        find.text(
          'Too many report downloads. Please wait a few minutes and try again.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppText.reportTryAgainIn(const Duration(minutes: 10))),
        findsOneWidget,
      );
      expect(find.text(AppText.tryAgain), findsNothing);
    });

    testWidgets('offline: "No internet connection", then "Try again" works', (
      tester,
    ) async {
      server.answers['transactions'] = (request) =>
          throw http.ClientException('no network', request.url);
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      server.answers.clear();
      await tapVisible(tester, find.text(AppText.tryAgain));
      expect(find.text(defaultName), findsOneWidget);
      expect(server.received, hasLength(2));
      expect(lastQuery(), defaultQuery);
    });

    testWidgets('an answer that is not a CSV file is not saved', (
      tester,
    ) async {
      server.answers['transactions'] = (_) => http.Response(
        '{"ok":true}',
        200,
        headers: {'content-type': 'application/json'},
      );
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.badResponse), findsOneWidget);
      expect(store.saved, isEmpty);
    });

    testWidgets('a full phone: the sentence and "Try again"', (tester) async {
      store.full = true;
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.reportNotSaved), findsOneWidget);
      expect(find.text(AppText.tryAgain), findsOneWidget);
    });

    testWidgets('an ended session: the password, then the same query again', (
      tester,
    ) async {
      late FakeAuthController auth;
      server.answers['transactions'] = (_) {
        server.answers.clear();
        auth.setState(SignedInNeedsPassword(userOf(Role.officer)));
        return refusal(401, 'TOKEN_EXPIRED', 'Your session has expired.');
      };
      await openReports(tester);
      auth = app.auth;
      await tapVisible(tester, chip('Cobalt'));
      await download(tester);
      expect(find.text(AppText.reportNeedsPassword), findsOneWidget);

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, AppText.enterPasswordButton),
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
      expect(server.received, hasLength(2));
      expect(lastQuery(), {...defaultQuery, 'mineral': 'cobalt'});
      expect(find.text(defaultName), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in sizes) {
      testWidgets('the form and a result: $name', (tester) async {
        await openReports(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await download(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.shareAgain));
        await tester.pumpAndSettle();
        expect(find.text(AppText.shareAgain), findsOneWidget);
      });

      testWidgets('a failure: $name', (tester) async {
        server.answers['transactions'] = tooLarge;
        await openReports(tester, size: size, textScale: scale);
        await download(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.reportTooLarge));
      });
    }
  });

  group('the card comes into sight (T5b)', () {
    testWidgets('offline: the sentence and "Try again", with no scrolling', (
      tester,
    ) async {
      server.answers['transactions'] = (request) =>
          throw http.ClientException('no network', request.url);
      await openReports(tester);
      await download(tester);
      expect(inSight(tester, find.text(AppText.noConnection)), isTrue);
      expect(inSight(tester, find.text(AppText.tryAgain)), isTrue);
    });

    testWidgets('a saved file: its name and "Share again"', (tester) async {
      await openReports(tester);
      await download(tester);
      expect(inSight(tester, find.text(defaultName)), isTrue);
      expect(inSight(tester, find.text(AppText.shareAgain)), isTrue);
    });

    testWidgets('an ended session: the password button', (tester) async {
      await openReports(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.officer)),
      );
      await download(tester);
      expect(
        inSight(
          tester,
          find.widgetWithText(FilledButton, AppText.enterPasswordButton),
        ),
        isTrue,
      );
    });

    for (final (name, size, scale) in sizes) {
      testWidgets('"Share again" in sight: $name', (tester) async {
        await openReports(tester, size: size, textScale: scale);
        await download(tester);
        expect(inSight(tester, find.text(AppText.shareAgain)), isTrue);
      });
    }
  });

  group('a new choice after a failure (T5b)', () {
    testWidgets('a filter clears the failure; the next download sends it', (
      tester,
    ) async {
      server.answers['transactions'] = (request) =>
          throw http.ClientException('no network', request.url);
      await openReports(tester);
      await tapVisible(
        tester,
        chipIn(AppText.filterStep, AppText.stepHandoffs),
      );
      await download(tester);
      expect(find.text(AppText.noConnection), findsOneWidget);

      await tapVisible(tester, chipIn(AppText.filterStep, AppText.filterAny));
      expect(find.text(AppText.noConnection), findsNothing);
      expect(find.text(AppText.tryAgain), findsNothing);
      expect(server.received, hasLength(1));

      server.answers.clear();
      await download(tester);
      expect(lastQuery(), defaultQuery);
      expect(find.text(defaultName), findsOneWidget);
    });

    testWidgets('a new period clears it too', (tester) async {
      server.answers['transactions'] = tooLarge;
      await openReports(tester);
      await download(tester);
      expect(find.text(AppText.reportTooLarge), findsOneWidget);
      await pickPeriod(tester, '11/01/2026', '11/21/2026');
      expect(find.text(AppText.reportTooLarge), findsNothing);
    });

    testWidgets("an ended session's card goes too", (tester) async {
      await openReports(
        tester,
        auth: SignedInNeedsPassword(userOf(Role.officer)),
      );
      await download(tester);
      expect(find.text(AppText.reportNeedsPassword), findsOneWidget);
      await tapVisible(tester, chip('Gold'));
      expect(find.text(AppText.reportNeedsPassword), findsNothing);
      expect(server.received, isEmpty);
    });

    testWidgets("a saved file's card stays: it names its own file", (
      tester,
    ) async {
      await openReports(tester);
      await download(tester);
      await tapVisible(tester, chip('Gold'));
      expect(find.text(defaultName), findsOneWidget);
      expect(find.text(AppText.shareAgain), findsOneWidget);
    });
  });
}
