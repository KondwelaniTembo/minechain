// The resume hook: coming back to the app asks AuthController.checkExpiry(),
// and the hook is really in place around the whole app.
//
// A test cannot press the Home button, so it plays Android's part: it tells
// the binding the lifecycle state changed, one step at a time, as Android
// does (resumed -> inactive -> hidden -> paused, and back).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/main.dart';

import '../../../fakes/fake_controllers.dart';

void main() {
  late FakeAuthController auth;

  Future<void> pumpApp(WidgetTester tester) async {
    final config = (AppConfig.check('https://api.example.test') as ConfigOk)
        .config;
    auth = FakeAuthController(signedInAs(Role.miner));
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...fakeOverrides(auth),
        ],
        child: const MineChainApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  void lifecycle(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.handleAppLifecycleStateChanged(state);

  testWidgets('to the background and back: checkExpiry once', (tester) async {
    await pumpApp(tester);
    expect(auth.expiryChecks, 0);

    // The user presses Home...
    lifecycle(tester, AppLifecycleState.inactive);
    lifecycle(tester, AppLifecycleState.hidden);
    lifecycle(tester, AppLifecycleState.paused);
    expect(auth.expiryChecks, 0); // leaving is not a reason to check

    // ...and comes back later.
    lifecycle(tester, AppLifecycleState.hidden);
    lifecycle(tester, AppLifecycleState.inactive);
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();

    expect(auth.expiryChecks, 1);
  });

  testWidgets('a short interruption (inactive and back) also checks',
      (tester) async {
    await pumpApp(tester);

    // For example the notification shade pulled down and pushed back up.
    lifecycle(tester, AppLifecycleState.inactive);
    expect(auth.expiryChecks, 0);
    lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();

    expect(auth.expiryChecks, 1);
  });
}
