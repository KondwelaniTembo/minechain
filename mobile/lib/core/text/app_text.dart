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

  /// Between the role and the username in the top bar's pill (Mobile (36)).
  static const String pillSeparator = ' · ';

  /// What TalkBack reads for that pill: "Miner, signed in as mutale_banda".
  static String signedInAs(String role, String username) =>
      '$role, signed in as $username';

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

  // ---- Register a consignment (features/registration/presentation/
  //      register_consignment_screen.dart, plan M5) ----

  static const String openingSavedWork = 'Opening your saved work…';
  static const String savedWorkProblem =
      'Your saved work cannot be opened on this phone. Do not uninstall the '
      'app: ask an administrator for help.';
  static const String checkingDeviceKey = 'Checking this phone\'s device key…';

  static const String scanStep = '1. Scan the custody record';
  static const String locationStep = '2. Location';
  static const String mineralStep = '3. Mineral';
  static const String weightStep = '4. Weight';

  static const String scanHint =
      'Hold the QR code on the custody record inside the camera view.';
  static String scannedRecord(String code) => 'Custody record $code ✓';
  static const String scanAnother = 'Scan another record';
  static const String notOurRecord =
      'This QR code is not a MineChain custody record.';

  /// Shown in place of the camera until the location question is answered:
  /// Android shows one permission dialog at a time.
  static const String cameraWaiting = 'The camera starts in a moment.';
  static String alreadyRegistered(DateTime on) =>
      'This custody record was already registered on this phone on '
      '${on.day} ${_months[on.month - 1]}.';

  static const String cameraNeeded =
      'The camera is needed to scan the custody record. Allow it to '
      'continue.';
  static const String allowCamera = 'Allow camera';
  static const String openSettings = 'Open settings';
  static const String noCamera = 'This phone has no camera the app can use.';
  static const String cameraFailed = 'The camera could not start.';

  static const String startingLocation = 'Starting the location…';
  static const String locationOff =
      'Turn on Location to register a consignment.';
  static const String turnOnLocation = 'Turn on Location';
  static const String locationNeeded =
      'The app needs your location to record where the minerals were found. '
      'It is only read while this screen is open.';
  static const String allowLocation = 'Allow location';
  static const String locationRefused =
      'Location is not allowed for MineChain. Open the settings and allow '
      'Location for this app.';
  static const String locationApproximate =
      'Only your approximate location is allowed. Open the settings and turn '
      'on "Use precise location" for MineChain.';
  static String findingLocation(double? accuracyM) => accuracyM == null
      ? 'Finding your location…'
      : 'Finding your location… ${accuracyM.round()} m';
  static const String stillLooking =
      'Still looking. Stand in the open, away from buildings and trees.';
  static const String fakeLocation =
      'This phone is using a fake location. Turn off any fake-GPS app to '
      'continue.';
  static const String locationFailed = 'The location could not be read.';
  static String locationFound(double accuracyM) =>
      'Location found ✓ (within ${accuracyM.round()} m)';

  static const String gold = 'Gold';
  static const String copper = 'Copper';
  static const String cobalt = 'Cobalt';
  static const String manganese = 'Manganese';
  static const String emerald = 'Emerald';
  static const String amethyst = 'Amethyst';

  static const String weightInGrams = 'Weight in grams';
  static const String weightInKilograms = 'Weight in kilograms';
  static const String grams = 'g';
  static const String kilograms = 'kg';
  static const String chooseMineralFirst = 'Choose the mineral first.';
  static const String weightNegative = 'The weight cannot be below zero.';
  static const String weightNotANumber =
      'Enter the weight as a number, like 12.5.';
  static String weightTooManyDecimals(int decimals) =>
      'Use at most $decimals digits after the point.';
  static const String weightZero = 'The weight must be more than zero.';
  static const String weightTooLarge =
      'That weight is too large. Check the number.';

  static const String save = 'Save';
  static const String saving = 'Saving…';
  static const String savedOnPhone =
      'Saved on this phone. It will be sent when you are online.';
  static const String registerAnother = 'Register another';
  static const String backToHome = 'Back to home';
  static const String saveKeyNotUsable =
      'This phone cannot sign records for you right now. Open My account to '
      'see why.';
  static const String saveInvalid =
      'Something in this record is not valid. Scan the custody record again.';
  static const String saveSigningFailed =
      'The phone could not sign the record. Nothing was saved. Try again.';
  static const String saveFailed =
      'Something went wrong. Nothing was saved. Try again.';

  // ---- Send my work (features/sync/presentation/send_work_screen.dart,
  //      plan M6 and §3) ----

  static const String sendNow = 'Send now';
  static const String sendingNow = 'Sending…';

  /// "3 records are safe on this phone and waiting to be sent." Shown only
  /// from the database's own count (plan §3, "Your work is safe").
  static String waitingOnPhone(int n) => n == 1
      ? '1 record is safe on this phone and waiting to be sent.'
      : '$n records are safe on this phone and waiting to be sent.';
  static const String nothingWaiting = 'Nothing is waiting to be sent.';

  /// Every record the server has, flagged ones included: a flagged record
  /// has left the phone too.
  static String countSentToServer(int n) => 'Sent to the server: $n';

  /// Shown indented under [countSentToServer]: part of it, not extra.
  static String countOfWhichUnderReview(int n) => 'of which under review: $n';

  /// Records the server refused; kept on the phone as evidence.
  static String countNeedsAttention(int n) => 'Needs attention: $n';
  static const String stuckDeferred =
      'Some records were not accepted yet after 3 days. Ask your '
      'administrator.';

  static String sendingProgress(int done, int total) =>
      'Sending your work… $done of $total';
  static const String sendingSlowServer =
      'This can take up to a minute if the server is waking up.';

  // The last run's result.

  /// "Last send, 22:06 — you tapped Send now". [localTime] is already in
  /// the phone's own time zone; [why] is one of the three below.
  static String lastSendAt(DateTime localTime, String why) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Last send, ${two(localTime.hour)}:${two(localTime.minute)} — $why';
  }

  static const String sendYouTapped = 'you tapped Send now';
  static const String sendAfterSave = 'after you saved';
  static const String sendAutomatic = 'started automatically';

  static const String nothingToSend = 'There was nothing to send.';

  /// "3 sent to the server ✓", or "3 sent to the server — 2 under review".
  static String resultSentToServer(int n, {required int underReview}) =>
      underReview == 0
      ? '$n sent to the server ✓'
      : '$n sent to the server — $underReview under review';
  static String resultRejected(int n) => '$n not accepted';
  static String resultWaiting(int n) => '$n still waiting to be sent';

  /// Debug builds only: how long the send took, for NFR-03's 10 s.
  static String sendTook(Duration elapsed) =>
      'The send took ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s.';

  // One record's state. "Send my work" puts the QR code in front of these;
  // "My consignments" shows them under the record (decision Mobile (34)), so
  // both screens say the same thing in the same words.
  static const String _underReview = 'under review';
  static String _notAccepted(String code) =>
      'this record could not be accepted ($code). Show this to your '
      'administrator.';
  static const String _notAcceptedUpdateApp =
      'this record could not be accepted. Please update the app.';

  /// One flagged step: the code and the server's message as given.
  static String underReviewLine(String qrCode, String message) =>
      '$qrCode: $_underReview. $message';

  /// One rejected step (plan §3: the code, and "Show this to your
  /// administrator").
  static String rejectedLine(String qrCode, String code) =>
      '$qrCode: ${_notAccepted(code)}';
  static String updateAppLine(String qrCode) =>
      '$qrCode: $_notAcceptedUpdateApp';

  // ---- My consignments (features/consignments/, plan M7) ----

  /// The singular of [waitingOnPhone].
  static const String stepWaiting =
      'Safe on this phone and waiting to be sent.';

  /// The singular of [stuckDeferred] (plan §3).
  static const String stepStuck =
      'Not accepted yet after 3 days. Ask your administrator.';

  /// As [resultSentToServer].
  static const String stepSent = 'Sent to the server ✓';
  static const String stepUnderReview = 'Sent to the server — $_underReview.';

  /// As [countNeedsAttention] and [rejectedLine].
  static String stepRejected(String code) =>
      'Needs attention: ${_notAccepted(code)}';
  static const String stepUpdateApp = 'Needs attention: $_notAcceptedUpdateApp';

  /// "Gold, 1.5 g".
  static String consignmentWhat(String mineral, String weight, String unit) =>
      '$mineral, $weight $unit';
  static const String milligrams = 'mg';

  /// "Saved 18 Nov, 02:29", in the phone's own time.
  static String savedAt(DateTime localTime) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Saved ${localTime.day} ${_months[localTime.month - 1]}, '
        '${two(localTime.hour)}:${two(localTime.minute)}';
  }

  static const String noConsignmentsYet =
      'You have not registered any consignments yet.';

  /// The list could not be read for a moment (Mobile (26)).
  static const String consignmentsPhoneBusy =
      'The phone was busy and could not show your consignments. Your work '
      'is safe on this phone.';

  // Why a send stopped. Every one says the work is still on the phone,
  // because it is: a stop never changes a saved record.
  static const String notSentOffline =
      'Not sent: no internet connection. Your work is safe on this phone.';
  static const String notSentTimedOut =
      'Not sent: the server did not answer in time. Your work is safe on '
      'this phone. Try again in a minute.';
  static const String notSentServer =
      'Not sent: the server had a problem. Your work is safe on this phone. '
      'Try again later.';
  static const String notSentAppProblem =
      'Something is wrong with the app. Your work is safe on this phone.';

  /// A moment's problem on the phone itself (the saved work was in use),
  /// never "cannot be opened": the work is fine and is tried again.
  static const String notSentPhoneBusy =
      'Not sent yet: the phone was busy. Your work is safe on this phone. '
      'It will be sent shortly.';

  /// A save that met the database in use for a moment (Mobile (26)).
  /// Nothing was stored, and nothing saved before is affected.
  static const String saveBusy =
      'Not saved yet: the phone was busy. Your other saved work is safe. '
      'Try Save again.';

  /// The same, once the automatic retry has also been used.
  static const String notSentPhoneBusyTryAgain =
      'Not sent yet: the phone was busy. Your work is safe on this phone. '
      'Tap Send now to try again.';

  /// The counts on "Send my work" could not be read for a moment.
  static const String countsPhoneBusy =
      'The phone was busy and could not count your saved work. Your work is '
      'safe on this phone.';
  static const String notSentNeedsPassword =
      'Your session has expired. Enter your password to send your work.';
  static const String notSentSignedOut =
      'You are signed out. Log in again to send your work. Your work is '
      'safe on this phone.';
  static const String notSentKeyProblem =
      'This phone cannot send records for you right now. Open My account '
      'to see why. Your work is safe on this phone.';
  static const String unmatchedAnswers =
      'Some answers from the server did not match the records sent. Those '
      'records stay on this phone and will be sent again.';

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
  static String rejected(String name) => 'The request from $name was rejected.';

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
