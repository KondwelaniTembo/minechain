// The MineChain app, F3: the API address is checked at start-up and handed to
// the rest of the app through Riverpod. A theme, shared widgets and a temporary
// sample home come from F2.

import 'package:flutter/material.dart';
// flutter_riverpod gives us ProviderScope, the store that holds all of the
// app's shared state (explained below).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/config/config_provider.dart';
import 'core/riverpod/no_retry.dart';
import 'core/text/app_text.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/home_scaffold.dart';

// main() is where every Dart program starts. Android launches the app, the
// Flutter engine starts, and then it calls this function.
void main() {
  // Check the address that was compiled in (see app_config.dart). This is the
  // only place in the app that reads it.
  final result = AppConfig.check(compiledApiBaseUrl);

  // ConfigResult is sealed, so these two cases are all there can be.
  switch (result) {
    case ConfigOk(:final config):
      // runApp() makes the widget it is given the root of the whole screen.
      runApp(
        // ProviderScope must sit above everything that uses Riverpod. It
        // creates the container that keeps each provider's value, so any
        // screen can read shared state without passing it down by hand.
        //
        // retry: noRetry turns off Riverpod's automatic retry (see
        // no_retry.dart for why). Tests pass the same function.
        //
        // overrides: appConfigProvider has no value of its own; here it is
        // given the checked settings, and every later piece of code reads the
        // address from it.
        ProviderScope(
          retry: noRetry,
          overrides: [appConfigProvider.overrideWithValue(config)],
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

/// The root widget: theme and first screen.
class MineChainApp extends StatelessWidget {
  const MineChainApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MaterialApp sets up what every screen shares: theme, title, text
    // direction and navigation. There is exactly one, at the top.
    return MaterialApp(
      // Shown in Android's recent-apps list. The name under the launcher icon
      // comes from android:label in AndroidManifest.xml.
      title: AppText.appTitle,
      debugShowCheckedModeBanner: false,
      // Both themes are given, and themeMode.system picks the one matching the
      // phone's dark-mode setting, switching live if the user changes it.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const SampleHomeScreen(),
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

// TEMPORARY (F2): a sample home to see the theme and tiles on the phone.
// Replaced in F7 by the real miner home, reached through login and routing.
class SampleHomeScreen extends StatelessWidget {
  const SampleHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Every tile does the same thing for now: a short "Coming soon" message.
    void comingSoon() {
      // ScaffoldMessenger shows snack bars (short messages at the bottom). The
      // hide call first removes any message still showing, so quick taps do
      // not queue up a line of identical messages.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text(AppText.comingSoon)));
    }

    // The miner's tiles from plan section 4.2. The screen only lists what it
    // offers; HomeScaffold decides the layout. This is how widgets compose:
    // small pieces, each with one job, fitted together.
    return HomeScaffold(
      title: AppText.appTitle,
      onAccountPressed: comingSoon,
      actions: [
        HomeAction(
          icon: Icons.qr_code_scanner,
          label: AppText.registerConsignment,
          onTap: comingSoon,
          primary: true,
        ),
        HomeAction(
          icon: Icons.inventory_2,
          label: AppText.myConsignments,
          onTap: comingSoon,
        ),
        HomeAction(
          icon: Icons.cloud_upload,
          label: AppText.sendMyWork,
          onTap: comingSoon,
        ),
      ],
    );
  }
}
