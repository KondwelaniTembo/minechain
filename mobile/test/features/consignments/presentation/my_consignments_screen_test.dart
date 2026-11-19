// "My consignments" inside the real app and router, with the real
// repository on an in-memory database, the real sync service, and a fake
// server behind MockClient (plan M7, decision Mobile (34)).
//
// pumpAndSettle is avoided after the screen opens, as on "Send my work":
// [frames] draws a few frames instead. Rows of the lazy list are reached
// with scrollTo (scrollUntilVisible); misses stay fatal.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/database/local_settings.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/consignments/presentation/my_consignments_screen.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/registration/data/location_source.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';
import 'package:minechain/features/sync/data/sync_service.dart';
import 'package:minechain/features/sync/domain/sync_report.dart';

import '../../../fakes/app_harness.dart';
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

/// Starts the app as a miner and opens the list from the home tile.
Future<void> open(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(signedInAs(Role.miner)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      localStepsRepositoryProvider.overrideWith((ref) async => steps),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(const DeviceKeyReady(fingerprint)),
      ),
      clockProvider.overrideWithValue(() => now),
      // For the empty state's Register button: no plugin loads.
      locationSourceProvider.overrideWithValue(FakeLocationSource()),
      qrScannerBuilderProvider.overrideWithValue(FakeQrScanner().builder),
      localSettingsProvider.overrideWith(
        (ref) async => LocalSettings(database),
      ),
    ],
  );
  final tile = find.text(AppText.myConsignments);
  await scrollTo(
    tester,
    tile,
    scrollable: find.byType(Scrollable).first,
    settle: false,
  );
  await tester.tap(tile);
  await frames(tester);
}

/// The list's own scrollable (the home below it is offstage).
Finder get list => find.descendant(
  of: find.byType(MyConsignmentsScreen),
  matching: find.byType(Scrollable),
);

Future<void> queue(int count, {String actor = minerId}) => queueSteps(
  steps,
  count: count,
  actor: actor,
  start: now.subtract(const Duration(hours: 1)),
);

/// Six records, one in each state (record 6 is the newest, so on top).
Future<void> sixStates() async {
  await queue(6);
  final longAgo = now.subtract(const Duration(hours: 80));
  await steps.applyResults([
    // 1 stays queued: waiting.
    StepDeferred(
      stepIdFor(2),
      code: 'STAGE_NOT_READY',
      message: 'Not ready.',
      nextAttemptAt: now.add(const Duration(hours: 1)),
    ),
  ], at: longAgo); // deferred for 80 hours: stuck
  await steps.applyResults([
    StepSynced(stepIdFor(3), reviewStatus: 'passed', transactionId: 'tx-3'),
    StepFlagged(
      stepIdFor(4),
      code: 'GPS_ZONE',
      message:
          'The record was saved, but its location is outside every '
          'registered extraction zone. An officer will review it.',
      reviewStatus: 'flagged',
      transactionId: 'tx-4',
    ),
    StepRejected(stepIdFor(5), code: 'PAYLOAD_MALFORMED', message: 'Bad.'),
    StepRejected(
      stepIdFor(6),
      code: 'PAYLOAD_UNSUPPORTED_VERSION',
      message: 'Old.',
    ),
  ], at: now);
}

