// Every screen's address ("path"), in one place (plan section 4.1).
//
// A path is like a web address inside the app: "/miner" is the miner's home.
// Writing them once as constants means a typo is a compile error, not a
// screen that silently never opens.
//

abstract final class AppRoutes {
  /// Start-up: shown while the saved session is read.
  static const String start = '/start';

  /// The login screen.
  static const String login = '/login';

  /// Request an account (miner, transporter, buyer).
  static const String register = '/register';

  /// Activate an officer or administrator account with a code.
  static const String activate = '/activate';

  // The five homes. Every page of a role lives under its home's path, for
  // example /miner/register-consignment, so one rule covers them all.
  static const String miner = '/miner';
  static const String transporter = '/transporter';
  static const String buyer = '/buyer';
  static const String officer = '/officer';
  static const String admin = '/admin';

  /// The signed-in user's own account and Log out. Open to every role, so it
  /// is not under a home's path.
  static const String account = '/account';

  /// The pages a signed-out user may see.
  static const Set<String> signedOutPages = {login, register, activate};
}
