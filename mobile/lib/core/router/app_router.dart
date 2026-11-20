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
import '../../features/admin/presentation/account_requests_screen.dart';
import '../../features/admin/presentation/admin_home_screen.dart';
import '../../features/alerts/presentation/alert_detail_screen.dart';
import '../../features/alerts/presentation/alerts_screen.dart';
import '../../features/auth/domain/auth_state.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/presentation/activate_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/buyer/presentation/buyer_home_screen.dart';
import '../../features/consignments/presentation/my_consignments_screen.dart';
import '../../features/handoff/presentation/custody_controller.dart'
    show CustodyStepKind;
import '../../features/handoff/presentation/take_custody_screen.dart';
import '../../features/miner/presentation/miner_home_screen.dart';
import '../../features/officer/presentation/officer_home_screen.dart';
import '../../features/registration/presentation/register_consignment_screen.dart';
import '../../features/sync/presentation/send_work_screen.dart';
import '../../features/transporter/presentation/transporter_home_screen.dart';
import '../../features/verification/presentation/consignment_check_screen.dart';
import '../widgets/app_navigation.dart';
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
  ref.listen<AuthState>(
    authControllerProvider,
    (_, _) => authChanges.changed(),
  );

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
      // Signed out only (redirect rule 2). The login screen opens them with
      // push(), so their back arrow returns to it.
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: AppRoutes.activate,
        builder: (context, state) => const ActivateScreen(),
      ),
      // The frame with the navigation bar (Mobile (37)): Home and Account.
      // "Indexed stack" keeps both places alive while one is hidden, so the
      // home keeps its scroll position while Account is open.
      //
      // The Home branch holds all five homes. Only one is ever reached: the
      // redirect puts each role on its own home, and keeps it out of the
      // others (rules 3 and 4), inside the frame as outside it.
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppNavigationShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
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
            ],
          ),
          // Every signed-in role, including SignedInNeedsPassword (redirect
          // rule 5). The homes' account button and the bar both go() here,
          // so there is one "My account" with two ways in (Q9).
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.account,
                builder: (context, state) => const AccountScreen(),
              ),
            ],
          ),
        ],
      ),
      // The task pages are outside the frame, on the app's top navigator, so
      // a push() covers the whole screen, bar included (Q11), and the back
      // arrow returns to the home in its frame.
      //
      // Under /miner, so redirect rule 4 sends every other role home. The
      // miner home opens it with push(), so the back arrow returns there.
      GoRoute(
        path: AppRoutes.minerRegister,
        builder: (context, state) => const RegisterConsignmentScreen(),
      ),
      GoRoute(
        path: AppRoutes.minerSync,
        builder: (context, state) => const SendWorkScreen(),
      ),
      GoRoute(
        path: AppRoutes.minerConsignments,
        builder: (context, state) => const MyConsignmentsScreen(),
      ),
      // One screen under three homes (consignment check plan, Q3), so redirect
      // rule 4 keeps each path for its own role. The homes open it with
      // push(), so the back arrow returns there.
      for (final path in [
        AppRoutes.transporterCheck,
        AppRoutes.buyerCheck,
        AppRoutes.officerCheck,
      ])
        GoRoute(
          path: path,
          builder: (context, state) => const ConsignmentCheckScreen(),
        ),
      // Under /transporter, so redirect rule 4 sends every other role home.
      // The transporter home opens it with push().
      GoRoute(
        path: AppRoutes.transporterCustody,
        builder: (context, state) => const TakeCustodyScreen(),
      ),
      // The same list and sync screens as the miner's (T5); the list shows
      // handoffs, and the sync sends whatever this account has waiting.
      GoRoute(
        path: AppRoutes.transporterHandoffs,
        builder: (context, state) =>
            const MyConsignmentsScreen(kind: StepListKind.handoffs),
      ),
      GoRoute(
        path: AppRoutes.transporterSync,
        builder: (context, state) => const SendWorkScreen(),
      ),
      // "Take custody" for the buyer (buyer purchase plan, Q4). Under /buyer,
      // so redirect rule 4 sends every other role home.
      GoRoute(
        path: AppRoutes.buyerPurchase,
        builder: (context, state) =>
            const TakeCustodyScreen(kind: CustodyStepKind.purchase),
      ),
      // The miner's list and sync screens for the buyer (T3).
      GoRoute(
        path: AppRoutes.buyerPurchases,
        builder: (context, state) =>
            const MyConsignmentsScreen(kind: StepListKind.purchases),
      ),
      GoRoute(
        path: AppRoutes.buyerSync,
        builder: (context, state) => const SendWorkScreen(),
      ),
      // The officer's alerts (officer alerts plan, T2 and T3). Under
      // /officer, so redirect rule 4 sends every other role home,
      // administrators included (Scope (5)). The home pushes the list, and
      // the list pushes one alert, so each back arrow returns one page.
      GoRoute(
        path: AppRoutes.officerAlerts,
        builder: (context, state) => const AlertsScreen(),
      ),
      GoRoute(
        path: AppRoutes.officerAlertPattern,
        builder: (context, state) =>
            AlertDetailScreen(id: state.pathParameters['id']!),
      ),
      // Under /admin, so redirect rule 4 sends every other role home. The
      // admin home opens it with push(), so the back arrow returns there.
      GoRoute(
        path: AppRoutes.adminRequests,
        builder: (context, state) => const AccountRequestsScreen(),
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
