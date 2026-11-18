// What the device key state looks like on screen: the "Device key" row on
// My account (signing roles only), and the miner home's notice when this
// phone may not sign. The controller is replaced by one holding a fixed
// state; its logic is tested in device_key_controller_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_controllers.dart';

const fingerprint =
    '4d61912d42cfc3d967e27e9179e01054cf7ef9d333a87b414a5ac153f4c93d53';

/// Holds [initial] and does nothing else: no channel, no network.
class FixedDeviceKeyController extends DeviceKeyController {
  FixedDeviceKeyController(this.initial);
  final DeviceKeyState initial;

  @override
  DeviceKeyState build() => initial;

  @override
  Future<void> check(User user) async {}
}

Future<AppHarness> pumpAs(
  WidgetTester tester,
  Role role,
  DeviceKeyState keyState, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) => AppHarness.pump(
  tester,
  FakeAuthController(signedInAs(role)),
  size: size,
  textScale: textScale,
  overrides: [
    deviceKeyControllerProvider.overrideWith(
      () => FixedDeviceKeyController(keyState),
    ),
  ],
);

Future<void> openAccount(WidgetTester tester) async {
  await tester.tap(find.byTooltip(AppText.myAccount));
  await tester.pumpAndSettle();
}

/// Each state and the sentence the account row shows for it.
final rowCases = <(String, DeviceKeyState, String)>[
  (
    'ready',
    const DeviceKeyReady(fingerprint),
    AppText.deviceKeyRegistered('4d61912d'),
  ),
  (
    'unregistered',
    const DeviceKeyUnregistered(fingerprint),
    AppText.deviceKeyNotRegistered,
  ),
  ('other device', const DeviceKeyOtherDevice(), AppText.deviceKeyOtherDevice),
  (
    'failed',
    const DeviceKeyFailed(AppText.deviceKeyProblem),
    AppText.deviceKeyProblem,
  ),
  ('checking', const DeviceKeyChecking(), AppText.deviceKeyChecking),
];

void main() {
  group('My account: the Device key row', () {
    for (final (name, keyState, sentence) in rowCases) {
      testWidgets('miner, $name', (tester) async {
        final app = await pumpAs(tester, Role.miner, keyState);
        await openAccount(tester);

        expect(app.path, AppRoutes.account);
        await tester.ensureVisible(find.text(AppText.deviceKey));
        await tester.pump();
        expect(find.text(AppText.deviceKey), findsOneWidget);
        expect(find.text(sentence), findsOneWidget);
      });
    }

    testWidgets('registered shows only the first 8 characters', (tester) async {
      await pumpAs(tester, Role.miner, const DeviceKeyReady(fingerprint));
      await openAccount(tester);

      expect(find.textContaining('4d61912d'), findsOneWidget);
      expect(find.textContaining(fingerprint), findsNothing);
    });

    for (final role in [Role.transporter, Role.buyer]) {
      testWidgets('${role.name} has the row too', (tester) async {
        await pumpAs(tester, role, const DeviceKeyReady(fingerprint));
        await openAccount(tester);
        expect(find.text(AppText.deviceKey), findsOneWidget);
      });
    }

    for (final role in [Role.officer, Role.admin]) {
      testWidgets('${role.name}: no row at all', (tester) async {
        await pumpAs(tester, role, const DeviceKeyNotNeeded());
        await openAccount(tester);
        expect(find.text(AppText.deviceKey), findsNothing);
      });
    }
  });

  group('the miner home notice', () {
    for (final (name, keyState, shown) in <(String, DeviceKeyState, String?)>[
      (
        'other device',
        const DeviceKeyOtherDevice(),
        AppText.deviceKeyOtherDevice,
      ),
      (
        'failed',
        const DeviceKeyFailed(AppText.deviceKeyProblem),
        AppText.deviceKeyProblem,
      ),
      ('ready', const DeviceKeyReady(fingerprint), null),
      ('unregistered', const DeviceKeyUnregistered(fingerprint), null),
      ('checking', const DeviceKeyChecking(), null),
    ]) {
      testWidgets(name, (tester) async {
        final app = await pumpAs(tester, Role.miner, keyState);

        expect(app.path, AppRoutes.miner);
        if (shown == null) {
          expect(find.text(AppText.deviceKeyOtherDevice), findsNothing);
          expect(find.text(AppText.deviceKeyProblem), findsNothing);
        } else {
          expect(find.text(shown), findsOneWidget);
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
      testWidgets('account row, other device (the longest): $name', (
        tester,
      ) async {
        await pumpAs(
          tester,
          Role.miner,
          const DeviceKeyOtherDevice(),
          size: size,
          textScale: scale,
        );
        await openAccount(tester);
        // The account screen is a SingleChildScrollView: everything is
        // built, so ensureVisible is enough here.
        await tester.ensureVisible(find.text(AppText.deviceKeyOtherDevice));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('miner home with the notice: $name', (tester) async {
        await pumpAs(
          tester,
          Role.miner,
          const DeviceKeyOtherDevice(),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.registerConsignment));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