void main() {
  setUp(() {
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
    server = FakeSyncServer();
    now = DateTime.utc(2026, 11, 16, 9);
  });
  tearDown(() => database.close());

  testWidgets('the home tile opens it; every state in the words of Send my '
      'work, with an icon', (tester) async {
    await sixStates();
    await open(tester, size: const Size(400, 2400));

    expect(app.path, AppRoutes.minerConsignments);
    final shown = <(String, IconData)>[
      (AppText.stepUpdateApp, Icons.block),
      (AppText.stepRejected('PAYLOAD_MALFORMED'), Icons.block),
      (AppText.stepUnderReview, Icons.policy),
      (AppText.stepSent, Icons.cloud_done),
      (AppText.stepStuck, Icons.schedule),
      (AppText.stepWaiting, Icons.phone_android),
    ];
    for (final (text, icon) in shown) {
      expect(find.text(text), findsOneWidget, reason: text);
      // The icon is in the same row as the words: never colour alone.
      expect(
        find.descendant(
          of: find.ancestor(of: find.text(text), matching: find.byType(Row)),
          matching: find.byIcon(icon),
        ),
        findsOneWidget,
        reason: text,
      );
    }
    // The server's message under the flagged one, as given.
    expect(find.textContaining('outside every registered'), findsOneWidget);
    // The same words as Send my work's sentences for the same states.
    expect(AppText.waitingOnPhone(1), contains('safe on this phone'));
    expect(AppText.stepWaiting.toLowerCase(), contains('safe on this phone'));
    expect(
      AppText.rejectedLine('X', 'PAYLOAD_MALFORMED'),
      'X: ${AppText.stepRejected('PAYLOAD_MALFORMED').substring(17)}',
    );
  });

  testWidgets('newest first, with the mineral, weight and saved time', (
    tester,
  ) async {
    await queue(2);
    await open(tester);

    final newest = tester.getTopLeft(find.text(qrCodeFor(2))).dy;
    final older = tester.getTopLeft(find.text(qrCodeFor(1))).dy;
    expect(newest, lessThan(older));
    // queueSteps saves gold, 1500 mg: shown in grams (Q2).
    expect(
      find.text(AppText.consignmentWhat(AppText.gold, '1.5', AppText.grams)),
      findsNWidgets(2),
    );
    final saved = now.subtract(const Duration(minutes: 59)).toLocal();
    expect(find.text(AppText.savedAt(saved)), findsOneWidget);
  });

  // Mobile (36), T8: each record's card in the tiles' sand, raised, with a
  // copper outline so its edge shows on the light screen.
  testWidgets('each card: sand, a shadow and a copper outline', (tester) async {
    await queue(2);
    await open(tester);

    final cards = find.byType(Card);
    expect(cards, findsNWidgets(2));
    for (final card in [cards.at(0), cards.at(1)]) {
      final scheme = Theme.of(tester.element(card)).colorScheme;
      final material = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)).first,
      );
      expect(material.color, scheme.secondaryContainer);
      expect(material.elevation, 3);
      expect(
        (material.shape! as RoundedRectangleBorder).side.color,
        scheme.primary,
      );
    }
  });

  testWidgets('only this miner\'s records, and no signed or secret field', (
    tester,
  ) async {
    await queue(1);
    await queueSteps(
      steps,
      count: 1,
      from: 7,
      actor: otherMinerId,
      start: now.subtract(const Duration(hours: 1)),
    );
    await open(tester);

    expect(find.text(qrCodeFor(1)), findsOneWidget);
    expect(find.text(qrCodeFor(7)), findsNothing);
    for (final secret in [
      '-15.419012', // latitude
      '28.288105', // longitude
      'MEUCIQ', // signature
      '4d61912d', // key fingerprint
      'minechain-step', // payload
      stepIdFor(1),
    ]) {
      expect(find.textContaining(secret), findsNothing, reason: secret);
    }
  });

  testWidgets('empty: the sentence and a button to register', (tester) async {
    await open(tester);

    expect(find.text(AppText.noConsignmentsYet), findsOneWidget);
    final register = find.ancestor(
      of: find.text(AppText.registerConsignment),
      matching: find.bySubtype<ButtonStyleButton>(),
    );
    await tester.tap(register);
    await frames(tester);
    expect(app.path, AppRoutes.minerRegister);

    // A record saved meanwhile (as the registration screen would), then
    // back: the list is read again on the way back.
    await queue(1);
    app.container.read(appRouterProvider).pop();
    await frames(tester);
    expect(app.path, AppRoutes.minerConsignments);
    expect(find.text(qrCodeFor(1)), findsOneWidget);
  });

  testWidgets('the list follows a send, without a refresh', (tester) async {
    await queue(1);
    await open(tester);
    expect(find.text(AppText.stepWaiting), findsOneWidget);

    unawaited(
      app.container.read(syncServiceProvider.notifier).syncNow(SyncTrigger.tap),
    );
    await frames(tester);

    expect(server.batches, hasLength(1));
    expect(find.text(AppText.stepSent), findsOneWidget);
    expect(find.text(AppText.stepWaiting), findsNothing);
  });

  testWidgets('a flagged answer from a send shows under review with the '
      'server\'s message', (tester) async {
    await queue(1);
    server.outcomes[stepIdFor(1)] = {
      'outcome': 'flagged',
      'code': 'DUPLICATE_CONSIGNMENT',
      'message':
          'This custody record was already registered. Your record was '
          'saved, and an officer will review it.',
      'transactionId': 'tx-9',
      'reviewStatus': 'flagged',
      'alerts': ['duplicate_consignment'],
    };
    await open(tester);

    unawaited(
      app.container.read(syncServiceProvider.notifier).syncNow(SyncTrigger.tap),
    );
    await frames(tester);

    expect(find.text(AppText.stepUnderReview), findsOneWidget);
    expect(find.textContaining('already registered'), findsOneWidget);
  });

  testWidgets('the phone busy for a moment: calm, never "cannot be opened", '
      'and Try again shows the list', (tester) async {
    await queue(1);
    final flaky = FlakyLocalDatabase(database)
      ..failNext(const DatabaseBusy('key-check'));
    steps = LocalStepsRepository(flaky);
    await open(tester);

    expect(find.text(AppText.consignmentsPhoneBusy), findsOneWidget);
    expect(find.text(AppText.savedWorkProblem), findsNothing);

    await tester.tap(
      find.ancestor(
        of: find.text(AppText.tryAgain),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    await frames(tester);
    expect(find.text(qrCodeFor(1)), findsOneWidget);
  });

  testWidgets('a real open failure still says "cannot be opened"', (
    tester,
  ) async {
    final flaky = FlakyLocalDatabase(database)
      ..failNext(const DatabaseWrongKey());
    steps = LocalStepsRepository(flaky);
    await open(tester);

    expect(find.text(AppText.savedWorkProblem), findsOneWidget);
    expect(find.text(AppText.consignmentsPhoneBusy), findsNothing);
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('portrait 360x640, text 2.0', const Size(360, 640), 2.0),
      ('landscape 640x360, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('$name: every record reachable, nothing overflows', (
        tester,
      ) async {
        await sixStates();
        await open(tester, size: size, textScale: scale);

        // Oldest (record 1) is last in the lazy list.
        await scrollTo(
          tester,
          find.text(AppText.stepWaiting),
          scrollable: list,
          settle: false,
        );
        expect(find.text(AppText.stepWaiting), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name: the empty state fits', (tester) async {
        await open(tester, size: size, textScale: scale);
        await tester.ensureVisible(find.text(AppText.registerConsignment));
        await tester.pump();
        expect(find.text(AppText.noConsignmentsYet), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
