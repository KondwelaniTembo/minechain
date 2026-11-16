// The app as main() starts it: ProviderScope with the checked settings, both
// themes, the sample home with its server check; and the error app for a build
// with no address.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/network/server_status.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/main.dart';

/// Stands in for the real controller, so no request is made: it holds
/// [initial] and counts check() calls.
class FakeServerStatus extends ServerStatusController {
  FakeServerStatus(this.initial);
  final ServerStatus initial;
  int checks = 0;

  @override
  ServerStatus build() => initial;

  @override
  Future<void> check() async => checks++;
}

void main() {
  late FakeServerStatus fake;

  // The same shape as main(): a fake, reserved address, never the real one.
  Future<void> pumpApp(
    WidgetTester tester, {
    ServerStatus status = const ServerUnknown(),
  }) {
    final config = switch (AppConfig.check('https://api.example.test')) {
      ConfigOk(:final config) => config,
      ConfigInvalid() => fail('the test address should be valid'),
    };
    return tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          appConfigProvider.overrideWithValue(config),
          serverStatusControllerProvider.overrideWith(
            () => fake = FakeServerStatus(status),
          ),
        ],
        child: const MineChainApp(),
      ),
    );
  }

  testWidgets('checks the server once when the home first appears', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pump(); // a later frame must not check again
    expect(fake.checks, 1);
  });

  testWidgets('shows the waking banner above the tiles', (tester) async {
    await pumpApp(tester, status: const ServerWaking());
    expect(find.text(AppText.serverWaking), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(AppText.serverWaking)).dy,
      lessThan(tester.getTopLeft(find.text(AppText.registerConsignment)).dy),
    );
  });

  testWidgets('shows the sample miner home', (tester) async {
    await pumpApp(tester);

    // "MineChain" is the app bar title; MaterialApp's own title is not drawn.
    expect(find.text(AppText.appTitle), findsOneWidget);
    expect(find.text(AppText.registerConsignment), findsOneWidget);
    expect(find.text(AppText.myConsignments), findsOneWidget);
    expect(find.text(AppText.sendMyWork), findsOneWidget);
  });

  testWidgets('follows the phone light/dark setting', (tester) async {
    await pumpApp(tester);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
  });

  testWidgets('a tile shows "Coming soon"', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text(AppText.myConsignments));
    await tester.pump(); // start the snack bar
    await tester.pump(const Duration(milliseconds: 750)); // let it slide in

    expect(find.text(AppText.comingSoon), findsOneWidget);
  });

  testWidgets('a build without an address shows only the plain message', (
    tester,
  ) async {
    await tester.pumpWidget(const ConfigErrorApp());

    expect(find.text(AppText.missingServerAddress), findsOneWidget);
    expect(find.text(AppText.registerConsignment), findsNothing);
  });
}
