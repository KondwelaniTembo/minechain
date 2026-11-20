// "My purchases" and the buyer's "Send my work" (buyer purchase T3), inside
// the real app and router, with the real repository on an in-memory
// database, the real sync service and a fake server. The screens are the
// miner's own, so their states and words are covered by
// my_consignments_screen_test.dart and send_work_screen_test.dart; here,
// what the buyer's paths add: the purchases listed by type with the weight
// in the hint's unit, the ways in and out, and the role rule.
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

final buyer = userOf(Role.buyer);

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

Future<void> start(
  WidgetTester tester, {
  AuthState? auth,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(auth ?? signedInAs(Role.buyer)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      localStepsRepositoryProvider.overrideWith((ref) async => steps),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(const DeviceKeyReady(fingerprint)),
      ),
      clockProvider.overrideWithValue(() => now),
      // For the empty list's "Record purchase" button: no plugin loads.
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

Finder get list => find.descendant(
  of: find.byType(MyConsignmentsScreen),
  matching: find.byType(Scrollable),
);

/// A step of [type] saved [minutesAgo] minutes ago, with the unsigned
/// [hint].
Future<void> saved(
  int n, {
  String type = 'purchase',
  String? hint = 'copper',
  String weightMg = '1900000',
  String? actor,
  int minutesAgo = 30,
}) => steps.insert(
  NewLocalStep(
    stepId: stepIdFor(n),
    actorId: actor ?? buyer.id,
    type: type,
    qrCode: qrCodeFor(n),
    mineral: null,
    mineralHint: hint,
    weightMg: weightMg,
    latitude: '-15.418900',
    longitude: '28.288700',
    capturedAt: '2026-11-16T08:00:00.000Z',
    // Not a valid signed payload: the fake server only reads step_id.
    payload: 'minechain-step/1/$type\nstep_id=${stepIdFor(n)}\n',
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

  group('My purchases', () {
    testWidgets('the tile opens /buyer/purchases: each purchase as "Bought '
        '…", newest first, the weight in the hint\'s unit', (tester) async {
      await saved(1, minutesAgo: 50); // copper, 1.9 kg
      await saved(2, hint: 'gold', weightMg: '15300', minutesAgo: 20);
      await openTile(tester, AppText.myPurchases);

      expect(app.path, AppRoutes.buyerPurchases);
      final newest = find.text(AppText.boughtRecord(qrCodeFor(2)));
      final older = find.text(AppText.boughtRecord(qrCodeFor(1)));
      expect(newest, findsOneWidget);
      expect(older, findsOneWidget);
      expect(
        tester.getTopLeft(newest).dy,
        lessThan(tester.getTopLeft(older).dy),
      );
      expect(
        find.text(
          AppText.consignmentWhat(AppText.copper, '1.9', AppText.kilograms),
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppText.consignmentWhat(AppText.gold, '15.3', AppText.grams)),
        findsOneWidget,
      );
      expect(find.text(AppText.stepWaiting), findsNWidgets(2));
    });

    testWidgets('only this buyer\'s purchases: no other account\'s, and no '
        'other step type', (tester) async {
      await saved(1);
      await saved(2, actor: '3f2b6c1e-0000-4000-8000-000000000999');
      await saved(3, type: 'handoff');
      await openTile(tester, AppText.myPurchases);

      expect(find.text(AppText.boughtRecord(qrCodeFor(1))), findsOneWidget);
      expect(find.textContaining(qrCodeFor(2)), findsNothing);
      expect(find.textContaining(qrCodeFor(3)), findsNothing);
    });

    testWidgets('empty: the sentence, and "Record purchase" opens its '
        'screen', (tester) async {
      await openTile(tester, AppText.myPurchases);

      expect(find.text(AppText.noPurchasesYet), findsOneWidget);
      expect(find.text(AppText.noHandoffsYet), findsNothing);
      await tapIt(tester, button(AppText.recordPurchase));
      expect(app.path, AppRoutes.buyerPurchase);
    });

    testWidgets('the back arrow returns to the home; opened by its address, '
        'it goes to the buyer\'s home', (tester) async {
      await openTile(tester, AppText.myPurchases);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.buyer);

      await go(tester, AppRoutes.buyerPurchases);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.buyer);
    });

    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('$name, text 2.0: every purchase reachable, nothing '
          'overflows', (tester) async {
        for (var n = 1; n <= 4; n++) {
          await saved(n, minutesAgo: 60 - n);
        }
        await openTile(tester, AppText.myPurchases, size: size, textScale: 2.0);
        await scrollTo(
          tester,
          find.text(AppText.boughtRecord(qrCodeFor(1))),
          scrollable: list,
          settle: false,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Send my work for a buyer', () {
    testWidgets('the tile opens /buyer/sync; Send sends the purchase, and My '
        'purchases then says sent', (tester) async {
      await saved(1);
      await openTile(tester, AppText.sendMyWork);

      expect(app.path, AppRoutes.buyerSync);
      expect(find.text(AppText.waitingOnPhone(1)), findsOneWidget);

      await tapIt(tester, button(AppText.sendNow));
      expect(server.batches, hasLength(1));
      expect(find.text(AppText.nothingWaiting), findsOneWidget);

      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.buyer);
      await tapIt(tester, find.text(AppText.myPurchases));
      expect(find.text(AppText.stepSent), findsOneWidget);
    });

    testWidgets('opened by its address, the back arrow goes to the buyer\'s '
        'home', (tester) async {
      await start(tester);
      await go(tester, AppRoutes.buyerSync);
      await tapIt(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.buyer);
    });
  });

  // Redirect rule 4: a path under another role's home sends you home.
  group('the role rule', () {
    for (final role in [
      Role.miner,
      Role.transporter,
      Role.officer,
      Role.admin,
    ]) {
      for (final path in [AppRoutes.buyerPurchases, AppRoutes.buyerSync]) {
        testWidgets('${role.name} cannot open $path', (tester) async {
          await start(tester, auth: signedInAs(role));
          await go(tester, path);
          expect(app.path, '/${role.name}');
          expect(find.text(AppText.myPurchases), findsNothing);
        });
      }
    }
  });
}
