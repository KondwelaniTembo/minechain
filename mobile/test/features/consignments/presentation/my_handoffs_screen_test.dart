// "My handoffs" and the transporter's "Send my work" (transporter handoff
// T5), inside the real app and router, with the real repository on an
// in-memory database, the real sync service and a fake server. The screens
// are the miner's own, so their states and words are covered by
// my_consignments_screen_test.dart and send_work_screen_test.dart; here,
// what the transporter's paths add: the handoffs listed by type with the
// weight in the hint's unit, the ways in and out, and the role rule.
//
// pumpAndSettle is avoided after the app opens, as on the miner's tests:
// [frames] draws a few frames instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/consignments/presentation/my_consignments_screen.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/registration/data/location_source.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart';
import '../../../fakes/fake_sync_server.dart';

const fingerprint =
    '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53';

final transporter = userOf(Role.transporter);

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

/// The app on [auth]'s home, with the fakes in place.
Future<void> start(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.transporter)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      localStepsRepositoryProvider.overrideWith((ref) async => steps),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(const DeviceKeyReady(fingerprint)),
      ),
      clockProvider.overrideWithValue(() => now),
      // For the empty list's "Take custody" button: no plugin loads.
      locationSourceProvider.overrideWithValue(FakeLocationSource()),
      qrScannerBuilderProvider.overrideWithValue(FakeQrScanner().builder),
    ],
  );
}

/// Start, then tap the home tile [label].
Future<void> openTile(
  WidgetTester tester,
  String label, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await start(tester, size: size, textScale: textScale);
  final tile = find.text(label);
  await scrollTo(
    tester,
    tile,
    scrollable: find.byType(Scrollable).first,
    settle: false,
  );
  await tester.tap(tile);
  await frames(tester);
}

/// Opens [path] by its address, with no screen below it.
Future<void> go(WidgetTester tester, String path) async {
  app.container.read(appRouterProvider).go(path);
  await frames(tester);
}

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Future<void> tapIt(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await frames(tester);
}

/// The list's own scrollable (the home below it is offstage).
Finder get list => find.descendant(
  of: find.byType(MyConsignmentsScreen),
  matching: find.byType(Scrollable),
);

