// "Check a consignment", T3: the way in from each home, the scan step, and
// every way a check can end except the result page (T4). The whole app runs
// with the real router, a fake camera and a fake server.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_admin_server.dart' show refusal;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart' show FakeQrScanner;

const _paths = {
  Role.transporter: AppRoutes.transporterCheck,
  Role.buyer: AppRoutes.buyerCheck,
  Role.officer: AppRoutes.officerCheck,
};

late FakeCheckServer server;
late FakeQrScanner camera;

/// The app on [role]'s home, with the fakes in place.
Future<AppHarness> start(
  WidgetTester tester,
  AuthState auth, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) => AppHarness.pump(
  tester,
  FakeAuthController(auth),
  size: size,
  textScale: textScale,
  overrides: [
    ...server.overrides(),
    qrScannerBuilderProvider.overrideWithValue(camera.builder),
  ],
);

/// Opens the screen from the home's "Check a consignment" tile.
Future<void> openCheck(WidgetTester tester) async {
  await tapVisible(tester, find.text(AppText.checkConsignment));
}

void main() {
  setUp(() {
    server = FakeCheckServer();
    camera = FakeQrScanner();
  });

  group('the way in', () {
    _paths.forEach((role, path) {
      testWidgets('${role.name}: the tile opens $path with the camera', (
        tester,
      ) async {
        final app = await start(tester, signedInAs(role));
        await openCheck(tester);

        expect(app.path, path);
        expect(find.text('fake camera'), findsOneWidget);
        expect(find.text(AppText.checkScanHint), findsOneWidget);
        expect(find.text(AppText.comingSoon), findsNothing);
      });

      testWidgets('${role.name}: the back arrow returns to the home', (
        tester,
      ) async {
        final app = await start(tester, signedInAs(role));
        await openCheck(tester);
        await tapVisible(tester, find.byType(BackButton));
        expect(app.path, '/${role.name}');
      });
    });

    // Redirect rule 4: a path under another role's home sends you home.
    for (final role in [Role.miner, Role.admin]) {
      for (final path in _paths.values) {
        testWidgets('${role.name} cannot open $path', (tester) async {
          final app = await start(tester, signedInAs(role));
          app.container.read(appRouterProvider).go(path);
          await tester.pumpAndSettle();
          expect(app.path, '/${role.name}');
          expect(server.requests, isEmpty);
        });
      }
    }

    testWidgets('a transporter cannot open the buyer\'s path', (tester) async {
      final app = await start(tester, signedInAs(Role.transporter));
      app.container.read(appRouterProvider).go(AppRoutes.buyerCheck);
      await tester.pumpAndSettle();
      expect(app.path, AppRoutes.transporter);
    });
  });

  group('scanning', () {
    testWidgets('a code that is not a custody record: said so, nothing sent, '
        'the camera stays', (tester) async {
      await start(tester, signedInAs(Role.officer));
      await openCheck(tester);

      camera.scan('https://myqrcode.mobi/8107b644');
      await tester.pump();

      expect(find.text(AppText.notOurRecord), findsOneWidget);
      expect(find.text('fake camera'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('a custody record: one request while the camera keeps '
        'reading it; then the camera is gone', (tester) async {
      server.hold = Completer<void>();
      await start(tester, signedInAs(Role.transporter));
      await openCheck(tester);

      camera.scan(knownQrCode);
      await tester.pump();
      expect(find.text(AppText.checkingRecord(knownQrCode)), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);

      // The camera reads the same code again before it is taken away.
      camera.scan(knownQrCode);
      await tester.pump();

      server.hold!.complete();
      await tester.pumpAndSettle();

      expect(server.requests, hasLength(1));
      expect(server.lastQrCode, knownQrCode);
      expect(find.text(AppText.checkedRecord(knownQrCode)), findsOneWidget);
      expect(find.text('fake camera'), findsNothing);
    });

    testWidgets('"Scan again" brings the camera back for a new check', (
      tester,
    ) async {
      await start(tester, signedInAs(Role.buyer));
      await openCheck(tester);
      camera.scan(knownQrCode);
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text(AppText.scanAgain));
      expect(find.text('fake camera'), findsOneWidget);
      expect(find.text(AppText.notOurRecord), findsNothing);

      camera.scan(knownQrCode);
      await tester.pumpAndSettle();
      expect(server.requests, hasLength(2));
    });

    testWidgets('camera refused: the reason, "Allow camera" asks again', (
      tester,
    ) async {
      camera.problem = ScannerProblem.permissionDenied;
      await start(tester, signedInAs(Role.officer));
      await openCheck(tester);

      expect(find.text(AppText.cameraNeeded), findsOneWidget);
      expect(find.text(AppText.openSettings), findsOneWidget);
      await tapVisible(tester, find.text(AppText.allowCamera));
      expect(camera.retries, 1);
    });
  });

  group('a check that does not succeed', () {
    testWidgets('404: the server\'s words, no "Try again"', (tester) async {
      await start(tester, signedInAs(Role.buyer));
      await openCheck(tester);

      camera.scan('MC-2026-LSK-9999');
      await tester.pumpAndSettle();

      expect(find.text('No consignment has this QR code.'), findsOneWidget);
      expect(find.text(AppText.tryAgain), findsNothing);
      expect(find.text(AppText.scanAgain), findsOneWidget);
    });

    testWidgets('429: the server\'s words and when to scan again', (
      tester,
    ) async {
      const words =
          'Too many consignment scans. Please wait a few minutes and try '
          'again.';
      server.answer = (_) => http.Response(
        '{"error":{"code":"TOO_MANY_REQUESTS","message":"$words"}}',
        429,
        headers: {'retry-after': '90'},
      );
      await start(tester, signedInAs(Role.transporter));
      await openCheck(tester);

      camera.scan(knownQrCode);
      await tester.pumpAndSettle();

      expect(find.text(words), findsOneWidget);
      expect(find.text(AppText.tooManyTries), findsNothing);
      expect(
        find.text(AppText.tryAgainIn(const Duration(seconds: 90))),
        findsOneWidget,
      );
      expect(AppText.tryAgainIn(const Duration(seconds: 90)), contains('2'));
      expect(find.text(AppText.tryAgain), findsNothing);
    });

    testWidgets('no network: said so; "Try again" checks the same code', (
      tester,
    ) async {
      var offline = true;
      server.answer = (request) {
        if (offline) throw http.ClientException('no network', request.url);
        return FakeCheckServer.knownOnly(request);
      };
      await start(tester, signedInAs(Role.officer));
      await openCheck(tester);

      camera.scan(knownQrCode);
      await tester.pumpAndSettle();
      expect(find.text(AppText.noConnection), findsOneWidget);

      offline = false;
      await tapVisible(tester, find.text(AppText.tryAgain));

      expect(server.requests, hasLength(2));
      expect(server.lastQrCode, knownQrCode);
      expect(find.text(AppText.checkedRecord(knownQrCode)), findsOneWidget);
    });

    testWidgets('a server fault (500) can be tried again', (tester) async {
      server.answer = (_) => refusal(
        500,
        'INTERNAL_ERROR',
        'Something went '
            'wrong',
      );
      await start(tester, signedInAs(Role.officer));
      await openCheck(tester);
      camera.scan(knownQrCode);
      await tester.pumpAndSettle();
      expect(find.text(AppText.tryAgain), findsOneWidget);
    });

    testWidgets('session ended before the scan: the password first, nothing '
        'sent', (tester) async {
      await start(tester, SignedInNeedsPassword(userOf(Role.transporter)));
      await openCheck(tester);

      camera.scan(knownQrCode);
      await tester.pumpAndSettle();

      expect(find.text(AppText.checkNeedsPassword), findsOneWidget);
      expect(find.text(AppText.enterPasswordButton), findsOneWidget);
      expect(server.requests, isEmpty);
    });
  });

  group('fits small screens and large text', () {
    for (final (name, size) in [
      ('portrait', const Size(360, 640)),
      ('landscape', const Size(640, 360)),
    ]) {
      testWidgets('scanning, $name, text 2.0', (tester) async {
        camera.problem = ScannerProblem.permissionDenied;
        await start(
          tester,
          signedInAs(Role.officer),
          size: size,
          textScale: 2.0,
        );
        await openCheck(tester);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(AppText.checkScanHint));
      });

      testWidgets('a failure, $name, text 2.0', (tester) async {
        server.answer = (request) =>
            throw http.ClientException('no network', request.url);
        await start(tester, signedInAs(Role.buyer), size: size, textScale: 2.0);
        await openCheck(tester);
        camera.scan(knownQrCode);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text(AppText.scanAgain));
        expect(find.text('fake camera'), findsOneWidget);
      });
    }
  });
}
