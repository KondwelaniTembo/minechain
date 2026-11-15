// The app as main() starts it: ProviderScope with the checked settings, both
// themes, the sample home; and the error app for a build with no address.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/main.dart';

void main() {
  // The same shape as main(): a fake, reserved address, never the real one.
  Future<void> pumpApp(WidgetTester tester) {
    final config = switch (AppConfig.check('https://api.example.test')) {
      ConfigOk(:final config) => config,
      ConfigInvalid() => fail('the test address should be valid'),
    };
    return tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const MineChainApp(),
      ),
    );
  }

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
