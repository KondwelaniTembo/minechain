// "Take custody". T3: the way in, the scan with the custody record rule,
// Q4's refusal, the optional check (Q1) and its warnings (Q2), and the
// mineral. T4: the GPS (started only after a code is accepted), the
// transporter's own weight, Save, the signed row, and every refusal. The
// whole app runs with the real router, a fake camera, a fake GPS, a fake
// server, a fake Keystore channel that "signs", and the real repository and
// handoff save on an in-memory database.
//
// T4 gave the harness a fake GPS that hands over a fresh fix as soon as it
// is listened to: once a code is accepted the location's progress bar would
// otherwise run, and pumpAndSettle would never return. No T3 assertion
// changed.

import 'dart:async';
import 'dart:typed_data';

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
import '../../../fakes/fake_admin_server.dart' show json200, refusal;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_device_key_channel.dart';
import '../../../fakes/fake_registration.dart'
    show FakeLocationSource, FakeQrScanner, StaticDeviceKeyController, reading;
import '../../../fakes/flaky_database.dart';

/// The GPS. Unless [autoFix] is off, the first reading is a fresh, usable
/// fix, stamped by the real clock (the one the app uses here).
class FixingLocationSource extends FakeLocationSource {
  bool autoFix = true;

  @override
  Stream<GpsReading> readings() async* {
    final later = super.readings();
    if (autoFix) yield reading(systemClock());
    yield* later;
  }
}

/// The Keystore: "signs" by recording the bytes, or refuses as told.
class SigningChannel extends FakeDeviceKeyChannel {
  SigningChannel({super.keys});

  final List<Uint8List> signed = [];
  DeviceKeyError? refuse;

  @override
  Future<Uint8List> sign(String alias, Uint8List bytes) async {
    final error = refuse;
    if (error != null) throw DeviceKeyException(error);
    signed.add(Uint8List.fromList(bytes));
    return Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
  }
}

final transporter = userOf(Role.transporter);
final phoneKey = fakeKey(3);
final fingerprint = keyFingerprint(phoneKey);

late FakeCheckServer server;
late FakeQrScanner camera;
late FixingLocationSource gps;
late SigningChannel channel;
late InMemoryLocalDatabase database;
late FlakyLocalDatabase flaky;
late LocalStepsRepository steps;
late AppHarness app;

/// The app on [auth]'s home, with the fakes in place.
Future<void> start(
  WidgetTester tester, {
  AuthState? auth,
  DeviceKeyState? key,
  Future<LocalStepsRepository> Function()? stepsSource,
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
      qrScannerBuilderProvider.overrideWithValue(camera.builder),
      locationSourceProvider.overrideWithValue(gps),
      deviceKeyChannelProvider.overrideWithValue(channel),
      localStepsRepositoryProvider.overrideWith(
        (ref) => stepsSource?.call() ?? Future.value(steps),
      ),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(key ?? DeviceKeyReady(fingerprint)),
      ),
    ],
  );
}

