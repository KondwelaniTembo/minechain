// Every sentence and label the user sees, in one file.
//
// Why one file: the wording stays plain and consistent (the same action is
// always called the same thing), it can be read and checked in one go, and if
// a second language is ever added (FR-15, cut for now) there is one place to
// start from.
//
// Rule: everyday words, short, no technical terms (plan section 7). For
// example "Send my work", not "Sync".

/// The app's text. Constants, plus a few small functions for sentences that
/// carry a value (a name, a number, a date), so the whole sentence still
/// lives here rather than being glued together in a screen.
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

  // The login screen's two links (F9).
  static const String requestAccountLink = 'Request an account';
  static const String haveActivationCodeLink = 'I have an activation code';

  // ---- Shared by the register and activate forms ----

  static const String confirmPassword = 'Type the password again';
  static const String enterConfirmPassword = 'Type the password again.';
  static const String passwordsDoNotMatch =
      'The two passwords are not the same.';

  /// The password policy (api.md, "Password policy"), as a hint under the
  /// field. The server checks it; this only says what it wants.
  static const String passwordPolicyHint =
      'Use at least 12 characters. A few words with spaces works well. '
      'Do not include your username.';

  static const String sending = 'Sending…';

  // ---- Request an account (features/auth/presentation/register_screen.dart)

  static const String registerTitle = 'Request an account';
  static const String chooseRoleLabel = 'I am a';
  static const String minerRoleHint = 'I mine and register minerals.';
  static const String transporterRoleHint = 'I carry minerals from the mine.';
  static const String buyerRoleHint = 'I buy minerals as a licensed buyer.';
  static const String licenceNumberOptional = 'Licence number (optional)';
  // The example must match LicenceNumberFormat.example. It is written out
  // because this file imports nothing from features/; the formatter's test
  // checks that the two stay the same.
  static const String licenceNumberHint = 'For example ZM-ASM-0001';
  static const String licenceIncomplete =
      'Enter the full licence number, like ZM-ASM-0001';
  static const String sendRequest = 'Send request';

  static const String enterFullName = 'Enter your full name.';
  static const String enterNewUsername = 'Choose a username.';
  static const String choosePassword = 'Choose a password.';
  static const String chooseRole = 'Choose what you do.';

  /// Under the username field for USERNAME_TAKEN (api.md's own words).
  static const String usernameTaken =
      'That username is already taken. Please choose another.';

  // The confirmation after a request was accepted.
  static const String requestSentTitle = 'Request sent';
  static const String requestSentBody =
      'An administrator will review it. You can log in once it is approved.';
  static const String backToLogin = 'Back to login';

  // ---- Activate (features/auth/presentation/activate_screen.dart) ----

  static const String activateTitle = 'Activate your account';
  static const String activateExplanation =
      'Your administrator gave you a username and an activation code. Enter '
      'them here and choose your own password. Nobody else will know it.';
  static const String activationCode = 'Activation code';
  static const String activationCodeHint =
      '12 letters and numbers. Spaces and dashes do not matter.';
  static const String enterActivationCode = 'Enter your activation code.';
  static const String newPassword = 'New password';
  static const String activateButton = 'Activate account';

  // ---- Account (features/account/presentation/account_screen.dart) ----

  static const String fullName = 'Full name';
  static const String role = 'Role';
  static const String licenceNumber = 'Licence number';
  static const String logOut = 'Log out';
  static const String cancel = 'Cancel';

  /// The question asked before logging out.
  static const String logOutQuestion = 'Log out of MineChain?';

  /// Under the question: logging out never deletes work saved on the phone
  /// (plan section 6.2).
  static const String logOutExplanation =
      'Work saved on this phone stays on this phone.';

  /// On the account screen while the token has expired (decision Q2).
  static const String accountNeedsPassword =
      'Your session has expired. Enter your password before you send work '
      'to the server.';

  // ---- Password prompt (features/auth/presentation/password_prompt.dart) ----

  /// The prompt's title, and the account screen's button that opens it.
  static const String enterYourPassword = 'Enter your password';

  /// The shorter button on a home's notice that opens the same prompt.
  static const String enterPasswordButton = 'Enter password';

  static const String passwordPromptExplanation =
      'Your session has expired. Enter your password to keep using the server.';
  static const String continueLabel = 'Continue';
  static const String checkingPassword = 'Checking…';

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

  // ---- Device key (features/device_key/, plan M2) ----

  /// The account screen's row label.
  static const String deviceKey = 'Device key';
  static const String deviceKeyChecking = 'Checking…';

  /// "Registered ✓ 4d61912d": the tick and the word, never colour alone,
  /// and the start of the fingerprint, to compare with an administrator's
  /// screen.
  static String deviceKeyRegistered(String shortFingerprint) =>
      'Registered ✓ $shortFingerprint';
  static const String deviceKeyNotRegistered =
      'Not registered yet (will be sent when online)';

  /// The plan's §4 sentence for a phone whose key is not the registered one.
  static const String deviceKeyOtherDevice =
      'This phone is not your registered phone. Ask an administrator to '
      'reset your device key.';
  static const String deviceKeyProblem =
      'This phone could not set up its device key. Close the app and open '
      'it again. If it keeps happening, ask an administrator.';

  // ---- Account requests (features/admin/presentation/
  //      account_requests_screen.dart) ----

  static const String refreshList = 'Refresh the list';
  static const String loadingRequests = 'Loading account requests…';
  static const String noRequestsWaiting = 'No account requests waiting.';
  static const String noLicenceNumber = 'No licence number';
  static const String showMore = 'Show more';
  static const String approve = 'Approve';
  static const String reject = 'Reject';

  /// Above the list. "1 request waiting", "3 requests waiting", or, when
  /// only part of the list is loaded, "Showing 20 of 45 requests".
  static String requestsCount({required int shown, required int total}) {
    if (shown < total) return 'Showing $shown of $total requests.';
    return total == 1 ? '1 request waiting.' : '$total requests waiting.';
  }

  /// When the account was requested, for example "Requested 5 Nov 2026".
  static String requestedOn(DateTime date) =>
      'Requested ${date.day} ${_months[date.month - 1]} ${date.year}';

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Shown instead of the list while the token has expired (decision Q2).
  static const String requestsNeedPassword =
      'Your session has expired. Enter your password to see account requests.';

  // Approve.
  static const String approveQuestion = 'Approve this request?';
  static String approveExplanation(String name, String role) =>
      '$name ($role) will be able to log in with the password they chose '
      'when they asked for the account.';
  static String approved(String name) => '$name can now log in.';

  // Reject.
  static const String rejectQuestion = 'Reject this request?';
  static String rejectExplanation(String name) =>
      '$name will not be able to log in. This cannot be undone: they would '
      'have to ask again with a different username.';
  static const String rejectReason = 'Reason';
  static const String rejectReasonHint =
      'For example: Licence number could not be verified';
  static const String rejectReasonWarning =
      'This reason is kept permanently and can never be changed. Keep it '
      'short and factual, and leave out personal details. Only '
      'administrators see it.';
  static const String rejectReasonTooShort = 'Write at least 3 characters.';
  static String rejected(String name) =>
      'The request from $name was rejected.';

  /// 404 or 409 on approve or reject: another administrator got there first.
  static const String requestAlreadyHandled =
      'Someone else has already dealt with this request. The list has been '
      'updated.';

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
  static const String weakPassword =
      'Choose a stronger password. See the note under the password.';
  static const String activationInvalid =
      'This activation code is not valid. Check it, or ask an administrator '
      'for a new one.';
  static const String checkTheForm =
      'Some details are missing or wrong. Please check them and try again.';
  static const String somethingWentWrong =
      'Something went wrong. Please try again.';

  // ---- Problems reaching the server ----

  /// Shown for any request that could not reach the server, the login
  /// included. It no longer says "Your work is safe on this phone" (plan
  /// §3): that is only true once a step has really been saved, and the sync
  /// screen (M6) says it there, with the count.
  static const String noConnection =
      'No internet connection. Try again when you have a signal.';
  static const String timedOut =
      'The server took too long to answer. Please try again.';
  static const String insecureConnection =
      'The connection is not safe, so the app stopped. Try another network.';
  static const String badResponse =
      'The server sent an answer the app could not read. Please try again later.';
}
