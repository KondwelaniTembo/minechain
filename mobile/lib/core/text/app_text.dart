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

  // ---- Miner home ----

  static const String registerConsignment = 'Register consignment';
  static const String myConsignments = 'My consignments';
  static const String sendMyWork = 'Send my work';

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
