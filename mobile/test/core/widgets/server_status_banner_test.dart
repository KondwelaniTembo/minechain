// The banner in each state, with a stand-in controller that holds a fixed
// state and counts "Try again" taps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/errors/app_failure.dart';
import 'package:minechain/core/network/server_status.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/theme/app_theme.dart';
import 'package:minechain/core/widgets/server_status_banner.dart';

/// Always in [initial]; check() only counts.
class FakeServerStatus extends ServerStatusController {
  FakeServerStatus(this.initial);
  final ServerStatus initial;
  int checks = 0;

  @override
  ServerStatus build() => initial;

  @override
  Future<void> check() async => checks++;
}

late FakeServerStatus fake;

Future<void> pumpBanner(
  WidgetTester tester,
  ServerStatus status, {
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = size * 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: [
        serverStatusControllerProvider.overrideWith(
          () => fake = FakeServerStatus(status),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        // Scrollable, as on a home screen, so very large text can scroll.
        home: const Scaffold(
          body: SingleChildScrollView(child: ServerStatusBanner()),
        ),
      ),
    ),
  );
}

final tryAgain = find.text(AppText.tryAgain);

void main() {
  group('says nothing', () {
    for (final status in const [
      ServerUnknown(),
      ServerChecking(),
      ServerReady(),
    ]) {
      testWidgets(status.runtimeType.toString(), (tester) async {
        await pumpBanner(tester, status);
        expect(find.byType(Text), findsNothing);
        expect(find.byType(Icon), findsNothing);
      });
    }
  });

  testWidgets('waking: the sentence, an icon and progress; no Try again', (
    tester,
  ) async {
    await pumpBanner(tester, const ServerWaking());
    expect(find.text(AppText.serverWaking), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tryAgain, findsNothing);
  });

  testWidgets('not ready: the sentence and Try again', (tester) async {
    await pumpBanner(tester, const ServerNotReady());
    expect(find.text(AppText.serverNotReady), findsOneWidget);
    expect(tryAgain, findsOneWidget);
  });

  testWidgets('failed: the failure\'s sentence, and Try again checks again', (
    tester,
  ) async {
    await pumpBanner(tester, const ServerFailed(NoConnection()));
    expect(find.text(AppText.noConnection), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await tester.tap(tryAgain);
    expect(fake.checks, 1);
  });

  testWidgets('failed, unsafe connection: no Try again', (tester) async {
    await pumpBanner(tester, const ServerFailed(InsecureConnection()));
    expect(find.text(AppText.insecureConnection), findsOneWidget);
    expect(find.byIcon(Icons.gpp_bad), findsOneWidget);
    expect(tryAgain, findsNothing);
  });

  testWidgets('failed, timed out: Try again', (tester) async {
    await pumpBanner(tester, const ServerFailed(TimedOut()));
    expect(find.text(AppText.timedOut), findsOneWidget);
    expect(tryAgain, findsOneWidget);
  });

  group('no overflow at text scale 2.0 on 360 x 640', () {
    for (final status in const [
      ServerWaking(),
      ServerNotReady(),
      ServerFailed(NoConnection()),
      ServerFailed(InsecureConnection()),
      ServerFailed(BadResponse(status: 502)),
    ]) {
      testWidgets(status.toString(), (tester) async {
        await pumpBanner(tester, status, textScale: 2.0);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
