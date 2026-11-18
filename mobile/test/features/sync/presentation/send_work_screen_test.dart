// "Send my work" inside the real app and router, with the real sync service
// and repository on an in-memory database, and a fake server behind
// MockClient.
//
// pumpAndSettle is avoided after the screen opens: while a send runs, the
// progress bar may move without end. [frames] draws a few frames instead.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/auth/presentation/auth_controller.dart';
import 'package:minechain/features/auth/presentation/password_prompt.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/sync/data/sync_service.dart';
import 'package:minechain/features/sync/domain/sync_report.dart';
import 'package:minechain/features/sync/presentation/send_work_screen.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/auth_fixtures.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart';
import '../../../fakes/fake_sync_server.dart';
import '../../../fakes/flaky_database.dart';

const fingerprint =
    '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53';

late InMemoryLocalDatabase database;
late LocalStepsRepository steps;
late FakeSyncServer server;
late AppHarness app;
late DateTime now;

Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Starts the app as a miner and opens the screen from the home tile.
Future<void> open(
  WidgetTester tester, {
  AuthState? signedIn,
  Size size = const Size(360, 640),
  double textScale = 1.0,
  Duration busyRetryDelay = const Duration(seconds: 3),
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(signedIn ?? signedInAs(Role.miner)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      localStepsRepositoryProvider.overrideWith((ref) async => steps),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(const DeviceKeyReady(fingerprint)),
      ),
      clockProvider.overrideWithValue(() => now),
      syncBusyRetryDelayProvider.overrideWithValue(busyRetryDelay),
    ],
  );
  final tile = find.text(AppText.sendMyWork);
  await scrollTo(
    tester,
    tile,
    scrollable: find.byType(Scrollable).first,
    settle: false,
  );
  await tester.tap(tile);
  await frames(tester);
}

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Future<void> send(WidgetTester tester) async {
  final send = button(AppText.sendNow);
  await tester.ensureVisible(send);
  await tester.pump();
  await tester.tap(send);
  await frames(tester);
}

Future<void> queue(int count) => queueSteps(
  steps,
  count: count,
  start: now.subtract(const Duration(hours: 1)),
);

