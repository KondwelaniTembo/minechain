// The app's navigation: which widget each path shows, and the redirect that
// keeps every user on the screens their sign-in state and role allow
// (plan section 4.1, decision Mobile (7)).
//
// Unlike the network code, the router does import features: it is where the
// app's screens are put together, so it has to know them. Nothing in a
// feature imports the router's internals, and core/network still imports no
// feature.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/account/presentation/account_screen.dart';
import '../../features/admin/presentation/admin_home_screen.dart';
import '../../features/auth/domain/auth_state.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/buyer/presentation/buyer_home_screen.dart';
import '../../features/miner/presentation/miner_home_screen.dart';
import '../../features/officer/presentation/officer_home_screen.dart';
import '../../features/transporter/presentation/transporter_home_screen.dart';
import 'redirect.dart';
import 'routes.dart';

/// Tells the router "the sign-in state changed, check the redirect again".
///
/// go_router listens to any Listenable through `refreshListenable`. A
/// ChangeNotifier is the simplest one: calling notifyListeners() rings the
/// bell. This lets the router stay the same object for the whole run; only the
/// redirect is re-run.
class _AuthChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// The router, built once.
final appRouterProvider = Provider<GoRouter>((ref) {
  final authChanges = _AuthChanges();

  // ref.listen (not ref.watch): watching would rebuild this provider, and so
  // throw the router away and lose the back stack, on every change.
  ref.listen<AuthState>(authControllerProvider, (_, _) => authChanges.changed());

  final router = GoRouter(
    initialLocation: AppRoutes.start,
    refreshListenable: authChanges,
    // Runs before every navigation, and again whenever authChanges rings.
    // It reads the current state at that moment and asks the pure function.
    // go_router stops with an error if redirects ever go round in a circle,
    // which the tests of redirectFor make sure cannot happen.
    redirect: (context, state) =>
        redirectFor(ref.read(authControllerProvider), state.uri.toString()),
    routes: [
      GoRoute(
        path: AppRoutes.start,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.miner,
        builder: (context, state) => const MinerHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.transporter,
        builder: (context, state) => const TransporterHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.buyer,
        builder: (context, state) => const BuyerHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.officer,
        builder: (context, state) => const OfficerHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.admin,
        builder: (context, state) => const AdminHomeScreen(),
      ),
      // Every signed-in role, including SignedInNeedsPassword (redirect rule
      // 5). The homes open it with push(), so it sits on top of the home and
      // the back arrow returns there.
      GoRoute(
        path: AppRoutes.account,
        builder: (context, state) => const AccountScreen(),
      ),
    ],
    // No path, query or other text from the address is logged.
    debugLogDiagnostics: false,
  );

  ref.onDispose(() {
    router.dispose();
    authChanges.dispose();
  });
  return router;
});
