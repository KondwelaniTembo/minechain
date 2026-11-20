// "Take custody", T3: the way in, the scan with the custody record rule,
// Q4's refusal, the optional check (Q1) and its warnings (Q2), and the
// mineral. The whole app runs with the real router, a fake camera, a fake
// server and the real repository on an in-memory database.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/local_database.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/handoff/presentation/custody_controller.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_admin_server.dart' show json200, refusal;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart'
    show FakeQrScanner, StaticDeviceKeyController;

const fingerprint = '4d61912d42cf';

late FakeCheckServer server;
late FakeQrScanner camera;
late InMemoryLocalDatabase database;
late LocalStepsRepository steps;
late AppHarness app;

final transporter = userOf(Role.transporter);

/// The app on [auth]'s home, with the fakes in place.
Future<void> start(
  WidgetTester tester, {
  AuthState? auth,
  DeviceKeyState key = const DeviceKeyReady(fingerprint),
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
      localStepsRepositoryProvider.overrideWith(
        (ref) => stepsSource?.call() ?? Future.value(steps),
      ),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(key),
      ),
    ],
  );
}

/// Start, then open the screen from the home's tile.
Future<void> open(
  WidgetTester tester, {
  AuthState? auth,
  DeviceKeyState key = const DeviceKeyReady(fingerprint),
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

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
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
    }
  });
}
