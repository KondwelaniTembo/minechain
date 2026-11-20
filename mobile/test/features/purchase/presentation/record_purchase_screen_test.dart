// "Record purchase" (buyer purchase plan, T2): the "Take custody" page with
// kind: purchase, opened from the buyer's home. What differs from the
// transporter's page is tested here: the way in and its role rule, the
// buyer's words, Q1 (no earlier weight shown), Q2 (the buyer's own accepted
// purchase refused), Q3 (a 404 needs "Record anyway"), Q4 by purchase, and
// the signed purchase row. The shared flow (GPS, weight parsing, the gates)
// is covered by take_custody_screen_test.dart.
//
// The whole app runs with the real router, a fake camera, a fake GPS, a fake
// server, a fake Keystore channel that "signs", and the real repository and
// purchase save on an in-memory database.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/clock.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/data/device_key_channel.dart';
import 'package:minechain/features/device_key/domain/key_alias.dart';
import 'package:minechain/features/device_key/domain/key_fingerprint.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/handoff/presentation/custody_controller.dart';
import 'package:minechain/features/registration/data/location_source.dart';
import 'package:minechain/features/registration/domain/gps_fix.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';
import 'package:minechain/features/sync/data/sync_service.dart';
import 'package:minechain/features/sync/domain/sync_report.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_admin_server.dart' show json200;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';
import '../../../fakes/fake_registration.dart'
    show FakeLocationSource, FakeQrScanner, StaticDeviceKeyController, reading;
import '../../../fakes/flaky_database.dart';
import '../../../fakes/signing_channel.dart';

/// The GPS: the first reading is a fresh, usable fix, so the location's
/// progress bar never keeps pumpAndSettle waiting.
class FixingLocationSource extends FakeLocationSource {
  @override
  Stream<GpsReading> readings() async* {
    final later = super.readings();
    yield reading(systemClock());
    yield* later;
  }
}

final buyer = userOf(Role.buyer);
final phoneKey = fakeKey(5);
final fingerprint = keyFingerprint(phoneKey);

late FakeCheckServer server;
late FakeQrScanner camera;
late FixingLocationSource gps;
late SigningChannel channel;
late InMemoryLocalDatabase database;
late FlakyLocalDatabase flaky;
late LocalStepsRepository steps;
late AppHarness app;

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
      qrScannerBuilderProvider.overrideWithValue(camera.builder),
      locationSourceProvider.overrideWithValue(gps),
      deviceKeyChannelProvider.overrideWithValue(channel),
      localStepsRepositoryProvider.overrideWith((ref) => Future.value(steps)),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(DeviceKeyReady(fingerprint)),
      ),
    ],
  );
}

/// Start as the buyer, then open the page from the home's tile.
Future<void> open(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await start(tester, size: size, textScale: textScale);
  await tapVisible(tester, find.text(AppText.recordPurchase));
}

Future<void> scan(WidgetTester tester, String code) async {
  camera.scan(code);
  await tester.pumpAndSettle();
}

void answerWith(Map<String, Object?> body) =>
    server.answer = (request) => json200(body);

void goOffline() =>
    server.answer = (request) =>
        throw http.ClientException('no network', request.url);

CustodyState purchaseState() => app.container.read(purchaseControllerProvider);

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Finder get saveButton => button(AppText.save);
Finder get weightField => find.byType(TextField);

Future<void> typeWeight(WidgetTester tester, String text) async {
  await tester.ensureVisible(weightField);
  await tester.pumpAndSettle();
  await tester.enterText(weightField, text);
  await tester.pumpAndSettle();
}

Future<List<LocalStep>> savedRows() =>
    LocalStepsRepository(database).listForActor(buyer.id);