/// Start, then open the screen from the home's tile.
Future<void> open(
  WidgetTester tester, {
  AuthState? auth,
  DeviceKeyState? key,
  Future<LocalStepsRepository> Function()? stepsSource,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  await start(
    tester,
    auth: auth,
    key: key,
    stepsSource: stepsSource,
    size: size,
    textScale: textScale,
  );
  await tapVisible(tester, find.text(AppText.takeCustody));
}

/// Scans [code] and lets the lookups finish.
Future<void> scan(WidgetTester tester, String code) async {
  camera.scan(code);
  await tester.pumpAndSettle();
}

/// A saved handoff of [qrCode] by [actorId], at 09:30 UTC on 20 Nov.
NewLocalStep savedHandoff({
  required String actorId,
  String qrCode = knownQrCode,
}) => NewLocalStep(
  stepId: '6f1d2c3a-0000-4000-8000-000000000301',
  actorId: actorId,
  type: 'handoff',
  qrCode: qrCode,
  mineral: null,
  mineralHint: 'gold',
  weightMg: '1495000',
  latitude: '-15.418900',
  longitude: '28.288700',
  capturedAt: '2026-11-20T09:30:00.000Z',
  payload: 'minechain-step/1/handoff\n',
  signature: 'MEQCIF==',
  keyFingerprint: fingerprint,
  gpsAccuracyM: 4.0,
  createdAt: DateTime.utc(2026, 11, 20, 9, 30),
);

/// Every answer is [body] (200), whatever the code.
void answerWith(Map<String, Object?> body) =>
    server.answer = (request) => json200(body);

CustodyState custodyState() => app.container.read(custodyControllerProvider);

// ---- T4 helpers --------------------------------------------------------------

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Finder get saveButton => button(AppText.save);
Finder get weightField => find.byType(TextField);

bool enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> typeWeight(WidgetTester tester, String text) async {
  await tester.ensureVisible(weightField);
  await tester.pumpAndSettle();
  await tester.enterText(weightField, text);
  await tester.pumpAndSettle();
}

/// No network: the check could not be made, so the mineral is chosen.
void goOffline() =>
    server.answer = (request) =>
        throw http.ClientException('no network', request.url);

/// The rows this transporter has on the phone.
Future<List<LocalStep>> savedRows() =>
    LocalStepsRepository(database).listForActor(transporter.id);

/// Offline, a copper bag weighed at 1.5 kg, ready to save.
Future<void> fillInCopper(WidgetTester tester) async {
  goOffline();
  await scan(tester, knownQrCode);
  await tapVisible(tester, find.text(AppText.copper));
  await typeWeight(tester, '1.5');
}

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
    gps = FixingLocationSource();
    channel = SigningChannel(keys: {deviceKeyAlias(transporter.id): phoneKey});
    database = InMemoryLocalDatabase();
    flaky = FlakyLocalDatabase(database);
    steps = LocalStepsRepository(flaky);
  });
  tearDown(() => database.close());

  group('the way in', () {
    testWidgets('the tile opens /transporter/custody with the camera', (
      tester,
    ) async {
      await open(tester);

      expect(app.path, AppRoutes.transporterCustody);
      expect(find.text('fake camera'), findsOneWidget);
      expect(find.text(AppText.checkScanHint), findsOneWidget);
      expect(find.text(AppText.comingSoon), findsNothing);
    });

    testWidgets('the back arrow returns to the home', (tester) async {
      await open(tester);
      await tapVisible(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);
    });

    // Redirect rule 4: a path under another role's home sends you home.
    for (final role in [Role.miner, Role.buyer, Role.officer, Role.admin]) {
      testWidgets('${role.name} cannot open it', (tester) async {
        await start(tester, auth: signedInAs(role));
        app.container.read(appRouterProvider).go(AppRoutes.transporterCustody);
        await tester.pumpAndSettle();
        expect(app.path, '/${role.name}');
        expect(find.text('fake camera'), findsNothing);
      });
    }
  });

  group('the gates', () {
    testWidgets('saved work that cannot be opened: said so, no camera', (
      tester,
    ) async {
      await open(
        tester,
        stepsSource: () async => throw const DatabaseWrongKey(),
      );
      expect(find.text(AppText.savedWorkProblem), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);
      await tapVisible(tester, find.text(AppText.backToHome));
      expect(app.path, AppRoutes.transporter);
    });

    testWidgets('a phone that may not sign: said so, no camera', (
      tester,
    ) async {
      await open(tester, key: const DeviceKeyOtherDevice());
      expect(find.text(AppText.deviceKeyOtherDevice), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);
    });
  });

  group('scanning', () {
    testWidgets('not a custody record: said so, nothing sent, the camera '
        'stays', (tester) async {
      await open(tester);
      await scan(tester, 'https://myqrcode.mobi/8107b644');

      expect(find.text(AppText.notOurRecord), findsOneWidget);
      expect(find.text('fake camera'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('a custody record: one request while the camera keeps '
        'reading it; the server\'s mineral is shown, not chosen', (
      tester,
    ) async {
      server.hold = Completer<void>();
      await open(tester);

      camera.scan(knownQrCode);
      await tester.pump();
      await tester.pump();
      expect(find.text(AppText.custodyChecking(knownQrCode)), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);

      camera.scan(knownQrCode); // read again before the camera went
      await tester.pump();
      server.hold!.complete();
      await tester.pumpAndSettle();

      expect(server.requests, hasLength(1));
      expect(server.lastQrCode, knownQrCode);
      expect(find.text(AppText.scannedRecord(knownQrCode)), findsOneWidget);
      expect(find.text(AppText.mineralLine(AppText.gold)), findsOneWidget);
      expect(
        find.text(AppText.stageLine(AppText.stageInTransit)),
        findsOneWidget,
      );
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text(AppText.recordAnyway), findsNothing);
      final state = custodyState() as CustodyReady;
      expect(state.mineral, Mineral.gold);
      expect(state.mayContinue, isTrue);
    });

    testWidgets('the blind view: no weight is shown, even if the answer '
        'held one', (tester) async {
      // The fake answers with the officer's full steps, weights included.
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.textContaining('1500000'), findsNothing);
      expect(find.textContaining('1.5'), findsNothing);
      expect(find.textContaining(' kg'), findsNothing);
    });

    testWidgets('"Scan another record": the camera again, and a new code is '
        'asked about', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);
      await tapVisible(tester, find.text(AppText.scanAnother));

      expect(find.text('fake camera'), findsOneWidget);
      await scan(tester, 'MC-2026-LSK-0002');
      expect(server.requests, hasLength(2));
      expect(server.lastQrCode, 'MC-2026-LSK-0002');
    });
  });

  group('Q4: one handoff of a bag per account on this phone', () {
    testWidgets('already taken by this account: when, nothing sent, the '
        'camera stays', (tester) async {
      await steps.insert(savedHandoff(actorId: transporter.id));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(
        find.text(
          AppText.alreadyTookCustody(
            DateTime.utc(2026, 11, 20, 9, 30).toLocal(),
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('fake camera'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('taken by another account on this phone: allowed', (
      tester,
    ) async {
      await steps.insert(
        savedHandoff(actorId: '3f2b6c1e-0000-4000-8000-000000000999'),
      );
      await open(tester);
      await scan(tester, knownQrCode);

      expect(server.requests, hasLength(1));
      expect(custodyState(), isA<CustodyReady>());
    });

    testWidgets('a different bag: allowed', (tester) async {
      await steps.insert(
        savedHandoff(actorId: transporter.id, qrCode: 'MC-2026-LSK-0009'),
      );
      await open(tester);
      await scan(tester, knownQrCode);
      expect(custodyState(), isA<CustodyReady>());
    });
  });

  group('could not be checked: never a dead end (Q1)', () {
    for (final (name, answer, sentence) in <(String, CheckAnswer, String)>[
      (
        'offline',
        (request) => throw http.ClientException('no network', request.url),
        AppText.custodyOffline,
      ),
      (
        'a server error',
        (request) => refusal(500, 'INTERNAL', 'Something went wrong.'),
        AppText.custodyCheckFailed,
      ),
      (
        'too many scans',
        (request) => refusal(429, 'TOO_MANY_REQUESTS', 'Too many scans.'),
        AppText.custodyCheckFailed,
      ),
      (
        'an unreadable answer',
        (request) => json200({'consignment': 'nonsense'}),
        AppText.custodyCheckFailed,
      ),
    ]) {
      testWidgets('$name: said so, then the mineral is chosen', (tester) async {
        server.answer = answer;
        await open(tester);
        await scan(tester, knownQrCode);

        expect(find.text(sentence), findsOneWidget);
        expect(find.text(AppText.chooseMineralFromRecord), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNWidgets(Mineral.values.length));
        expect((custodyState() as CustodyReady).mayContinue, isFalse);

        await tapVisible(tester, find.text(AppText.copper));
        final state = custodyState() as CustodyReady;
        expect(state.mineral, Mineral.copper);
        expect(state.mayContinue, isTrue);
        expect(
          tester
              .widget<ChoiceChip>(
                find.ancestor(
                  of: find.text(AppText.copper),
                  matching: find.byType(ChoiceChip),
                ),
              )
              .selected,
          isTrue,
        );
      });
    }

    testWidgets('the session has ended: nothing sent, said so, the mineral '
        'is chosen', (tester) async {
      await open(tester, auth: SignedInNeedsPassword(transporter));
      await scan(tester, knownQrCode);

      expect(server.requests, isEmpty);
      expect(find.text(AppText.custodyCheckNeedsPassword), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(Mineral.values.length));
    });

    testWidgets('not on the server yet (404): a note, the mineral chosen, no '
        '"Record anyway"', (tester) async {
      await open(tester);
      await scan(tester, 'MC-2026-LSK-0002'); // the fake knows only one code

      expect(find.text(AppText.custodyNotOnServer), findsOneWidget);
      expect(find.text(AppText.recordAnyway), findsNothing);
      expect(find.byType(ChoiceChip), findsNWidgets(Mineral.values.length));
    });

    testWidgets('a chip after a check that knew the mineral changes nothing', (
      tester,
    ) async {
      await open(tester);
      await scan(tester, knownQrCode);
      app.container
          .read(custodyControllerProvider.notifier)
          .chooseMineral(Mineral.copper);
      expect((custodyState() as CustodyReady).mineral, Mineral.gold);
    });
  });

  group('warnings (Q2: warn and allow)', () {
    testWidgets('held: "Under review", then one "Record anyway" tap', (
      tester,
    ) async {
      answerWith(consignmentAnswerJson(held: true));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.custodyUnderReview), findsOneWidget);
      expect(find.text(AppText.custodyMismatch), findsNothing);
      expect((custodyState() as CustodyReady).mayContinue, isFalse);

      await tapVisible(tester, find.text(AppText.recordAnyway));

      expect(find.text(AppText.recordAnyway), findsNothing);
      expect(find.text(AppText.recordingAnyway), findsOneWidget);
      expect((custodyState() as CustodyReady).mayContinue, isTrue);
    });

    testWidgets('a mismatch: its own warning only, and "Record anyway"', (
      tester,
    ) async {
      answerWith(
        consignmentAnswerJson(
          held: true,
          steps: [checkedStepJson(check: 'mismatch')],
        ),
      );
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.custodyMismatch), findsOneWidget);
      expect(find.text(AppText.custodyUnderReview), findsNothing);
      expect(find.text(AppText.recordAnyway), findsOneWidget);
    });

    testWidgets('already bought: a note, no "Record anyway"', (tester) async {
      answerWith(consignmentAnswerJson(stage: 'purchased'));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.custodyAlreadyBought), findsOneWidget);
      expect(find.text(AppText.recordAnyway), findsNothing);
      expect((custodyState() as CustodyReady).mayContinue, isTrue);
    });

    testWidgets('held and bought: both said, "Record anyway" once', (
      tester,
    ) async {
      answerWith(consignmentAnswerJson(held: true, stage: 'purchased'));
      await open(tester);
      await scan(tester, knownQrCode);

      expect(find.text(AppText.custodyUnderReview), findsOneWidget);
      expect(find.text(AppText.custodyAlreadyBought), findsOneWidget);
      expect(find.text(AppText.recordAnyway), findsOneWidget);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('$name, text 2.0: the warning, "Record anyway" and '
          '"Scan another record" are reachable', (tester) async {
        answerWith(consignmentAnswerJson(held: true, stage: 'purchased'));
        await open(tester, size: size, textScale: 2.0);
        await scan(tester, knownQrCode);
        expect(tester.takeException(), isNull);

        await tapVisible(tester, find.text(AppText.recordAnyway));
        expect(find.text(AppText.recordingAnyway), findsOneWidget);
        await tapVisible(tester, find.text(AppText.scanAnother));
        expect(find.text('fake camera'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name, text 2.0: offline, every mineral chip reachable', (
        tester,
      ) async {
        server.answer = (request) =>
            throw http.ClientException('no network', request.url);
        await open(tester, size: size, textScale: 2.0);
        await scan(tester, knownQrCode);

        await tapVisible(tester, find.text(AppText.manganese));
        expect((custodyState() as CustodyReady).mineral, Mineral.manganese);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name, text 2.0: weigh, Save, then "Take custody of '
          'another" are reachable', (tester) async {
        await open(tester, size: size, textScale: 2.0);
        await fillInCopper(tester);
        await tapVisible(tester, saveButton);

        expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
        expect(await savedRows(), hasLength(1));
        await tapVisible(tester, button(AppText.takeAnotherCustody));
        expect(find.text('fake camera'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('fits small screens and large text: two saved (T5b)', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('$name, text 2.0', (tester) async {
        await open(tester, size: size, textScale: 2.0);
        await fillInCopper(tester);
        await tapVisible(tester, saveButton);
        await tapVisible(tester, button(AppText.takeAnotherCustody));
        await scan(tester, 'MC-2026-LSK-0002');
        await tapVisible(tester, find.text(AppText.copper));
        await typeWeight(tester, '1.5');
        await tapVisible(tester, saveButton);

        expect(find.text(AppText.savedThisVisit(2)), findsOneWidget);
        await tapVisible(tester, button(AppText.backToHome));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('T4: the GPS, one permission request at a time', () {
    testWidgets('not asked while the camera is on; asked once a code is '
        'accepted; kept for the next bag', (tester) async {
      await open(tester);
      expect(gps.accessChecks, 0);

      await scan(tester, 'https://myqrcode.mobi/8107b644');
      expect(gps.accessChecks, 0);

      await scan(tester, knownQrCode);
      expect(gps.accessChecks, 1);
      expect(gps.listening, isTrue);
      expect(find.text(AppText.locationFound(6)), findsOneWidget);

      await tapVisible(tester, find.text(AppText.scanAnother));
      // Not on the fake server: the location shows once the mineral is
      // chosen, already found, without asking again.
      await scan(tester, 'MC-2026-LSK-0002');
      await tapVisible(tester, find.text(AppText.copper));
      expect(gps.accessChecks, 1);
      expect(find.text(AppText.locationFound(6)), findsOneWidget);
    });

    testWidgets('a scan refused by Q4 does not ask', (tester) async {
      await steps.insert(savedHandoff(actorId: transporter.id));
      await open(tester);
      await scan(tester, knownQrCode);
      expect(gps.accessChecks, 0);
    });

    testWidgets('leaving the screen stops it', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);
      expect(gps.listening, isTrue);

      await tapVisible(tester, find.byType(BackButton));
      expect(app.path, AppRoutes.transporter);
      expect(gps.listening, isFalse);
    });

    testWidgets('no fix yet: Save stays off until one arrives', (tester) async {
      gps.autoFix = false;
      await open(tester);
      camera.scan(knownQrCode);
      // Not pumpAndSettle: the location's progress bar is running.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);

      await tester.enterText(weightField, '1.5');
      await tester.pump();
      expect(enabled(tester, saveButton), isFalse);

      gps.emit(reading(systemClock()));
      await tester.pump();
      await tester.pump();
      expect(enabled(tester, saveButton), isTrue);
    });

    testWidgets('location refused: said so; "Allow location" asks again', (
      tester,
    ) async {
      gps.access = LocationAccess.deniedOnce;
      await open(tester);
      await scan(tester, knownQrCode);
      expect(find.text(AppText.locationNeeded), findsOneWidget);

      gps.access = LocationAccess.granted;
      await tapVisible(tester, button(AppText.allowLocation));
      expect(gps.asks, [true, true]);
      expect(find.text(AppText.locationFound(6)), findsOneWidget);
    });
  });

  group('T4: weight and Save', () {
    testWidgets('online, gold from the server: the weight in grams, 1.5 g '
        'signs weight_mg=1500, then a send starts', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);
      expect(find.text(AppText.weightInGrams), findsOneWidget);
      expect(find.text(AppText.handoffWeightHint), findsOneWidget);

      await typeWeight(tester, '1.5');
      await tapVisible(tester, saveButton);

      expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
      final row = (await savedRows()).single;
      expect(row.type, 'handoff');
      expect(row.qrCode, knownQrCode);
      expect(row.payload, contains('\nweight_mg=1500\n'));
      expect(row.payload, isNot(contains('mineral')));
      expect(row.mineralHint, 'gold');
      expect(channel.signed, hasLength(1));
      expect(row.syncState, SyncState.queued);
      // As registration: a send starts at once. The fake session's token
      // has run out by the real clock, so it stops before sending.
      final report = app.container.read(syncServiceProvider).last;
      expect(report?.trigger, SyncTrigger.afterSave);
      expect(report?.stop, SyncStop.needsPassword);
    });

    testWidgets('offline, copper chosen: 1.5 kg signs weight_mg=1500000', (
      tester,
    ) async {
      await open(tester);
      await fillInCopper(tester);
      expect(find.text(AppText.weightInKilograms), findsOneWidget);

      await tapVisible(tester, saveButton);

      expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
      final row = (await savedRows()).single;
      expect(row.payload, contains('\nweight_mg=1500000\n'));
      expect(row.weightMg, '1500000');
      expect(row.mineralHint, 'copper');
      expect(row.mineral, isNull);
    });

    testWidgets('no weight field before the mineral is settled', (
      tester,
    ) async {
      goOffline();
      await open(tester);
      await scan(tester, knownQrCode);
      expect(weightField, findsNothing);
      expect(saveButton, findsNothing);

      await tapVisible(tester, find.text(AppText.gold));
      expect(weightField, findsOneWidget);
    });

    testWidgets('held: no weight field until "Record anyway"', (tester) async {
      answerWith(consignmentAnswerJson(held: true));
      await open(tester);
      await scan(tester, knownQrCode);
      expect(weightField, findsNothing);

      await tapVisible(tester, find.text(AppText.recordAnyway));
      await typeWeight(tester, '1.5');
      await tapVisible(tester, saveButton);
      expect(await savedRows(), hasLength(1));
    });

    testWidgets('a weight that is not a number: Save stays off, and the '
        'reason shows on leaving the field', (tester) async {
      await open(tester);
      await scan(tester, knownQrCode);
      await typeWeight(tester, '1,5kg');
      expect(enabled(tester, saveButton), isFalse);
      expect(find.text(AppText.weightNotANumber), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text(AppText.weightNotANumber), findsOneWidget);
      expect(await savedRows(), isEmpty);
    });

    testWidgets('"Take custody of another": the camera, an empty weight, '
        'and the same bag is refused (Q4)', (tester) async {
      await open(tester);
      await fillInCopper(tester);
      await tapVisible(tester, saveButton);

      await tapVisible(tester, button(AppText.takeAnotherCustody));
      expect(find.text('fake camera'), findsOneWidget);

      await scan(tester, knownQrCode);
      expect(find.textContaining('You recorded taking custody'), findsOne);

      await scan(tester, 'MC-2026-LSK-0002');
      expect(weightField, findsNothing); // the mineral is chosen first
      await tapVisible(tester, find.text(AppText.copper));
      expect(tester.widget<TextField>(weightField).controller!.text, isEmpty);
      expect((custodyState() as CustodyReady).weightText, isEmpty);
    });

    // T5b: the saved screen counts this visit's saves (found in T6).
    testWidgets('"2 saved this time." from the second save; back to zero '
        'after "Back to home"', (tester) async {
      final count = find.textContaining('saved this time');
      Future<void> saveAnother(String code) async {
        await scan(tester, code);
        await tapVisible(tester, find.text(AppText.copper));
        await typeWeight(tester, '1.5');
        await tapVisible(tester, saveButton);
      }

      await open(tester);
      await fillInCopper(tester);
      await tapVisible(tester, saveButton);
      expect(count, findsNothing); // one save: nothing to add

      await tapVisible(tester, button(AppText.takeAnotherCustody));
      await saveAnother('MC-2026-LSK-0002');
      expect(find.text(AppText.savedThisVisit(2)), findsOneWidget);
      expect(await savedRows(), hasLength(2));

      await tapVisible(tester, button(AppText.backToHome));
      expect(app.path, AppRoutes.transporter);
      await tapVisible(tester, find.text(AppText.takeCustody));
      await saveAnother('MC-2026-LSK-0003');
      expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
      expect(count, findsNothing);
    });

    testWidgets('recorded meanwhile by this account: checked again at Save, '
        'nothing signed', (tester) async {
      await open(tester);
      await fillInCopper(tester);
      await steps.insert(savedHandoff(actorId: transporter.id));

      await tapVisible(tester, saveButton);

      expect(find.text('fake camera'), findsOneWidget);
      expect(find.textContaining('You recorded taking custody'), findsOne);
      expect(channel.signed, isEmpty);
      expect(await savedRows(), hasLength(1)); // only the one inserted
    });
  });

  group('T4: refused saves store nothing', () {
    for (final (name, prepare, sentence) in <(String, void Function(), String)>[
      (
        'no screen lock',
        () => channel.refuse = DeviceKeyError.noScreenLock,
        AppText.saveNoScreenLock,
      ),
      (
        'the Keystore did not sign',
        () => channel.refuse = DeviceKeyError.keystoreError,
        AppText.saveSigningFailed,
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
        await fillInCopper(tester);
        prepare();

        await tapVisible(tester, saveButton);

        expect(find.text(sentence), findsOneWidget);
        expect(await savedRows(), isEmpty);
        expect(enabled(tester, saveButton), isTrue);

        channel.refuse = null;
        await tapVisible(tester, saveButton);
        expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
        expect(await savedRows(), hasLength(1));
      });
    }

    testWidgets('the key is not the one approved: said so, nothing signed', (
      tester,
    ) async {
      await open(tester, key: DeviceKeyReady(keyFingerprint(fakeKey(9))));
      await fillInCopper(tester);

      await tapVisible(tester, saveButton);

      expect(find.text(AppText.saveKeyNotUsable), findsOneWidget);
      expect(channel.signed, isEmpty);
      expect(await savedRows(), isEmpty);
    });
  });
}
