// Which screen the user may be on, decided in ONE pure function (plan section
// 4.1, rules 1-5).
//
// "Pure" means: the answer depends only on the two inputs, and the function
// changes nothing. So it can be tested with a plain table of cases, and the
// router can call it as often as it likes.
//
// This only keeps the screens tidy. The server checks the role on every
// request, so a screen opened by mistake still cannot do anything.

import '../../features/auth/domain/auth_state.dart';
import '../../features/auth/domain/user.dart';
import 'routes.dart';

/// The home path of each role.
String homeOf(Role role) => switch (role) {
  Role.miner => AppRoutes.miner,
  Role.transporter => AppRoutes.transporter,
  Role.buyer => AppRoutes.buyer,
  Role.officer => AppRoutes.officer,
  Role.admin => AppRoutes.admin,
};

/// Where to go instead of [location], or null to stay.
///
///  1. Session not read yet -> /start.
///  2. Signed out -> only /login, /register, /activate; anything else ->
///     /login.
///  3. Signed in and on a signed-out page or /start -> the role's home.
///  4. Signed in and on another role's page -> the role's home.
///  5. Otherwise stay (the role's own pages, and /account, which every
///     signed-in role may open).
///
/// "Signed in" includes SignedInNeedsPassword (decision Q2): the home and
/// offline work stay open; only server actions need the password again.
/// A path that belongs to no role (an unknown or mistyped one) sends a
/// signed-in user home too.
String? redirectFor(AuthState auth, String location) {
  // Only the path counts; "?a=b" or "#x" after it never change the decision.
  final path = Uri.parse(location).path;

  final User user;
  switch (auth) {
    case AuthUnknown():
      return path == AppRoutes.start ? null : AppRoutes.start; // rule 1
    case SignedOut():
      return AppRoutes.signedOutPages.contains(path)
          ? null
          : AppRoutes.login; // rule 2
    case SignedIn(user: final signedIn):
      user = signedIn;
    case SignedInNeedsPassword(user: final signedIn):
      user = signedIn;
  }

  // Rule 5: the account screen belongs to every role. Only the exact path:
  // nothing lives under /account yet, so /account/anything goes home below.
  if (path == AppRoutes.account) return null;

  final home = homeOf(user.role);
  // Rule 5: the role's own home, or any page under it.
  if (path == home || path.startsWith('$home/')) return null;
  // Rules 3 and 4, and unknown paths.
  return home;
}
