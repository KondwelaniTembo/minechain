// The registration screen inside the real app and router, with a fake
// camera, a fake GPS, a fake save, and the real repository and settings on
// an in-memory database. No plugin loads.
//
// pumpAndSettle is avoided while the GPS is searching: its progress bar
// moves for ever, so settling would never finish. [frames] draws a few
// frames instead.

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
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/registration/data/location_source.dart';
import 'package:minechain/features/registration/data/register_consignment.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';
import 'package:minechain/features/registration/presentation/registration_controller.dart';
import 'package:minechain/features/steps/data/local_steps_repository.dart';
import 'package:minechain/features/steps/domain/local_step.dart';
import 'package:minechain/features/sync/data/sync_service.dart';
import 'package:minechain/features/sync/domain/sync_report.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart';

const fingerprint =
    '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53';
const goodCode = 'MC-2026-LSK-0001';

late FakeLocationSource gps;
late FakeQrScanner camera;
late FakeRegisterConsignment saver;
late InMemoryLocalDatabase database;
late LocalStepsRepository steps;
late LocalSettings settings;
late DateTime now;
late AppHarness app;

/// Starts the app as a miner and opens the screen from the home tile.
Future<void> open(
  WidgetTester tester, {
  DeviceKeyState key = const DeviceKeyReady(fingerprint),
  Future<LocalStepsRepository> Function()? stepsSource,
  Role role = Role.miner,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  app = await AppHarness.pump(
    tester,
    FakeAuthController(signedInAs(role)),
    size: size,
    textScale: textScale,
    overrides: [
      locationSourceProvider.overrideWithValue(gps),
      qrScannerBuilderProvider.overrideWithValue(camera.builder),
      registerConsignmentProvider.overrideWithValue(saver),
      localStepsRepositoryProvider.overrideWith(
        (ref) => stepsSource?.call() ?? Future.value(steps),
      ),
      localSettingsProvider.overrideWith((ref) async => settings),
      deviceKeyControllerProvider.overrideWith(
        () => StaticDeviceKeyController(key),
      ),
      clockProvider.overrideWithValue(() => now),
    ],
  );
  if (role == Role.miner) {
    // At text scale 2.0 the device key notice pushes the tile below the
    // fold; a tap there would miss (misses are fatal here).
    final tile = find.text(AppText.registerConsignment);
    await scrollTo(
      tester,
      tile,
      scrollable: find.byType(Scrollable).first,
      settle: false,
    );
    await tester.tap(tile);
    await frames(tester);
  }
}

/// A few frames: the route change, the page transition, then one more.
///
/// The last pump matters. Work that finishes after a frame (the controller's
/// start, the location answer, the remembered mineral) changes the state
/// after that frame was drawn; without another frame the screen still shows
/// the state from before, such as "Starting the location…".
Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Scrolls [finder] into view (the form is one non-lazy scroll view), then
/// taps it.
Future<void> tapIt(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await frames(tester);
}

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);

Finder get saveButton => button(AppText.save);
Finder get weightField => find.byType(TextField);
Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

bool enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> typeWeight(WidgetTester tester, String text) async {
  await tester.ensureVisible(weightField);
  await tester.pump();
  await tester.enterText(weightField, text);
  await frames(tester);
}

/// Leaves the weight field with the keyboard's Done key, which shows any
/// problem with what was typed.
Future<void> leaveWeight(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await frames(tester);
}

Future<void> scan(WidgetTester tester, String code) async {
  camera.scan(code);
  await frames(tester);
}

Future<void> fix(WidgetTester tester, {double accuracyM = 6}) async {
  gps.emit(reading(now, accuracyM: accuracyM));
  await frames(tester);
}

/// Everything Save needs: a code, a fix, gold, 1.5 g.
Future<void> fillIn(WidgetTester tester) async {
  await scan(tester, goodCode);
  await fix(tester);
  await tapIt(tester, chip(AppText.gold));
  await typeWeight(tester, '1.5');
}

