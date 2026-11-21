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

  /// Register a consignment (plan M5). Under /miner, so the redirect's role
  /// rule keeps it for miners only.
  static const String minerRegister = '/miner/register';

  /// "Send my work" (plan M6). Under /miner like the screen above. The sync
  /// itself serves transporters and buyers too; their own screens come in
  /// later modules.
  static const String minerSync = '/miner/sync';

  /// "My consignments" (plan M7). Under /miner like the screens above.
  static const String minerConsignments = '/miner/consignments';

  /// "Check a consignment" (consignment check plan, Q3: one screen, three
  /// paths). Each is under its role's home, so the redirect's role rule
  /// keeps miners and administrators out with no new rule.
  static const String transporterCheck = '/transporter/check';
  static const String buyerCheck = '/buyer/check';
  static const String officerCheck = '/officer/check';

  /// "Take custody" (transporter handoff plan). Under /transporter, so the
  /// redirect's role rule keeps it for transporters only.
  static const String transporterCustody = '/transporter/custody';

  /// "My handoffs" and the transporter's "Send my work" (transporter handoff
  /// T5): the miner's two screens again, under /transporter for the same
  /// role rule.
  static const String transporterHandoffs = '/transporter/handoffs';
  static const String transporterSync = '/transporter/sync';

  /// "Record purchase" (buyer purchase plan, T2): "Take custody" for the
  /// buyer. Under /buyer, so the redirect's role rule keeps it for buyers
  /// only.
  static const String buyerPurchase = '/buyer/purchase';

  /// "My purchases" and the buyer's "Send my work" (buyer purchase T3): the
  /// miner's two screens again, under /buyer for the same role rule.
  static const String buyerPurchases = '/buyer/purchases';
  static const String buyerSync = '/buyer/sync';

  /// The officer's alerts list (officer alerts plan, T2), and one alert
  /// (T3). Under /officer, so the redirect's role rule keeps every other
  /// role out, administrators included (Scope (5)).
  static const String officerAlerts = '/officer/alerts';
  static const String officerAlertPattern = '/officer/alerts/:id';
  static String officerAlert(String id) =>
      '/officer/alerts/${Uri.encodeComponent(id)}';

  /// The administrator's list of pending account requests. Under /admin, so
  /// the redirect's role rule keeps it for administrators only.
  static const String adminRequests = '/admin/requests';

  /// The administrator's accounts (admin accounts plan): the list (T2), one
  /// account (T3), opened from the list through openedAccountProvider
  /// (there is no GET /admin/users/{id} to read it by its id), and "Create
  /// account" (T5). All under /admin, for the same role rule.
  static const String adminAccounts = '/admin/accounts';
  static const String adminAccount = '/admin/accounts/account';
  static const String adminCreateAccount = '/admin/accounts/new';

  /// The signed-in user's own account and Log out. Open to every role, so it
  /// is not under a home's path.
  static const String account = '/account';

  /// The pages a signed-out user may see.
  static const Set<String> signedOutPages = {login, register, activate};
}
