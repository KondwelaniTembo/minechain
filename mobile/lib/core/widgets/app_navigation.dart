// The frame around the signed-in user's two places, Home and Account, with the
// navigation bar that moves between them (decision Mobile (37), from Mapalo
// Maseko's suggestion in docs/plans/bottom-navigation-suggestion.md).
//
// Why a frame (go_router's "shell"): the bar belongs to both places, so it is
// drawn once around them instead of by each screen. Task pages ("Register
// consignment", "Send my work", ...) are outside the frame, so they cover the
// whole screen and have no bar (Q11).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../text/app_text.dart';

/// The frame: the current place, and the bar under it.
class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({super.key, required this.shell});

  /// go_router's handle on the two places ("branches"). It knows which one is
  /// shown, and keeps each one's own page stack, so the home keeps its scroll
  /// position while Account is open.
  final StatefulNavigationShell shell;

  /// The branches, in the order app_router.dart lists them.
  static const int homeBranch = 0;
  static const int accountBranch = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        // A tap on the place you are already in goes back to its start (the
        // home itself), as Android users expect from a bar.
        onDestinationSelected: (index) =>
            shell.goBranch(index, initialLocation: index == shell.currentIndex),
        destinations: const [
          // Outlined when not chosen, filled when chosen: the shape shows
          // where you are as well as the colour (Mobile (37), T10).
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: AppText.navHome,
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: AppText.navAccount,
          ),
        ],
      ),
    );
  }
}
