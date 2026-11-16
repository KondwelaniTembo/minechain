// Every sentence and label the user sees, in one file.
//
// Why one file: the wording stays plain and consistent (the same action is
// always called the same thing), it can be read and checked in one go, and if
// a second language is ever added (FR-15, cut for now) there is one place to
// start from.
//
// Rule: everyday words, short, no technical terms (plan section 7). For
// example "Send my work", not "Sync".

/// The app's text. Constants only.
abstract final class AppText {
  // ---- App ----

  static const String appTitle = 'MineChain';

  /// Shown instead of the app when it was built without a valid server
  /// address (see lib/core/config/app_config.dart). The address itself is
  /// never shown.
  static const String missingServerAddress =
      'This app was built without its server address.';

  // ---- Shared ----

  static const String comingSoon = 'Coming soon';
  static const String myAccount = 'My account';

  // ---- Login (features/auth/presentation/login_screen.dart) ----

  static const String username = 'Username';
  static const String password = 'Password';
  static const String logIn = 'Log in';
  static const String loggingIn = 'Logging in…';
  static const String showPassword = 'Show password';
  static const String hidePassword = 'Hide password';
  static const String enterUsername = 'Enter your username.';
  static const String enterPassword = 'Enter your password.';

  // Why the user was signed out (SignedOut.reason), shown on the login
  // screen. The API's own reasons reuse the sentences further down.
  static const String unsupportedApp =
      'This version of the app does not support your account. Please update it.';
  static const String accountChanged =
      'This phone was signed in to a different account. Please log in again.';
  static const String loggedOut =
      'You have been logged out. Please log in again.';

  // ---- Homes ----

  static const String minerTitle = 'Miner';
  static const String transporterTitle = 'Transporter';
  static const String buyerTitle = 'Buyer';
  static const String officerTitle = 'Officer';
  static const String adminTitle = 'Administrator';

  /// Shown on a home while the token has expired (decision Q2).
  static const String needsPasswordNotice =
      'Enter your password the next time you send your work.';

  // Tiles (plan section 4.2).
  static const String registerConsignment = 'Register consignment';
  static const String myConsignments = 'My consignments';
  static const String sendMyWork = 'Send my work';
  static const String takeCustody = 'Take custody';
  static const String checkConsignment = 'Check a consignment';
  static const String myHandoffs = 'My handoffs';
  static const String recordPurchase = 'Record purchase';
  static const String myPurchases = 'My purchases';
  static const String reports = 'Reports';
  static const String alerts = 'Alerts';
  static const String auditTrail = 'Audit trail';
  static const String accountRequests = 'Account requests';
  static const String accounts = 'Accounts';
  static const String gpsZones = 'GPS zones';
  static const String anchoring = 'Anchoring';

  // ---- Server status banner (core/widgets/server_status_banner.dart) ----

  static const String serverWaking =
      'Waking the server. This can take up to a minute the first time.';
  static const String serverNotReady =
      'The server is running but not ready. Try again in a minute.';
  static const String tryAgain = 'Try again';

  // ---- Problems with the server's answer (core/errors/failure_text.dart) ----

  static const String invalidCredentials = 'Wrong username or password.';
  static const String sessionNotValid =
      'Your session has ended. Please log in again.';
  static const String sessionExpired =
      'Your session has expired. Please enter your password again.';
  static const String accountPending =
      'Your account is waiting for an administrator to approve it.';
  static const String accountSuspended =
      'Your account has been suspended. Please contact an administrator.';
  static const String accountRejected =
      'Your account request was not approved. Please contact an administrator.';
  static const String accountNotActive =
      'Your account is not active. Please contact an administrator.';
  static const String notAllowed = 'You are not allowed to do this.';
  static const String tooManyTries =
      'Too many tries. Please wait a few minutes, then try again.';
  static const String checkTheForm =
      'Some details are missing or wrong. Please check them and try again.';
  static const String somethingWentWrong =
      'Something went wrong. Please try again.';

  // ---- Problems reaching the server ----

  static const String noConnection =
      'No internet connection. Your work is safe on this phone.';
  static const String timedOut =
      'The server took too long to answer. Please try again.';
  static const String insecureConnection =
      'The connection is not safe, so the app stopped. Try another network.';
  static const String badResponse =
      'The server sent an answer the app could not read. Please try again later.';
}
