// The app as main() starts it: ProviderScope, both themes, the sample home.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/main.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    const ProviderScope(retry: noRetry, child: MineChainApp()),
  );

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
}