/// A saved step of [type] for [qrCode] by [actorId], at 09:30 UTC on 20 Nov.
NewLocalStep savedStep({
  required String actorId,
  String type = 'purchase',
  String qrCode = knownQrCode,
}) => NewLocalStep(
  stepId: '6f1d2c3a-0000-4000-8000-000000000401',
  actorId: actorId,
  type: type,
  qrCode: qrCode,
  mineral: null,
  mineralHint: 'gold',
  weightMg: '1495000',
  latitude: '-15.418900',
  longitude: '28.288700',
  capturedAt: '2026-11-20T09:30:00.000Z',
  payload: 'minechain-step/1/$type\n',
  signature: 'MEQCIF==',
  keyFingerprint: fingerprint,
  gpsAccuracyM: 4.0,
  createdAt: DateTime.utc(2026, 11, 20, 9, 30),
);

/// The server's owner view after this buyer's accepted purchase (Q2),
/// captured at 14:10 UTC on 20 Nov.
Map<String, Object?> boughtByThisBuyer() {
  final purchase = checkedStepJson(type: 'purchase', role: 'buyer', n: 3)
    ..['byYou'] = true
    ..['capturedAt'] = '2026-11-20T14:10:00.000Z';
  return consignmentAnswerJson(
    stage: 'purchased',
    steps: [
      checkedStepJson(),
      checkedStepJson(type: 'handoff', role: 'transporter', n: 2),
      purchase,
    ],
  );
}

