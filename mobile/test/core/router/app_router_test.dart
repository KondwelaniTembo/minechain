// The real router, wired to a stand-in auth controller: the redirect really
// moves users to the right screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:minechain/core/config/app_config.dart';
import 'package:minechain/core/config/config_provider.dart';
import 'package:minechain/core/riverpod/no_retry.dart';
import 'package:minechain/core/router/app_router.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/core/widgets/mine_chain_logo.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/main.dart';

import '../../fakes/fake_controllers.dart';

late ProviderContainer container;
late FakeAuthController auth;

Future<void> pumpApp(WidgetTester tester, AuthState state) async {
  final config = (AppConfig.check('https://api.example.test') as ConfigOk)
      .config;
  auth = FakeAuthController(state);
  container = ProviderContainer.test(
    retry: noRetry,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      ...fakeOverrides(auth),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MineChainApp(),
    ),
  );
  await tester.pumpAndSettle();
}

GoRouter get router => container.read(appRouterProvider);
String get path => router.routerDelegate.currentConfiguration.uri.path;

void main() {
  testWidgets('a signed-in admin starting at /start ends on /admin',
      (tester) async {
    await pumpApp(tester, signedInAs(Role.admin));
    expect(path, AppRoutes.admin);
    expect(find.text(AppText.adminTitle), findsOneWidget);
  });

  testWidgets('a signed-in miner opening /admin ends on /miner',
      (tester) async {
    await pumpApp(tester, signedInAs(Role.miner));
    router.go(AppRoutes.admin);
    await tester.pumpAndSettle();
    expect(path, AppRoutes.miner);
    expect(find.text(AppText.minerTitle), findsOneWidget);
    expect(find.text(AppText.adminTitle), findsNothing);
  });

  testWidgets('a sign-in moves from the login screen to the home',
      (tester) async {
    await pumpApp(tester, const SignedOut());
    expect(path, AppRoutes.login);

    auth.setState(signedInAs(Role.buyer));
    await tester.pumpAndSettle();

    expect(path, AppRoutes.buyer);
    expect(find.text(AppText.buyerTitle), findsOneWidget);
  });

  testWidgets('a logout moves from the home to the login screen',
      (tester) async {
    await pumpApp(tester, signedInAs(Role.officer));
    auth.setState(const SignedOut(reason: 'ACCOUNT_SUSPENDED'));
    await tester.pumpAndSettle();

    expect(path, AppRoutes.login);
    expect(find.text(AppText.accountSuspended), findsOneWidget);
  });

  testWidgets('the router is built once, not on every sign-in change',
      (tester) async {
    await pumpApp(tester, const SignedOut());
    final first = router;
    auth.setState(signedInAs(Role.miner));
    await tester.pumpAndSettle();
    expect(identical(router, first), isTrue);
  });

  testWidgets('while the session is read, the splash shows', (tester) async {
    final config = (AppConfig.check('https://api.example.test') as ConfigOk)
        .config;
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...fakeOverrides(FakeAuthController(const AuthUnknown())),
        ],
        child: const MineChainApp(),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(AppText.appTitle), findsOneWidget);
    // Mobile (36): the logo above the name.
    expect(find.byType(MineChainLogo), findsOneWidget);
  });
}
