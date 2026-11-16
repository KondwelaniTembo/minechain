// The MineChain app, F8: the API address is checked at start-up and handed to
// the rest of the app through Riverpod (F3); the saved session is read at
// start-up (F6); go_router shows the splash, the login screen or the role's
// home, following the sign-in state (F7); the token's expiry is checked each
// time the app comes back to the screen (F8).

import 'dart:async';

import 'package:flutter/material.dart';
// flutter_riverpod gives us ProviderScope, the store that holds all of the
// app's shared state (explained below).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/config/config_provider.dart';
import 'core/riverpod/no_retry.dart';
import 'core/router/app_router.dart';
import 'core/text/app_text.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/session_expiry_watcher.dart';

// main() is where every Dart program starts. Android launches the app, the
// Flutter engine starts, and then it calls this function.
void main() {
  // Check the address that was compiled in (see app_config.dart). This is the
  // only place in the app that reads it.
  final result = AppConfig.check(compiledApiBaseUrl);

  // ConfigResult is sealed, so these two cases are all there can be.
  switch (result) {
    case ConfigOk(:final config):
      // Secure storage talks to Android through Flutter's "platform channels",
      // which only work once Flutter's engine binding is set up. runApp does
      // this itself, but we read the saved session just before runApp.
      WidgetsFlutterBinding.ensureInitialized();

      // A ProviderContainer is the store that keeps each provider's value, so
      // any screen can read shared state without passing it down by hand.
      // Made here, rather than inside ProviderScope, so main() can start
      // reading the saved session before the first screen is drawn.
      //
      // retry: noRetry turns off Riverpod's automatic retry (see
      // no_retry.dart for why). Tests pass the same function.
      //
      // overrides: appConfigProvider has no value of its own; here it is
      // given the checked settings, and every later piece of code reads the
      // address from it.
      final container = ProviderContainer(
        retry: noRetry,
        overrides: [appConfigProvider.overrideWithValue(config)],
      );

      // Read the saved session (F6). Not awaited: the app appears at once on
      // the splash screen, and the router moves on when the read finishes.
      unawaited(container.read(authControllerProvider.notifier).restore());

      // runApp() makes the widget it is given the root of the whole screen.
      // UncontrolledProviderScope hands the container above to the widgets.
      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const MineChainApp(),
        ),
      );
    case ConfigInvalid(:final problem):
      // For the developer, in the terminal of `flutter run`: which rule was
      // broken, never the value itself. debugPrint also writes to the phone's
      // log in a release build, which is why only the rule's name is printed.
      debugPrint('API_BASE_URL was refused: ${problem.name}. '
          'See lib/core/config/app_config.dart.');
      runApp(const ConfigErrorApp());
  }
}

/// The root widget: theme and router.
///
/// A ConsumerWidget is a StatelessWidget that can read providers; here it
/// reads the router.
class MineChainApp extends ConsumerWidget {
  const MineChainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // MaterialApp sets up what every screen shares: theme, title, text
    // direction and navigation. There is exactly one, at the top.
    //
    // MaterialApp.router hands navigation to go_router: which screen shows is
    // decided by the current path and the redirect (core/router/), not by a
    // fixed `home:`.
    //
    // SessionExpiryWatcher sits above everything, so it lives exactly as long
    // as the app does and sees every return to the foreground, whichever
    // screen is showing (F8).
    return SessionExpiryWatcher(
      child: MaterialApp.router(
        routerConfig: ref.watch(appRouterProvider),
        // Shown in Android's recent-apps list. The name under the launcher
        // icon comes from android:label in AndroidManifest.xml.
        title: AppText.appTitle,
        debugShowCheckedModeBanner: false,
        // Both themes are given, and themeMode.system picks the one matching
        // the phone's dark-mode setting, switching live if the user changes
        // it.
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
      ),
    );
  }
}

/// Shown instead of the app when it was built without a valid server address.
///
/// Deliberately tiny: no Riverpod, no network, nothing that could need the
/// address. It only says, in plain words, that this build cannot work.
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppText.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            // The padding keeps the text off the screen's edges, and the
            // scroll view keeps it readable at the largest text size.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    AppText.missingServerAddress,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
