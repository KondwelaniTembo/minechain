// The MineChain app, F2: Riverpod is set up, the theme and shared widgets
// exist, and a temporary sample home shows them on the phone.

import 'package:flutter/material.dart';
// flutter_riverpod gives us ProviderScope, the store that holds all of the
// app's shared state (explained below).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/riverpod/no_retry.dart';
import 'core/text/app_text.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/home_scaffold.dart';

// main() is where every Dart program starts. Android launches the app, the
// Flutter engine starts, and then it calls this function.
void main() {
  // runApp() makes the widget it is given the root of the whole screen.
  runApp(
    // ProviderScope must sit above everything that uses Riverpod. It creates
    // the container that keeps each provider's value, so any screen can read
    // shared state without passing it down by hand. Nothing uses a provider
    // yet; it is set up now so later steps only add providers.
    //
    // retry: noRetry turns off Riverpod's automatic retry (see no_retry.dart
    // for why). Tests pass the same function.
    const ProviderScope(retry: noRetry, child: MineChainApp()),
  );
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
