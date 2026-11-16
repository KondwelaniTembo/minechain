// The app as main() starts it: the checked settings, both themes and the
// router; and the error app for a build with no address. Navigation itself is
// tested in test/core/router/.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/main.dart';

import 'fakes/fake_controllers.dart';

void main() {
  late FakeServerStatus server;

  // The same shape as main(): a fake, reserved address, never the real one.
  Future<void> pumpApp(WidgetTester tester, AuthState state) async {
    final config = switch (AppConfig.check('https://api.example.test')) {
      ConfigOk(:final config) => config,
      ConfigInvalid() => fail('the test address should be valid'),
    };
    server = FakeServerStatus();
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...fakeOverrides(FakeAuthController(state), server: server),
        ],
        child: const MineChainApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('signed out: the login screen, which checks the server', (
    tester,
  ) async {
    await pumpApp(tester, const SignedOut());
    expect(find.text(AppText.logIn), findsOneWidget);
    expect(server.checks, 1);
  });

  testWidgets('follows the phone light/dark setting', (tester) async {
    await pumpApp(tester, const SignedOut());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
  });

  testWidgets('a build without an address shows only the plain message', (
    tester,
  ) async {
    await tester.pumpWidget(const ConfigErrorApp());

    expect(find.text(AppText.missingServerAddress), findsOneWidget);
    expect(find.text(AppText.logIn), findsNothing);
  });
}