Future<void> registerElsewhere(String qrCode, {required String actor}) =>
    steps.insert(
      NewLocalStep(
        stepId: '6f1d2c3a-0000-4000-8000-000000000777',
        actorId: actor,
        type: 'registration',
        qrCode: qrCode,
        mineral: 'gold',
        weightMg: '1000',
        latitude: '0.000000',
        longitude: '0.000000',
        capturedAt: '2026-11-17T08:00:00.000Z',
        payload: 'minechain-step/1/registration\n',
        signature: 'MEQCIF==',
        keyFingerprint: fingerprint,
        gpsAccuracyM: 5,
        createdAt: DateTime.utc(2026, 11, 17, 8),
      ),
    );

void main() {
  setUp(() {
    gps = FakeLocationSource();
    camera = FakeQrScanner();
    saver = FakeRegisterConsignment();
    database = InMemoryLocalDatabase();
    steps = LocalStepsRepository(database);
    settings = LocalSettings(database);
    now = DateTime.utc(2026, 11, 17, 10);
  });
  tearDown(() => database.close());

  group('opening', () {
    testWidgets('the home tile opens /miner/register', (tester) async {
      await open(tester);
      expect(app.path, AppRoutes.minerRegister);
      expect(find.text(AppText.scanStep), findsOneWidget);
      expect(find.text('fake camera'), findsOneWidget);
    });

    testWidgets('the GPS starts on open and stops on leaving', (tester) async {
      await open(tester);
      expect(gps.accessChecks, 1);
      expect(gps.listening, isTrue);

      await tester.tap(find.byType(BackButton));
      await frames(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(app.path, AppRoutes.miner);
      expect(gps.listening, isFalse);
    });

    testWidgets('another role cannot open it', (tester) async {
      await open(tester, role: Role.transporter);
      app.container.read(appRouterProvider).go(AppRoutes.minerRegister);
      await frames(tester);
      expect(app.path, AppRoutes.transporter);
      expect(gps.accessChecks, 0);
    });
  });

  group('gates', () {
    testWidgets('the database cannot be opened', (tester) async {
      await open(
        tester,
        stepsSource: () async => throw const DatabaseWrongKey(),
      );
      expect(find.text(AppText.savedWorkProblem), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);
      expect(gps.accessChecks, 0);
    });

    testWidgets('not the registered phone', (tester) async {
      await open(tester, key: const DeviceKeyOtherDevice());
      expect(find.text(AppText.deviceKeyOtherDevice), findsOneWidget);
      expect(saveButton, findsNothing);
    });

    testWidgets('the key failed', (tester) async {
      await open(tester, key: const DeviceKeyFailed(AppText.deviceKeyProblem));
      expect(find.text(AppText.deviceKeyProblem), findsOneWidget);
    });

    testWidgets('the key is still being checked', (tester) async {
      await open(tester, key: const DeviceKeyChecking());
      expect(find.text(AppText.checkingDeviceKey), findsOneWidget);
    });

    testWidgets('a key not registered yet still allows registering', (
      tester,
    ) async {
      await open(tester, key: const DeviceKeyUnregistered(fingerprint));
      expect(saveButton, findsOneWidget);
    });
  });

  group('Save is enabled only with all four', () {
    testWidgets('step by step', (tester) async {
      await open(tester);
      expect(enabled(tester, saveButton), isFalse);

      await scan(tester, goodCode);
      expect(enabled(tester, saveButton), isFalse);

      await fix(tester);
      expect(enabled(tester, saveButton), isFalse);

      await tapIt(tester, chip(AppText.gold));
      expect(enabled(tester, saveButton), isFalse);

      await typeWeight(tester, '1.5');
      expect(enabled(tester, saveButton), isTrue);
    });

    testWidgets('an invalid weight disables it again', (tester) async {
      await open(tester);
      await fillIn(tester);
      await typeWeight(tester, '0');
      expect(enabled(tester, saveButton), isFalse);
      await leaveWeight(tester);
      expect(find.text(AppText.weightZero), findsOneWidget);
    });

    testWidgets('a fix that is not accurate enough is not enough', (
      tester,
    ) async {
      await open(tester);
      await scan(tester, goodCode);
      await fix(tester, accuracyM: 40);
      await tapIt(tester, chip(AppText.gold));
      await typeWeight(tester, '1.5');
      expect(enabled(tester, saveButton), isFalse);
    });
  });

  group('scanning', () {
    // The first two were picked up by the A57's camera by themselves. All
    // of them pass the server's wide QR grammar except the last.
    for (final code in [
      'http://scn.by/7d1k2',
      'https://myqrcode.mobi/8107b644',
      'mc-2026-lsk-0001',
      'MC-DEMO-000001',
      'https://shop.example/item?id=7',
    ]) {
      testWidgets('"$code": refused, the camera keeps scanning', (
        tester,
      ) async {
        await open(tester);
        await scan(tester, code);
        expect(find.text(AppText.notOurRecord), findsOneWidget);
        expect(find.text('fake camera'), findsOneWidget);
        expect(find.text(AppText.scannedRecord(code)), findsNothing);

        await scan(tester, goodCode);
        expect(find.text(AppText.scannedRecord(goodCode)), findsOneWidget);
        expect(find.text(AppText.notOurRecord), findsNothing);
      });
    }

    testWidgets('a good code is shown exactly, with "Scan another"', (
      tester,
    ) async {
      await open(tester);
      await scan(tester, goodCode);
      expect(find.text(AppText.scannedRecord(goodCode)), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);

      await tapIt(tester, button(AppText.scanAnother));
      expect(find.text('fake camera'), findsOneWidget);
    });

    testWidgets('already registered on this phone by another account', (
      tester,
    ) async {
      await registerElsewhere(
        goodCode,
        actor: '3f2b6c1e-0000-4000-8000-000000000099',
      );
      await open(tester);
      await scan(tester, goodCode);

      expect(
        find.text(
          AppText.alreadyRegistered(DateTime.utc(2026, 11, 17, 8).toLocal()),
        ),
        findsOneWidget,
      );
      expect(find.text(AppText.scannedRecord(goodCode)), findsNothing);
    });

    testWidgets('registered meanwhile: checked again at Save', (tester) async {
      await open(tester);
      await fillIn(tester);
      await registerElsewhere(
        goodCode,
        actor: '3f2b6c1e-0000-4000-8000-000000000099',
      );

      await tapIt(tester, saveButton);

      expect(saver.calls, isEmpty);
      expect(find.textContaining('already registered'), findsOneWidget);
    });

    testWidgets('camera refused: Allow camera and Open settings', (
      tester,
    ) async {
      camera.problem = ScannerProblem.permissionDenied;
      await open(tester);
      expect(find.text(AppText.cameraNeeded), findsOneWidget);

      await tapIt(tester, button(AppText.allowCamera));
      expect(camera.retries, 1);

      await tapIt(tester, button(AppText.openSettings));
      expect(gps.appSettingsOpened, 1);
    });

    testWidgets('no camera', (tester) async {
      camera.problem = ScannerProblem.noCamera;
      await open(tester);
      expect(find.text(AppText.noCamera), findsOneWidget);
    });
  });

  group('location', () {
    testWidgets('accuracy shown as it improves, then found', (tester) async {
      await open(tester);
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);

      await fix(tester, accuracyM: 40);
      expect(find.text(AppText.findingLocation(40)), findsOneWidget);

      await fix(tester, accuracyM: 6);
      expect(find.text(AppText.locationFound(6)), findsOneWidget);
    });

    testWidgets('after a minute without a fix: still looking', (tester) async {
      await open(tester);
      now = now.add(const Duration(seconds: 61));
      await fix(tester, accuracyM: 80);
      expect(find.textContaining(AppText.stillLooking), findsOneWidget);
    });

    testWidgets('a fake location is named, not used', (tester) async {
      await open(tester);
      gps.emit(reading(now, mocked: true));
      await frames(tester);
      expect(find.text(AppText.fakeLocation), findsOneWidget);
    });

    testWidgets('location off: Turn on Location opens the settings', (
      tester,
    ) async {
      gps.access = LocationAccess.serviceOff;
      await open(tester);
      expect(find.text(AppText.locationOff), findsOneWidget);
      await tapIt(tester, button(AppText.turnOnLocation));
      expect(gps.locationSettingsOpened, 1);
    });

    testWidgets('refused once: Allow location asks again', (tester) async {
      gps.access = LocationAccess.deniedOnce;
      await open(tester);
      expect(find.text(AppText.locationNeeded), findsOneWidget);

      gps.access = LocationAccess.granted;
      await tapIt(tester, button(AppText.allowLocation));

      expect(gps.accessChecks, 2);
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
    });

    testWidgets('refused for good: Open settings', (tester) async {
      gps.access = LocationAccess.deniedForever;
      await open(tester);
      expect(find.text(AppText.locationRefused), findsOneWidget);
      await tapIt(tester, button(AppText.openSettings));
      expect(gps.appSettingsOpened, 1);
    });

    testWidgets('approximate only', (tester) async {
      gps.access = LocationAccess.approximateOnly;
      await open(tester);
      expect(find.text(AppText.locationApproximate), findsOneWidget);
    });

    testWidgets('back from the settings page: tried again by itself', (
      tester,
    ) async {
      gps.access = LocationAccess.serviceOff;
      await open(tester);
      gps.access = LocationAccess.granted;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);

      expect(gps.accessChecks, 2);
      // Only looked: coming back must never open a dialog by itself.
      expect(gps.asks, [true, false]);
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
    });

    testWidgets('refused once, then the app resumes: not asked again', (
      tester,
    ) async {
      gps.access = LocationAccess.deniedOnce;
      await open(tester);

      // Closing the dialog itself resumes the app.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);

      expect(gps.asks, [true, false]);
      expect(find.text(AppText.locationNeeded), findsOneWidget);
    });

    testWidgets('the camera waits until the location question is answered', (
      tester,
    ) async {
      final dialog = Completer<LocationAccess>();
      gps.pending = dialog;
      await open(tester);

      expect(find.text(AppText.startingLocation), findsOneWidget);
      expect(find.text(AppText.cameraWaiting), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);

      dialog.complete(LocationAccess.granted);
      await frames(tester);

      expect(find.text('fake camera'), findsOneWidget);
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
    });

    testWidgets('the location check throws: could not be read, Try again', (
      tester,
    ) async {
      gps.accessError = Exception('plugin fault');
      await open(tester);

      expect(find.text(AppText.locationFailed), findsOneWidget);
      // Settled, even if badly: the camera may start.
      expect(find.text('fake camera'), findsOneWidget);

      gps.accessError = null;
      await tapIt(tester, button(AppText.tryAgain));

      expect(gps.accessChecks, 2);
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
    });

    testWidgets('the readings cannot start: could not be read', (tester) async {
      gps.readingsError = Exception('plugin fault');
      await open(tester);
      expect(find.text(AppText.locationFailed), findsOneWidget);
      expect(button(AppText.tryAgain), findsOneWidget);
    });

    testWidgets('no answer in time: could not be read, Try again', (
      tester,
    ) async {
      gps.pending = Completer<LocationAccess>(); // never answers
      await open(tester);
      expect(find.text(AppText.startingLocation), findsOneWidget);

      await tester.pump(locationStartTimeout);
      await frames(tester);

      expect(find.text(AppText.locationFailed), findsOneWidget);
      expect(find.text('fake camera'), findsOneWidget);

      gps.pending = null;
      await tapIt(tester, button(AppText.tryAgain));
      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
    });

    testWidgets('an answer after the timeout still counts', (tester) async {
      final dialog = Completer<LocationAccess>();
      gps.pending = dialog;
      await open(tester);
      await tester.pump(locationStartTimeout);
      await frames(tester);
      expect(find.text(AppText.locationFailed), findsOneWidget);

      dialog.complete(LocationAccess.granted);
      await frames(tester);

      expect(find.text(AppText.findingLocation(null)), findsOneWidget);
      expect(gps.listening, isTrue);
    });

    testWidgets('location switched off while searching', (tester) async {
      await open(tester);
      gps.fail(LocationStreamProblem.serviceOff);
      await frames(tester);
      expect(find.text(AppText.locationOff), findsOneWidget);
    });
  });

  group('mineral and weight', () {
    testWidgets('the last mineral is preselected, with its unit', (
      tester,
    ) async {
      await settings.write(SettingKeys.lastMineral, 'copper');
      await open(tester);

      expect(tester.widget<ChoiceChip>(chip(AppText.copper)).selected, isTrue);
      expect(find.text(AppText.weightInKilograms), findsOneWidget);
    });

    testWidgets('no mineral yet: the weight asks for it', (tester) async {
      await open(tester);
      await typeWeight(tester, '1.5');
      expect(find.text(AppText.chooseMineralFirst), findsOneWidget);
    });

    for (final (typed, sentence) in [
      ('1.2345', AppText.weightTooManyDecimals(3)),
      ('-1', AppText.weightNegative),
      ('abc', AppText.weightNotANumber),
      ('99999999999999999999', AppText.weightTooLarge),
    ]) {
      testWidgets('gold "$typed": $sentence', (tester) async {
        await open(tester);
        await tapIt(tester, chip(AppText.gold));
        await typeWeight(tester, typed);
        await leaveWeight(tester);
        expect(find.text(sentence), findsOneWidget);
      });
    }

    testWidgets('no format error while typing "12."; shown on leaving, '
        'cleared on edit', (tester) async {
      await open(tester);
      await tapIt(tester, chip(AppText.gold));

      // On the way to "12.5": not a mistake yet (found on the A57).
      await typeWeight(tester, '12.');
      expect(find.text(AppText.weightNotANumber), findsNothing);

      // Leaving the field shows it.
      await leaveWeight(tester);
      expect(find.text(AppText.weightNotANumber), findsOneWidget);

      // Editing clears it at once, even before the number is right.
      await typeWeight(tester, '12.x');
      expect(find.text(AppText.weightNotANumber), findsNothing);

      await typeWeight(tester, '12.5');
      await leaveWeight(tester);
      expect(find.text(AppText.weightNotANumber), findsNothing);
    });

    testWidgets('a tap on the greyed-out Save shows the weight problem', (
      tester,
    ) async {
      await open(tester);
      await scan(tester, goodCode);
      await fix(tester);
      await tapIt(tester, chip(AppText.gold));
      await typeWeight(tester, '12.');
      expect(enabled(tester, saveButton), isFalse);
      expect(find.text(AppText.weightNotANumber), findsNothing);

      await tapIt(tester, saveButton);

      expect(find.text(AppText.weightNotANumber), findsOneWidget);
      expect(saver.calls, isEmpty);
    });
  });

  group('saving', () {
    testWidgets('the values go to the save, the weight in milligrams', (
      tester,
    ) async {
      await open(tester);
      await scan(tester, goodCode);
      await fix(tester);
      await tapIt(tester, chip(AppText.copper));
      await typeWeight(tester, '1.5');

      await tapIt(tester, saveButton);

      expect(saver.calls.single['qrCode'], goodCode);
      expect(saver.calls.single['mineral'], Mineral.copper);
      expect(saver.calls.single['weightMg'], '1500000'); // 1.5 kg
      expect(saver.calls.single['latitude'], -15.4190123);
    });

    testWidgets('saved: the sentence, and the mineral is remembered', (
      tester,
    ) async {
      await open(tester);
      await fillIn(tester);

      await tapIt(tester, saveButton);

      // Tests run in debug mode, so the duration follows the sentence.
      expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
      expect(find.textContaining(' s)'), findsOneWidget);
      expect(saver.calls.single['weightMg'], '1500'); // 1.5 g
      expect(await settings.read(SettingKeys.lastMineral), 'gold');
      // A send was started at once (M6). Here the fake session's token has
      // run out by this test's clock, so it stops before sending anything.
      expect(
        app.container.read(syncServiceProvider).last?.stop,
        SyncStop.needsPassword,
      );
    });

    testWidgets('Register another: a fresh form, the mineral kept', (
      tester,
    ) async {
      await open(tester);
      await fillIn(tester);
      await tapIt(tester, saveButton);

      await tapIt(tester, button(AppText.registerAnother));

      expect(find.text('fake camera'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(chip(AppText.gold)).selected, isTrue);
      expect(tester.widget<TextField>(weightField).controller!.text, isEmpty);
      expect(enabled(tester, saveButton), isFalse);
    });

    testWidgets('while saving: Saving…, and Save cannot be tapped again', (
      tester,
    ) async {
      saver.hold = Completer<void>();
      await open(tester);
      await fillIn(tester);

      await tapIt(tester, saveButton);

      expect(find.text(AppText.saving), findsOneWidget);
      expect(enabled(tester, button(AppText.saving)), isFalse);

      saver.hold!.complete();
      await frames(tester);
      expect(saver.calls, hasLength(1));
    });

    for (final (name, result, sentence) in <(String, SaveResult, String)>[
      ('signing failed', const SaveSigningFailed(), AppText.saveSigningFailed),
      ('key not usable', const SaveKeyNotUsable(), AppText.saveKeyNotUsable),
      ('storage failed', const SaveStorageFailed(), AppText.savedWorkProblem),
      ('invalid field', const SaveInvalidField('qr_code'), AppText.saveInvalid),
      ('duplicate step id', const SaveDuplicateStepId(), AppText.saveFailed),
      // Mobile (26): calm, and never the "cannot be opened" sentence.
      ('the phone busy', const SaveBusy(), AppText.saveBusy),
    ]) {
      testWidgets('$name: its sentence, the form kept', (tester) async {
        saver.answer = result;
        await open(tester);
        await fillIn(tester);

        await tapIt(tester, saveButton);

        expect(find.text(sentence), findsOneWidget);
        expect(find.text(AppText.scannedRecord(goodCode)), findsOneWidget);
        if (result is SaveBusy) {
          expect(find.text(AppText.savedWorkProblem), findsNothing);
        }
      });
    }
  });

  group('fits small screens and large text', () {
    for (final (name, size, scale) in [
      ('portrait 360x640', const Size(360, 640), 1.0),
      ('landscape 640x360', const Size(640, 360), 1.0),
      ('portrait, text 2.0', const Size(360, 640), 2.0),
      ('landscape, text 2.0', const Size(640, 360), 2.0),
    ]) {
      testWidgets('the form with problems shown: $name', (tester) async {
        await open(tester, size: size, textScale: scale);
        await scan(tester, 'not ours!');
        await fix(tester, accuracyM: 40);
        await typeWeight(tester, '1.5');
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(saveButton);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('the camera refused and location off: $name', (tester) async {
        camera.problem = ScannerProblem.permissionDenied;
        gps.access = LocationAccess.serviceOff;
        await open(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(button(AppText.turnOnLocation));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('saved: $name', (tester) async {
        await open(tester, size: size, textScale: scale);
        await fillIn(tester);
        await tapIt(tester, saveButton);
        expect(find.textContaining(AppText.savedOnPhone), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('not the registered phone: $name', (tester) async {
        await open(
          tester,
          key: const DeviceKeyOtherDevice(),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