/// A handoff saved [minutesAgo] minutes ago, with the unsigned [hint].
Future<void> handoff(
  int n, {
  String? hint = 'copper',
  String weightMg = '1500000',
  String? actor,
  int minutesAgo = 30,
}) => steps.insert(
  NewLocalStep(
    stepId: stepIdFor(n),
    actorId: actor ?? transporter.id,
    type: 'handoff',
    qrCode: qrCodeFor(n),
    mineral: null,
    mineralHint: hint,
    weightMg: weightMg,
    latitude: '-15.418900',
    longitude: '28.288700',
    capturedAt: '2026-11-16T08:00:00.000Z',
    // Not a valid signed payload: the fake server only reads step_id.
    payload: 'minechain-step/1/handoff\nstep_id=${stepIdFor(n)}\n',
    signature: 'MEUCIQFAKE${n}FAKE==',
    keyFingerprint: fingerprint,
    gpsAccuracyM: 4,
    createdAt: now.subtract(Duration(minutes: minutesAgo)),
  ),
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

  group('My handoffs', () {
    testWidgets('the tile opens /transporter/handoffs: each handoff as "Took '
        'custody of …", newest first, the weight in the hint\'s unit', (
      tester,
    ) async {
      await handoff(1, minutesAgo: 50); // copper, 1.5 kg
      await handoff(2, hint: 'gold', weightMg: '15300', minutesAgo: 20);
      await openTile(tester, AppText.myHandoffs);

      expect(app.path, AppRoutes.transporterHandoffs);
      expect(find.text(AppText.myHandoffs), findsOneWidget);
      final newest = find.text(AppText.tookCustodyOf(qrCodeFor(2)));
      final older = find.text(AppText.tookCustodyOf(qrCodeFor(1)));
      expect(newest, findsOneWidget);
      expect(older, findsOneWidget);
      expect(
        tester.getTopLeft(newest).dy,
        lessThan(tester.getTopLeft(older).dy),
      );
      expect(
        find.text(
          AppText.consignmentWhat(AppText.copper, '1.5', AppText.kilograms),
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppText.consignmentWhat(AppText.gold, '15.3', AppText.grams)),
        findsOneWidget,
      );
      expect(find.text(AppText.stepWaiting), findsNWidgets(2));
    });

    testWidgets('a handoff with no hint (a row from before schema version 2) '
        'shows its weight in mg', (tester) async {
      await handoff(1, hint: null);
      await openTile(tester, AppText.myHandoffs);
      expect(find.text('1500000 ${AppText.milligrams}'), findsOneWidget);
    });

    testWidgets('only this transporter\'s handoffs: no other account\'s, and '
        'no other step type', (tester) async {
      await handoff(1);
      await handoff(2, actor: '3f2b6c1e-0000-4000-8000-000000000999');
      await queueSteps(
        steps,
        count: 1,
        from: 3,
        actor: transporter.id, // a registration row, whoever saved it
        start: now.subtract(const Duration(hours: 1)),
      );
      await openTile(tester, AppText.myHandoffs);

      expect(find.text(AppText.tookCustodyOf(qrCodeFor(1))), findsOneWidget);
      expect(find.textContaining(qrCodeFor(2)), findsNothing);
      expect(find.textContaining(qrCodeFor(3)), findsNothing);
    });

    testWidgets('empty: the sentence, and "Take custody" opens its screen', (
      tester,
    ) async {
      await openTile(tester, AppText.myHandoffs);

      expect(find.text(AppText.noHandoffsYet), findsOneWidget);
      expect(find.text(AppText.noConsignmentsYet), findsNothing);
      await tapIt(tester, button(AppText.takeCustody));
      expect(app.path, AppRoutes.transporterCustody);
    });

    testWidgets('the back arrow returns to the home; opened by its address, '
        'it goes to the transporter\'s home', (tester) async {
      await openTile(tester, AppText.myHandoffs);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);

      await go(tester, AppRoutes.transporterHandoffs);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);
    });

    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('$name, text 2.0: every handoff reachable, nothing '
          'overflows', (tester) async {
        for (var n = 1; n <= 4; n++) {
          await handoff(n, minutesAgo: 60 - n);
        }
        await openTile(tester, AppText.myHandoffs, size: size, textScale: 2.0);
        // The oldest is last.
        await scrollTo(
          tester,
          find.text(AppText.tookCustodyOf(qrCodeFor(1))),
          scrollable: list,
          settle: false,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Send my work for a transporter', () {
    testWidgets('the tile opens /transporter/sync; Send sends the handoff, '
        'and My handoffs then says sent', (tester) async {
      await handoff(1);
      await openTile(tester, AppText.sendMyWork);

      expect(app.path, AppRoutes.transporterSync);
      expect(find.text(AppText.waitingOnPhone(1)), findsOneWidget);

      await tapIt(tester, button(AppText.sendNow));
      expect(server.batches, hasLength(1));
      expect(find.text(AppText.nothingWaiting), findsOneWidget);

      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);
      final tile = find.text(AppText.myHandoffs);
      await tapIt(tester, tile);
      expect(find.text(AppText.stepSent), findsOneWidget);
    });

    // Redirect rule 4 would also turn a transporter's /miner into
    // /transporter, so this test passes with the old miner-only back arrow
    // too (checked in T5); the role-aware arrow only saves that redirect.
    testWidgets('opened by its address, the back arrow goes to the '
        'transporter\'s home, not the miner\'s', (tester) async {
      await start(tester);
      await go(tester, AppRoutes.transporterSync);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);
    });

    testWidgets('the miner\'s, opened by its address, still goes to the '
        'miner\'s home', (tester) async {
      await start(tester, auth: signedInAs(Role.miner));
      await go(tester, AppRoutes.minerSync);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.miner);
    });
  });

  // Redirect rule 4: a path under another role's home sends you home.
  group('the role rule', () {
    for (final role in [Role.miner, Role.buyer, Role.officer, Role.admin]) {
      for (final path in [
        AppRoutes.transporterHandoffs,
        AppRoutes.transporterSync,
      ]) {
        testWidgets('${role.name} cannot open $path', (tester) async {
          await start(tester, auth: signedInAs(role));
          await go(tester, path);
          expect(app.path, '/${role.name}');
          expect(find.text(AppText.myHandoffs), findsNothing);
        });
      }
    }
  });
}
