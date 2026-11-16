// The MineChain app, F5: the API address is checked at start-up and handed to
// the rest of the app through Riverpod (F3); the sample home checks the server
// once through the API client and shows a banner while it wakes up. A theme,
// shared widgets and a temporary sample home come from F2.

import 'package:flutter/material.dart';
// flutter_riverpod gives us ProviderScope, the store that holds all of the
// app's shared state (explained below).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/config/config_provider.dart';
import 'core/network/server_status.dart';
import 'core/riverpod/no_retry.dart';
import 'core/text/app_text.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/home_scaffold.dart';
import 'core/widgets/server_status_banner.dart';

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
//
// A ConsumerStatefulWidget is a StatefulWidget that can also use Riverpod
// (through `ref`). It is stateful only to run one thing once, when the screen
// first appears: the server check.
class SampleHomeScreen extends ConsumerStatefulWidget {
  const SampleHomeScreen({super.key});

  @override
  ConsumerState<SampleHomeScreen> createState() => _SampleHomeScreenState();
}

class _SampleHomeScreenState extends ConsumerState<SampleHomeScreen> {
  @override
  void initState() {
    super.initState();
    // Check the server once, so a sleeping server starts waking while the
    // user looks at the screen. Not straight away: initState runs while
    // Flutter is building, and Riverpod forbids changing a provider's state
    // during a build. addPostFrameCallback waits until this frame is drawn.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(serverStatusControllerProvider.notifier).check();
    });
  }

  // ScaffoldMessenger shows snack bars (short messages at the bottom). The
  // hide call first removes any message still showing, so quick taps do not
  // queue up a line of identical messages.
  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // Every tile does the same thing for now: "Coming soon".
    void comingSoon() => _say(AppText.comingSoon);

    // The miner's tiles from plan section 4.2. The screen only lists what it
    // offers; HomeScaffold decides the layout. This is how widgets compose:
    // small pieces, each with one job, fitted together.
    return HomeScaffold(
      title: AppText.appTitle,
      onAccountPressed: comingSoon,
      // Says nothing while the server is fine.
      header: const ServerStatusBanner(),
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