/// Not on the server (404, the fake knows one code only): "Record anyway",
/// then copper and 1.9 kg, ready to save.
Future<void> fillInCopperAfter404(WidgetTester tester, String code) async {
  await scan(tester, code);
  await tapVisible(tester, find.text(AppText.recordAnyway));
  await tapVisible(tester, find.text(AppText.copper));
  await typeWeight(tester, '1.9');
}

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
    gps = FixingLocationSource();
    channel = SigningChannel(keys: {deviceKeyAlias(buyer.id): phoneKey});
    database = InMemoryLocalDatabase();
    flaky = FlakyLocalDatabase(database);
    steps = LocalStepsRepository(flaky);
  });
  tearDown(() => database.close());

  group('the way in', () {
    testWidgets('the tile opens /buyer/purchase with the camera and the '
        "buyer's title", (tester) async {
      await open(tester);

      expect(app.path, AppRoutes.buyerPurchase);
      expect(find.text('fake camera'), findsOneWidget);
      expect(find.text(AppText.comingSoon), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(AppText.recordPurchase),
        ),
        findsOneWidget,
      );
      expect(find.text(AppText.takeCustody), findsNothing);
    });

    testWidgets('the back arrow returns to the buyer home', (tester) async {
      await open(tester);
      await tapVisible(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.buyer);
    });

    for (final role in [
      Role.miner,
      Role.transporter,
      Role.officer,
      Role.admin,
    ]) {
      testWidgets('${role.name} cannot open it', (tester) async {
        await start(tester, auth: signedInAs(role));
        app.container.read(appRouterProvider).go(AppRoutes.buyerPurchase);
        await tester.pumpAndSettle();
        expect(app.path, '/${role.name}');
        expect(find.text('fake camera'), findsNothing);
      });
    }
  });

  group('online, in transit', () {
    testWidgets('the mineral from the server, no warning, no "Record '
        'anyway"', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.mineralLine(AppText.gold)), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text(AppText.recordAnyway), findsNothing);
      final state = purchaseState() as CustodyReady;
      expect(state.kind, CustodyStepKind.purchase);
      expect(state.mayContinue, isTrue);
    });

    testWidgets('Q1: no earlier weight is shown before Save, although the '
        "server's answer held them", (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.textContaining('1500000'), findsNothing);
      expect(find.textContaining('1.5'), findsNothing);
      expect(find.textContaining(' kg'), findsNothing);
      expect(find.textContaining('1500 g'), findsNothing);
    });

    testWidgets('gold, 1.5 g: signs a purchase with weight_mg=1500 and no '
        'mineral line, then a send starts', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);
      await typeWeight(tester, '1.5');
      await tapVisible(tester, saveButton);

      expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
      expect(find.text(AppText.recordAnotherPurchase), findsOneWidget);
      final row = (await savedRows()).single;
      expect(row.type, 'purchase');
      expect(row.payload, startsWith('minechain-step/1/purchase\n'));
      expect(row.payload, contains('\nweight_mg=1500\n'));
      expect(row.payload, isNot(contains('mineral')));
      expect(row.mineralHint, 'gold');
      expect(utf8.decode(channel.signed.single), row.payload);
      expect(row.syncState, SyncState.queued);
      final report = app.container.read(syncServiceProvider).last;
      expect(report?.trigger, SyncTrigger.afterSave);
    });
  });

  group('Q2: bought by this buyer already', () {
    testWidgets('refused with the date, the camera stays, nothing stored', (
      tester,
    ) async {
      answerWith(boughtByThisBuyer());
      await open(tester);
      await scan(tester, knownQrCode);

      expect(
        find.text(
          AppText.boughtByYou(DateTime.utc(2026, 11, 20, 14, 10).toLocal()),
        ),
        findsOneWidget,
      );
      expect(find.text('fake camera'), findsOneWidget);
      expect(purchaseState(), isA<CustodyScanning>());
      expect(await savedRows(), isEmpty);
    });

    testWidgets('bought, but not by this buyer: a warning and "Record '
        'anyway"', (tester) async {
      answerWith(consignmentAnswerJson(stage: 'purchased'));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.purchaseAlreadyBought), findsOneWidget);
      expect(find.text(AppText.recordAnyway), findsOneWidget);
      expect((purchaseState() as CustodyReady).mayContinue, isFalse);
    });
  });

  group('Q3: not shown to this buyer (404)', () {
    testWidgets('one sentence, then "Record anyway" before the chips and the '
        'weight', (tester) async {
      await open(tester);
      await scan(tester, 'MC-2026-LSK-0008');

      expect(find.text(AppText.purchaseNotOnServer), findsOneWidget);
      expect(find.text(AppText.custodyNotOnServer), findsNothing);
      expect(find.text(AppText.recordAnyway), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(weightField, findsNothing);

      await tapVisible(tester, find.text(AppText.recordAnyway));
      expect(find.text(AppText.recordingAnyway), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(Mineral.values.length));
    });

    testWidgets('copper, 1.9 kg: signs weight_mg=1900000 under the purchase '
        'header, no mineral line', (tester) async {
      await open(tester);
      await fillInCopperAfter404(tester, 'MC-2026-LSK-0008');
      await tapVisible(tester, saveButton);

      final row = (await savedRows()).single;
      expect(row.type, 'purchase');
      expect(row.qrCode, 'MC-2026-LSK-0008');
      expect(row.payload, startsWith('minechain-step/1/purchase\n'));
      expect(row.payload, contains('\nweight_mg=1900000\n'));
      expect(row.payload, isNot(contains('mineral')));
      expect(row.mineralHint, 'copper');
    });
  });

  group('held and mismatch need "Record anyway"', () {
    testWidgets('held: the buyer\'s "Under review"', (tester) async {
      answerWith(consignmentAnswerJson(held: true));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.purchaseUnderReview), findsOneWidget);
      expect((purchaseState() as CustodyReady).mayContinue, isFalse);
      await tapVisible(tester, find.text(AppText.recordAnyway));
      expect((purchaseState() as CustodyReady).mayContinue, isTrue);
    });

    testWidgets('a mismatch: the buyer\'s warning only', (tester) async {
      answerWith(
        consignmentAnswerJson(
          held: true,
          steps: [checkedStepJson(check: 'mismatch')],
        ),
      );
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.purchaseMismatch), findsOneWidget);
      expect(find.text(AppText.purchaseUnderReview), findsNothing);
      expect(find.text(AppText.recordAnyway), findsOneWidget);
    });
  });

  group('offline or a failed check: the chips, no "Record anyway"', () {
    testWidgets('offline', (tester) async {
      goOffline();
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.custodyOffline), findsOneWidget);
      expect(find.text(AppText.recordAnyway), findsNothing);
      expect(find.byType(ChoiceChip), findsNWidgets(Mineral.values.length));

      await tapVisible(tester, find.text(AppText.copper));
      await typeWeight(tester, '1.9');
      await tapVisible(tester, saveButton);
      expect((await savedRows()).single.type, 'purchase');
    });
  });

  group('Q4: one purchase of a bag per account on this phone', () {
    testWidgets('already bought here: when, nothing sent, the camera stays', (
      tester,
    ) async {
      await steps.insert(savedStep(actorId: buyer.id));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(
        find.text(
          AppText.alreadyBoughtHere(
            DateTime.utc(2026, 11, 20, 9, 30).toLocal(),
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('fake camera'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('a handoff row of the same code by this account does not '
        'count', (tester) async {
      await steps.insert(savedStep(actorId: buyer.id, type: 'handoff'));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(server.requests, hasLength(1));
      expect(purchaseState(), isA<CustodyReady>());
    });

    testWidgets('recorded meanwhile: checked again at Save, nothing signed', (
      tester,
    ) async {
      await open(tester);
      await fillInCopperAfter404(tester, 'MC-2026-LSK-0008');
      await steps.insert(
        savedStep(actorId: buyer.id, qrCode: 'MC-2026-LSK-0008'),
      );

      await tapVisible(tester, saveButton);

      expect(find.text('fake camera'), findsOneWidget);
      expect(find.textContaining('You recorded buying'), findsOneWidget);
      expect(channel.signed, isEmpty);
    });
  });

  group('after Save', () {
    testWidgets('"Record another purchase": the camera, and "2 saved this '
        'time." from the second; "Back to home" goes to the buyer home', (
      tester,
    ) async {
      await open(tester);
      await fillInCopperAfter404(tester, 'MC-2026-LSK-0008');
      await tapVisible(tester, saveButton);
      expect(find.text(AppText.savedThisVisit(2)), findsNothing);

      await tapVisible(tester, button(AppText.recordAnotherPurchase));
      expect(find.text('fake camera'), findsOneWidget);
      await fillInCopperAfter404(tester, 'MC-2026-LSK-0009');
      await tapVisible(tester, saveButton);

      expect(find.text(AppText.savedThisVisit(2)), findsOneWidget);
      expect(await savedRows(), hasLength(2));
      await tapVisible(tester, button(AppText.backToHome));
      expect(app.path, AppRoutes.buyer);
    });
  });

  group('refused saves store nothing', () {
    for (final (name, prepare, sentence) in <(String, void Function(), String)>[
      (
        'no screen lock',
        () => channel.refuse = DeviceKeyError.noScreenLock,
        AppText.saveNoScreenLock,
      ),
      (
        'the phone busy',
        () => flaky.failNext(const DatabaseBusy('open')),
        AppText.saveBusy,
      ),
    ]) {
      testWidgets('$name: said so, nothing stored, Save again works', (
        tester,
      ) async {
        await open(tester);
        await fillInCopperAfter404(tester, 'MC-2026-LSK-0008');
        prepare();

        await tapVisible(tester, saveButton);
        expect(find.text(sentence), findsOneWidget);
        expect(await savedRows(), isEmpty);

        channel.refuse = null;
        await tapVisible(tester, saveButton);
        expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
        expect(await savedRows(), hasLength(1));
      });
    }
  });

  group('fits small screens and large text', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('$name, text 2.0: the 404 sentence, "Record anyway", the '
          'chips, Save and "Record another purchase" are reachable', (
        tester,
      ) async {
        await open(tester, size: size, textScale: 2.0);
        await fillInCopperAfter404(tester, 'MC-2026-LSK-0008');
        expect(tester.takeException(), isNull);

        await tapVisible(tester, saveButton);
        expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
        await tapVisible(tester, button(AppText.recordAnotherPurchase));
        expect(find.text('fake camera'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