void main() {
  setUp(() {
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
    server = FakeSyncServer();
    // Before signedInAs's token runs out (2026-11-16 10:00).
    now = DateTime.utc(2026, 11, 16, 9);
  });
  tearDown(() => database.close());

  testWidgets('the home tile opens it, with the waiting count', (tester) async {
    await queue(2);
    await open(tester);

    expect(app.path, AppRoutes.minerSync);
    expect(find.text(AppText.waitingOnPhone(2)), findsOneWidget);
    expect(find.text(AppText.countSentToServer(0)), findsOneWidget);
    expect(find.text(AppText.countOfWhichUnderReview(0)), findsOneWidget);
    expect(find.text(AppText.countNeedsAttention(0)), findsOneWidget);
    expect(server.batches, isEmpty); // opening sends nothing
  });

  testWidgets('all flagged (the A57 outside the demo zone): sent to the '
      'server, of which under review', (tester) async {
    await queue(3);
    for (var n = 1; n <= 3; n++) {
      server.outcomes[stepIdFor(n)] = {
        'outcome': 'flagged',
        'code': 'GPS_ZONE',
        'message':
            'The record was saved, but its location is outside every '
            'registered extraction zone. An officer will review it.',
        'transactionId': 'tx-$n',
        'reviewStatus': 'flagged',
      };
    }
    await open(tester);

    await send(tester);

    expect(
      find.text(AppText.resultSentToServer(3, underReview: 3)),
      findsOneWidget,
    );
    expect(find.text(AppText.countSentToServer(3)), findsOneWidget);
    expect(find.text(AppText.countOfWhichUnderReview(3)), findsOneWidget);
    expect(find.text(AppText.countNeedsAttention(0)), findsOneWidget);
    expect(find.text(AppText.nothingWaiting), findsOneWidget);
  });

  testWidgets('another role cannot open it', (tester) async {
    app = await AppHarness.pump(
      tester,
      FakeAuthController(signedInAs(Role.transporter)),
    );
    app.container.read(appRouterProvider).go(AppRoutes.minerSync);
    await tester.pumpAndSettle();
    expect(app.path, AppRoutes.transporter);
  });

  testWidgets('nothing waiting', (tester) async {
    await open(tester);
    expect(find.text(AppText.nothingWaiting), findsOneWidget);
  });

  testWidgets('Send: progress while sending, then the result and time', (
    tester,
  ) async {
    await queue(2);
    server.hold = Completer<void>();
    await open(tester);

    await send(tester);

    expect(find.text(AppText.sendingProgress(0, 2)), findsOneWidget);
    expect(find.text(AppText.sendingSlowServer), findsOneWidget);
    final busy = tester.widget<ButtonStyleButton>(button(AppText.sendingNow));
    expect(busy.onPressed, isNull);

    server.hold!.complete();
    await frames(tester);

    expect(
      find.text(AppText.resultSentToServer(2, underReview: 0)),
      findsOneWidget,
    );
    expect(find.text(AppText.countSentToServer(2)), findsOneWidget);
    expect(find.text(AppText.nothingWaiting), findsOneWidget);
    // When, in the phone's own time, and why.
    expect(
      find.text(AppText.lastSendAt(now.toLocal(), AppText.sendYouTapped)),
      findsOneWidget,
    );
    // Tests run in debug mode, so the send's duration is shown.
    expect(find.textContaining('The send took'), findsOneWidget);
  });

  testWidgets('a send after a save says so', (tester) async {
    await queue(1);
    await open(tester);

    unawaited(
      app.container
          .read(syncServiceProvider.notifier)
          .syncNow(SyncTrigger.afterSave),
    );
    await frames(tester);

    expect(
      find.text(AppText.lastSendAt(now.toLocal(), AppText.sendAfterSave)),
      findsOneWidget,
    );
  });

  testWidgets('stopped for the password, then the password is accepted: '
      'the stale stop goes and a new send runs (found on the A57)', (
    tester,
  ) async {
    await queue(1);
    await open(tester, signedIn: SignedInNeedsPassword(userOf(Role.miner)));

    // The automatic send at app start, before the password.
    unawaited(
      app.container
          .read(syncServiceProvider.notifier)
          .syncNow(SyncTrigger.resume),
    );
    await frames(tester);
    expect(find.text(AppText.notSentNeedsPassword), findsOneWidget);

    // The password accepted (from the home's notice, say), within the 2
    // minutes. The real controller becomes SignedIn and announces it.
    now = now.add(const Duration(minutes: 1));
    app.auth.setState(signedInAs(Role.miner));
    app.container.read(signedInEventsProvider).report(userOf(Role.miner));
    await frames(tester);

    expect(find.text(AppText.notSentNeedsPassword), findsNothing);
    expect(
      find.text(AppText.resultSentToServer(1, underReview: 0)),
      findsOneWidget,
    );
    expect(
      find.text(AppText.lastSendAt(now.toLocal(), AppText.sendAutomatic)),
      findsOneWidget,
    );
    expect(server.batches, hasLength(1));
  });

  testWidgets('at most one password prompt at a time', (tester) async {
    await open(tester, signedIn: SignedInNeedsPassword(userOf(Role.miner)));
    final context = tester.element(find.byType(SendWorkScreen));

    // Two callers at once (a double tap, or two buttons): one dialog, and
    // both get its answer.
    final first = showPasswordPrompt(context);
    final second = showPasswordPrompt(context);
    await frames(tester);
    expect(identical(first, second), isTrue);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);

    await tester.tap(button(AppText.cancel));
    await frames(tester);
    expect(await first, isFalse);
    expect(find.byType(PasswordPromptDialog), findsNothing);

    // Once it is closed, a new one may open.
    final third = showPasswordPrompt(context);
    await frames(tester);
    expect(identical(third, first), isFalse);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);
  });

  testWidgets('offline: not sent, the work still counted as waiting', (
    tester,
  ) async {
    await queue(2);
    server.next.add(offline);
    await open(tester);

    await send(tester);

    expect(find.text(AppText.notSentOffline), findsOneWidget);
    expect(find.text(AppText.waitingOnPhone(2)), findsOneWidget);
  });

  testWidgets('the phone busy for a moment: a calm line, never "cannot be '
      'opened", then the retry sends it', (tester) async {
    await queue(1);
    final flaky = FlakyLocalDatabase(database);
    steps = LocalStepsRepository(flaky);
    await open(tester);

    // The send's first database call meets a lock (the emulator's case).
    flaky.failNext(const DatabaseBusy('key-check'));
    await send(tester);

    expect(find.text(AppText.notSentPhoneBusy), findsOneWidget);
    expect(find.text(AppText.savedWorkProblem), findsNothing);
    expect(find.text(AppText.waitingOnPhone(1)), findsOneWidget);
    expect(server.batches, isEmpty);

    // The one retry, after its short wait.
    await tester.pump(const Duration(seconds: 3));
    await frames(tester);

    expect(server.batches, hasLength(1));
    expect(
      find.text(AppText.resultSentToServer(1, underReview: 0)),
      findsOneWidget,
    );
    expect(find.text(AppText.notSentPhoneBusy), findsNothing);
    expect(find.text(AppText.nothingWaiting), findsOneWidget);
  });

  testWidgets('a real open failure still says "cannot be opened"', (
    tester,
  ) async {
    await queue(1);
    final flaky = FlakyLocalDatabase(database);
    steps = LocalStepsRepository(flaky);
    await open(tester);

    flaky.failNext(const DatabaseWrongKey());
    await send(tester);

    expect(find.text(AppText.savedWorkProblem), findsOneWidget);
    expect(find.text(AppText.notSentPhoneBusy), findsNothing);
  });

  testWidgets('the server too slow: not sent, try again', (tester) async {
    await queue(1);
    server.next.add(timedOut);
    await open(tester);

    await send(tester);
    // The request is at the server, waiting for its time limit (90 s).
    expect(server.batches, hasLength(1));
    expect(server.timeLimits, [const Duration(seconds: 90)]);
    expect(find.text(AppText.sendingProgress(0, 1)), findsOneWidget);

    server.timeLimit.complete();
    await frames(tester);

    expect(find.text(AppText.notSentTimedOut), findsOneWidget);
    expect(find.text(AppText.waitingOnPhone(1)), findsOneWidget);
  });

  testWidgets('flagged: under review, with the server\'s message', (
    tester,
  ) async {
    await queue(1);
    const message =
        'This custody record was already registered. Your record was saved, '
        'and an officer will review it.';
    server.outcomes[stepIdFor(1)] = {
      'outcome': 'flagged',
      'code': 'DUPLICATE_CONSIGNMENT',
      'message': message,
      'transactionId': 'tx-9',
      'reviewStatus': 'flagged',
      'alerts': ['duplicate_consignment'],
    };
    await open(tester);

    await send(tester);

    expect(
      find.text(AppText.resultSentToServer(1, underReview: 1)),
      findsOneWidget,
    );
    expect(
      find.text(AppText.underReviewLine(qrCodeFor(1), message)),
      findsOneWidget,
    );
    expect(find.text(AppText.countSentToServer(1)), findsOneWidget);
    expect(find.text(AppText.countOfWhichUnderReview(1)), findsOneWidget);
  });

  testWidgets('rejected: the code, and ask the administrator', (tester) async {
    await queue(1);
    server.outcomes[stepIdFor(1)] = {
      'outcome': 'rejected',
      'code': 'STEP_ID_CONFLICT',
      'message': 'A different record with this id was already stored.',
    };
    await open(tester);

    await send(tester);

    expect(find.text(AppText.resultRejected(1)), findsOneWidget);
    expect(
      find.text(AppText.rejectedLine(qrCodeFor(1), 'STEP_ID_CONFLICT')),
      findsOneWidget,
    );
    expect(find.text(AppText.countNeedsAttention(1)), findsOneWidget);
  });

  testWidgets('a duplicate resend shows as sent', (tester) async {
    await queue(1);
    server.stored[stepIdFor(1)] = 'tx-earlier';
    await open(tester);

    await send(tester);

    expect(
      find.text(AppText.resultSentToServer(1, underReview: 0)),
      findsOneWidget,
    );
  });

  testWidgets('session expired: the password first, then the send', (
    tester,
  ) async {
    await queue(1);
    await open(tester, signedIn: SignedInNeedsPassword(userOf(Role.miner)));

    await send(tester);
    expect(find.text(AppText.enterYourPassword), findsOneWidget);
    expect(server.batches, isEmpty);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      fakePassword,
    );
    await tester.tap(button(AppText.continueLabel));
    await frames(tester);

    expect(
      find.text(AppText.resultSentToServer(1, underReview: 0)),
      findsOneWidget,
    );
    expect(server.batches, hasLength(1));
  });

  testWidgets('session expired, prompt cancelled: nothing sent', (
    tester,
  ) async {
    await queue(1);
    await open(tester, signedIn: SignedInNeedsPassword(userOf(Role.miner)));

    await send(tester);
    await tester.tap(button(AppText.cancel));
    await frames(tester);

    expect(server.batches, isEmpty);
    expect(find.text(AppText.waitingOnPhone(1)), findsOneWidget);
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('a mixed result: $name', (tester) async {
        await queue(3);
        server.outcomes[stepIdFor(2)] = {
          'outcome': 'flagged',
          'code': 'GPS_ZONE',
          'message':
              'The record was saved, but its location is outside every '
              'registered extraction zone. An officer will review it.',
          'transactionId': 'tx-8',
          'reviewStatus': 'flagged',
        };
        server.outcomes[stepIdFor(3)] = {
          'outcome': 'rejected',
          'code': 'PAYLOAD_MALFORMED',
          'message': 'Not in the signed format.',
        };
        await open(tester, size: size, textScale: scale);
        await send(tester);
        expect(tester.takeException(), isNull);
        expect(
          find.text(AppText.resultSentToServer(2, underReview: 1)),
          findsOneWidget,
        );
      });
    }
  });
}
