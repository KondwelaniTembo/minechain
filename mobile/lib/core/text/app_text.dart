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

  /// The refresh button's tooltip on "My account" (admin accounts T6b).
  static const String refreshAccount = 'Refresh my details';

  // ---- Navigation bar (core/widgets/app_navigation.dart, Mobile (37)) ----
  // One short word each: the bar has little room, and the page's own title
  // ("My account") says the rest.

  static const String navHome = 'Home';
  static const String navAccount = 'Account';

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

  /// Under "Saved on this phone" from the second save in one visit (T5b).
  static String savedThisVisit(int count) => '$count saved this time.';

  static const String registerAnother = 'Register another';
  static const String backToHome = 'Back to home';
  static const String saveKeyNotUsable =
      'This phone cannot sign records for you right now. Open My account to '
      'see why.';
  static const String saveInvalid =
      'Something in this record is not valid. Scan the custody record again.';
  static const String saveSigningFailed =
      'The phone could not sign the record. Nothing was saved. Try again.';
  static const String saveNoScreenLock =
      'Nothing was saved: this phone needs a screen lock before it can sign. '
      "Set a PIN, pattern or password in the phone's Settings, under Lock "
      'screen, then save again.';
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

  /// The heading for two or more sends since the user last looked (T5b):
  /// "Since 14:40 — sent 2 times after you saved". [why] is null when the
  /// sends had different triggers. Not "2 sends" (read as a verb on the
  /// emulator check) and not "2 sent", which the line below uses for
  /// records.
  static String sendsSince(DateTime localTime, int sends, String? why) {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(localTime.hour)}:${two(localTime.minute)}';
    return why == null
        ? 'Since $time — sent $sends times'
        : 'Since $time — sent $sends times $why';
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

  // "My handoffs" (transporter handoff plan, T5).
  static String tookCustodyOf(String code) => 'Took custody of $code';
  static const String noHandoffsYet =
      'You have not recorded taking custody of any consignment yet.';
  static const String handoffsPhoneBusy =
      'The phone was busy and could not show your handoffs. Your work is '
      'safe on this phone.';

  // "My purchases" (buyer purchase plan, T3).
  static String boughtRecord(String code) => 'Bought $code';
  static const String noPurchasesYet =
      'You have not recorded buying any consignment yet.';
  static const String purchasesPhoneBusy =
      'The phone was busy and could not show your purchases. Your work is '
      'safe on this phone.';

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

  /// Hardening H1: the key is made and used only on a phone with a screen
  /// lock. Plain steps, because the fix is in the phone's own settings.
  static const String screenLockNeeded =
      'This phone needs a screen lock before it can sign your records. Set '
      "a PIN, pattern or password in the phone's Settings, under Lock "
      'screen, then open MineChain again.';

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

  // ---- Accounts (features/admin/, admin accounts plan) ----

  // The refusals of api.md's shared table that get our own sentence (T1).
  // INVALID_STATUS_TRANSITION and LAST_ACTIVE_ADMIN keep the server's: it
  // names the action and the account's actual status.
  static const String accountNotFound =
      'This account could not be found. Go back to the list and refresh it.';
  static const String cannotSuspendSelf =
      'You cannot suspend your own account.';
  static const String cannotDeleteSelf = 'You cannot delete your own account.';
  static const String noDeviceKeyToReset =
      'This account has no device key to reset.';

  // The list (T2).
  static const String loadingAccounts = 'Loading accounts…';
  static const String accountsShowing = 'Show accounts that are';
  static const String accountsActive = 'Active';
  static const String accountsSuspended = 'Suspended';
  static const String accountsInvited = 'Invited';
  static const String accountsRejected = 'Rejected';
  static const String accountsDeleted = 'Deleted';
  static const String accountsNeedPassword =
      'Your session has expired. Enter your password to see the accounts.';
  static const String createAccount = 'Create account';

  /// Above the list, [status] in lower case: "12 active accounts.",
  /// "1 invited account.", or "Showing 20 of 45 active accounts.".
  static String accountsCount({
    required String status,
    required int shown,
    required int total,
  }) {
    if (shown < total) return 'Showing $shown of $total $status accounts.';
    return total == 1 ? '1 $status account.' : '$total $status accounts.';
  }

  static String noAccounts(String status) => 'No $status accounts.';
  static String suspendedBecause(String reason) => 'Suspended: $reason';
  static String rejectedBecause(String reason) => 'Rejected: $reason';
  static String deletedBecause(String reason) => 'Deleted: $reason';
  static String codeValidUntil(DateTime localTime) =>
      'Activation code valid until ${_dayAndTime(localTime)}';
  static const String codeExpired =
      'Activation code expired: give them a new one.';
  static const String noCodeLeft =
      'No activation code: too many wrong tries. Give them a new one.';

  // One account's page (T3).
  static const String accountTitle = 'Account';
  static const String accountIsActive = 'Active: can sign in.';
  static const String accountIsSuspended =
      'Suspended: cannot sign in until reactivated.';
  static const String accountIsInvited =
      'Invited: waiting to be activated with its code.';
  static const String accountIsPending =
      'Waiting for approval under Account requests.';
  static const String accountIsRejected =
      'Rejected: the request was refused. This is final.';
  static const String accountIsDeleted =
      'Deleted: can never sign in again. This is final.';
  static String createdOn(DateTime date) =>
      'Created ${date.day} ${_months[date.month - 1]} ${date.year}';
  static String approvedOn(DateTime date) =>
      'Approved ${date.day} ${_months[date.month - 1]} ${date.year}';
  static String reasonLine(String reason) => 'Reason: $reason';
  static String accountDeviceKey(String shortFingerprint) =>
      'Device key: registered ($shortFingerprint)';
  static const String accountNoDeviceKey = 'Device key: none registered';
  static const String lostPhoneHint =
      'Lost or replaced phone? Suspend the account, reset its device key, '
      'then reactivate it.';
  static const String yourOwnAccount =
      'This is your account. You cannot suspend or delete it.';
  static const String accountIsFinal =
      'This account is final: nothing about it can be changed.';
  static const String accountPageGone =
      'Open this account from the Accounts list.';
  static const String backToAccounts = 'Back to Accounts';
  static const String editName = 'Edit name';
  static const String suspendAccount = 'Suspend';
  static const String reactivateAccount = 'Reactivate';
  static const String resetDeviceKey = 'Reset device key';
  static const String newActivationCode = 'New activation code';
  static const String deleteAccount = 'Delete account';

  // The actions (T4).
  static const String suspendQuestion = 'Suspend this account?';
  static String suspendExplanation(String name) =>
      '$name will not be able to use MineChain until the account is '
      'reactivated.';
  static const String suspendHint = 'For example: Lost device reported';
  static String suspendedDone(String name) => '$name is suspended.';

  static const String resetKeyQuestion = 'Reset the device key?';
  static String resetKeyExplanation(String name) =>
      "Removes the device key of $name's lost or replaced phone. Records it "
      'already signed keep verifying. Reactivate the account when the person '
      'has the new phone.';
  static const String resetKeyHint = 'For example: Phone replaced';
  static const String resetKey = 'Reset key';
  static String resetKeyDone(String name) =>
      "$name's device key is removed. Reactivate the account when they have "
      'the new phone.';

  static const String deleteQuestion = 'Delete this account?';
  static String deleteExplanation(String name) =>
      'Deleting cannot be undone. $name can never sign in again, and the '
      'username stays taken. Every record they made is kept.';
  static const String deleteHint = 'For example: Left the cooperative';
  static const String deleteForGood = 'Delete for good';
  static String deletedDone(String name) => "$name's account is deleted.";

  static const String reactivateQuestion = 'Reactivate this account?';
  static String reactivateExplanation(String name) =>
      '$name will be able to sign in again.';
  static const String reactivateAfterReset =
      'Their device key was reset: signing in on the new phone registers its '
      'key.';
  static String reactivatedDone(String name) => '$name is active again.';

  static const String editNameTitle = 'Edit full name';
  static const String editNameExplanation =
      'Only the full name can change. The username, role and licence number '
      'never do.';
  static const String enterAccountFullName = 'Enter the full name.';
  static String renamedDone(String name) => 'The name is now $name.';

  // Creating an account and its code (T5).
  static const String createAccountIntro =
      'For a regulatory officer or another administrator. Miners, '
      'transporters and buyers ask for their own accounts.';
  static const String newAccountRole = 'Role';
  static const String officerRoleHint =
      'Reviews alerts and checks consignments.';
  static const String adminRoleHint =
      'Manages accounts, GPS zones and the system.';
  static const String chooseNewAccountRole = 'Choose the role.';
  static const String enterAccountUsername = 'Choose a username.';
  static const String usernameRulesHint =
      '3 to 32 letters, digits, _ . or -. It can never be changed.';

  static const String newCodeQuestion = 'Give a new activation code?';
  static const String newCodeExplanation =
      'The old code stops working at once. The new one works for 72 hours.';
  static const String giveNewCode = 'New code';

  static const String activationCodeTitle = 'Activation code';
  static String activationCodeFor(String username) =>
      'Activation code for $username';
  static String codeValidFor(DateTime localTime) =>
      'Valid until ${_dayAndTime(localTime)} (72 hours).';
  static String codeShownOnce(String name) =>
      'This code is shown only once. Give it to $name yourself, in person or '
      'by phone. They open the app, tap "I have an activation code", and '
      'choose their own password.';
  static const String codeDone = 'Done';
  static const String leaveWithoutCodeQuestion = 'Leave without the code?';
  static const String leaveWithoutCodeExplanation =
      'It cannot be shown again. If it is lost, give a new code from the '
      "account's page.";
  static const String stayOnCode = 'Stay';
  static const String leaveCode = 'Leave';
  static String accountCreated(String username) =>
      'Account $username created. It is waiting to be activated.';

  // ---- GPS zones (features/admin/, GPS zones plan) ----

  // T1: the refusal with our own sentence. ZONE_NAME_TAKEN and
  // INVALID_STATUS_TRANSITION keep the server's.
  static const String zoneNotFound =
      'This GPS zone could not be found. Go back to the list and refresh it.';

  // The list (T2).
  static const String loadingZones = 'Loading GPS zones…';
  static const String zonesShowing = 'Show zones that are';
  static const String zonesActive = 'Active';
  static const String zonesInactive = 'Inactive';
  static const String zonesNeedPassword =
      'Your session has expired. Enter your password to see the GPS zones.';
  static const String createZone = 'Create zone';
  static const String noActiveZone =
      'No zone is active. Every new registration is flagged as outside a '
      'licensed zone until you create or reactivate one.';

  /// Above the list, [status] in lower case: "2 active zones.", "1 inactive
  /// zone.", or "Showing 20 of 45 active zones.".
  static String zonesCount({
    required String status,
    required int shown,
    required int total,
  }) {
    if (shown < total) return 'Showing $shown of $total $status zones.';
    return total == 1 ? '1 $status zone.' : '$total $status zones.';
  }

  static String noZones(String status) => 'No $status zones.';
  static String zoneCorners(int count) =>
      count == 1 ? '1 corner' : '$count corners';

  // One zone's page (T3).
  static const String zoneTitle = 'GPS zone';
  static const String zoneIsActive =
      'Active: new registrations are checked against it.';
  static const String zoneIsInactive =
      'Inactive: new registrations are not checked against it.';
  static String zoneCreatedAt(DateTime localTime) =>
      'Created ${_dayAndTime(localTime)}';
  static String zoneChangedAt(DateTime localTime) =>
      'Changed ${_dayAndTime(localTime)}';
  static const String zoneShape = 'Shape';
  static const String zoneSketchNote = 'A sketch, not a map. North is up.';
  static String zoneSketchLabel(int corners) =>
      'A sketch of the zone with $corners corners, north up.';
  static String cornerNumber(int number) => 'Corner $number';
  static const String zoneFixedBoundary =
      'The boundary and licence number cannot be changed. To change them, '
      'rename this zone, create a new one with its name, then deactivate '
      'this one.';
  static const String zonePageGone = 'Open this zone from the GPS zones list.';
  static const String backToZones = 'Back to GPS zones';
  static const String renameZone = 'Rename';
  static const String deactivateZone = 'Deactivate';
  static const String reactivateZone = 'Reactivate';
  static const String zoneCornersHeading = 'Corners';

  // The actions (T4).
  static const String renameZoneTitle = 'Rename zone';
  static const String renameZoneExplanation =
      'Only the name changes. Alerts already raised keep the name they were '
      'raised with.';
  static const String zoneName = 'Zone name';
  static const String zoneNameTooShort = 'Write at least 3 characters.';
  static String zoneRenamedDone(String name) => 'The zone is now called $name.';

  static const String deactivateZoneQuestion = 'Deactivate this zone?';
  static String deactivateZoneExplanation(String name) =>
      'Registrations synced after this are no longer matched to $name. Steps '
      'already stored keep their zone.';
  static const String onlyActiveZone =
      'This is the only active zone. After this, every new registration is '
      'flagged.';
  static const String deactivateZoneHint = 'For example: Licence revoked';
  static String zoneDeactivatedDone(String name) => '$name is inactive.';

  static const String noActiveZoneTitle = 'No zone is active';
  static const String iUnderstand = 'I understand';

  static const String reactivateZoneQuestion = 'Reactivate this zone?';
  static String reactivateZoneExplanation(String name) =>
      'Registrations synced after this are checked against $name again.';
  static String zoneReactivatedDone(String name) => '$name is active again.';

  // Creating a zone (T5).
  static const String createZoneIntro =
      'A licensed extraction area. Registrations synced from now on are '
      'checked against it. Its boundary and licence number cannot be changed '
      'later.';
  static const String zoneLicenceNumber = 'Licence number (optional)';
  static const String zoneLicenceHint = 'It cannot be changed later.';
  static const String zoneCornersHint =
      'Add the corners in order around the edge, latitude first. Do not '
      'repeat the first corner at the end.';
  static const String noCornersYet = 'No corners yet. A zone needs at least 3.';
  static const String maxCornersReached = 'A zone has at most 100 corners.';
  static const String addMyLocation = 'Add my location';
  static const String addMyLocationHint =
      'Stand at each corner of the site in turn and tap "Add my location".';
  static const String stopLocating = 'Stop';
  static const String zoneLocationOff =
      'Turn on Location to add where you stand as a corner.';
  static const String zoneLocationNeeded =
      'The app needs your location to add where you stand as a corner. It is '
      'used only when you tap "Add my location".';
  static const String typeACorner = 'Type a corner';
  static const String typeCornerTitle = 'Type a corner';
  static const String typeCornerExplanation =
      'Latitude first, then longitude, as Google Maps shows a dropped pin.';
  static const String cornerFieldLabel = 'Latitude, longitude';
  static const String cornerFieldHint = '-15.418327, 28.289494';
  static const String addCorner = 'Add';
  static const String cornerNotTwoNumbers =
      'Write the latitude, then the longitude, with a comma between them. '
      'For example: -15.418327, 28.289494';
  static const String cornerLatitudeRange =
      'The latitude must be between -90 and 90.';
  static const String cornerLongitudeRange =
      'The longitude must be between -180 and 180.';
  static const String cornerTooManyDecimals =
      'Use at most 6 decimal places (about 10 cm).';
  static String removeCorner(int number) => 'Remove corner $number';
  static String zoneCreated(String name) =>
      'Zone $name created. Registrations synced from now on are checked '
      'against it.';
  static const String leaveZoneQuestion = 'Leave without creating the zone?';
  static const String leaveZoneExplanation =
      'The name and corners you entered will be lost.';
  static const String stay = 'Stay';
  static const String leave = 'Leave';

  // ---- Server status banner (core/widgets/server_status_banner.dart) ----

  static const String serverWaking =
      'Waking the server. This can take up to a minute the first time.';
  static const String serverNotReady =
      'The server is running but not ready. Try again in a minute.';
  static const String tryAgain = 'Try again';

  // ---- Check a consignment (consignment check plan) ----
  static const String checkScanHint =
      "Hold the QR code on the bag's custody record inside the camera view.";
  static String checkingRecord(String code) =>
      'Checking $code against the blockchain…';
  static const String checkingTakesTime =
      'This can take a few seconds on a slow network.';
  static const String scanAgain = 'Scan again';
  static const String checkNeedsPassword =
      'Your session has ended. Enter your password to check this consignment.';

  /// A 429's Retry-After, rounded up to whole minutes.
  static String tryAgainIn(Duration wait) {
    final minutes = (wait.inSeconds / 60).ceil().clamp(1, 1440);
    return minutes == 1
        ? 'You can scan again in about 1 minute.'
        : 'You can scan again in about $minutes minutes.';
  }

  // The result page (plan §4). The verdicts, worst first.
  static const String verdictMismatch =
      'This record does not match the blockchain. Officers have been told, '
      'and the consignment is held.';
  static const String verdictUnderReview =
      'Under review: an officer is checking a problem with this consignment.';
  static const String verdictChainUnavailable =
      'Could not reach the blockchain just now. Try again later.';
  static const String verdictNotAnchoredYet =
      'Recorded, not on the blockchain yet. This usually takes a few minutes.';
  static const String verdictNothingToCheck =
      'Nothing to check yet: no accepted step is recorded for this '
      'consignment.';
  static const String verdictVerified =
      'Verified: every step matches the blockchain.';

  static String stageLine(String stage) => 'Stage: $stage';
  static const String stageRegistered = 'Registered';
  static const String stageInTransit = 'On its way';
  static const String stagePurchased = 'Bought';
  static const String custodySteps = 'Custody steps';

  /// "miner mutale_banda", or "a miner" when the username is not shown.
  static String actorName(String role, String? username) =>
      username == null ? 'a $role' : '$role $username';
  static const String you = 'you';
  static String registeredBy(String who) => 'Registered by $who';
  static String handedOffTo(String who) => 'Handed off to $who';
  static String boughtBy(String who) => 'Bought by $who';

  static String weightLine(String weight) => 'Weight: $weight';
  static String zoneLine(String zone) => 'Zone: $zone';
  static const String outsideEveryZone = 'Outside every licensed zone';

  /// "Recorded 10 Nov 2026, 10:00", in the phone's own time.
  static String recordedAt(DateTime localTime) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Recorded ${localTime.day} ${_months[localTime.month - 1]} '
        '${localTime.year}, ${two(localTime.hour)}:${two(localTime.minute)}';
  }

  static const String stepMatches = 'Matches the blockchain';
  static const String stepMismatch = 'Does not match the blockchain';
  static const String stepNotAnchoredYet = 'Not on the blockchain yet';

  /// A rejected step (officers only): it is never sent, so not "yet".
  static const String stepRejectedNeverAnchored = 'Never put on the blockchain';
  static const String stepChainUnavailable =
      'Could not check the blockchain just now';
  static const String blockchainTransaction = 'Blockchain transaction:';
  static const String notSentYet = 'Not sent to the blockchain yet';

  // ---- Take custody (transporter handoff plan, T3) ----

  /// Q4: this account already took custody of the bag on this phone, in
  /// the phone's own time.
  static String alreadyTookCustody(DateTime localTime) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'You recorded taking custody of this consignment on '
        '${localTime.day} ${_months[localTime.month - 1]}, '
        '${two(localTime.hour)}:${two(localTime.minute)}.';
  }

  /// "20 Nov, 16:10", in the time given.
  static String _dayAndTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.day} ${_months[t.month - 1]}, ${two(t.hour)}:${two(t.minute)}';
  }

  static const String custodyPhoneBusy =
      'The phone was busy for a moment. Scan the custody record again.';
  static String custodyChecking(String code) => 'Looking up $code…';
  static String mineralLine(String mineral) => 'Mineral: $mineral';

  // Q2: the warnings, worst first. The first two need "Record anyway".
  static const String custodyMismatch =
      'This record does not match the blockchain. Officers have been told, '
      'and the consignment is held. You can still record that you took it.';
  static const String custodyUnderReview =
      'Under review: an officer is checking a problem with this '
      'consignment. You can still record that you took it.';
  static const String custodyAlreadyBought =
      'The server says this consignment is already bought. Your handoff is '
      'checked when it is sent.';
  static const String custodyNotOnServer =
      "This consignment is not on the server yet: the miner's registration "
      'may not have been sent. You can still record it; it is checked when '
      'it is sent.';
  static const String recordAnyway = 'Record anyway';
  static const String recordingAnyway = 'You chose to record it anyway.';

  // Q1: the check could not be made, so the transporter chooses the mineral.
  static const String custodyOffline =
      'No network: the consignment could not be checked. You can still '
      'record it; it is checked when it is sent.';
  static const String custodyCheckFailed =
      'The consignment could not be checked just now. You can still record '
      'it; it is checked when it is sent.';
  static const String custodyCheckNeedsPassword =
      'Your session has ended, so the consignment could not be checked. You '
      'can still record it; enter your password before you send it.';
  static const String chooseMineralFromRecord =
      'Choose the mineral written on the custody record.';

  // T4: the transporter's own weighing, place and save.
  static const String handoffLocationStep = 'Your location';
  static const String handoffWeightStep = 'Weight on your scale';
  static const String handoffWeightHint =
      'Weigh the bag and type what your own scale says.';
  static const String takeAnotherCustody = 'Take custody of another';

  // ---- Record purchase (buyer purchase plan, T2) ----
  // The page and its weighing words are Take custody's; these differ.

  /// Q4: this buyer already recorded buying the bag on this phone.
  static String alreadyBoughtHere(DateTime localTime) =>
      'You recorded buying this consignment on ${_dayAndTime(localTime)}.';

  /// Q2: the server holds this buyer's own accepted purchase.
  static String boughtByYou(DateTime localTime) =>
      'You bought this consignment on ${_dayAndTime(localTime)}.';

  static const String purchaseMismatch =
      'This record does not match the blockchain. Officers have been told, '
      'and the consignment is held. You can still record the purchase.';
  static const String purchaseUnderReview =
      'Under review: an officer is checking a problem with this '
      'consignment. You can still record the purchase.';
  static const String purchaseAlreadyBought =
      'The server says this consignment is already bought. A second '
      'purchase is flagged for an officer when it is sent.';

  /// Q3: a 404 for a buyer covers three cases the server keeps apart on
  /// purpose, so the sentence names all three.
  static const String purchaseNotOnServer =
      "The server does not show you this consignment yet. The transporter's "
      'handoff may not have been sent, or it may be under review or already '
      'sold. You can still record it; it is checked when it is sent.';
  static const String recordAnotherPurchase = 'Record another purchase';

  // Role differences (T5).
  static const String weighFirst =
      'Weigh it before you take custody: the weight is hidden until you '
      'record yours.';
  static const String stepsHiddenWhileHeld =
      'Its custody steps are hidden while an officer reviews it.';
  static String locationLine(String latitude, String longitude) =>
      'Location: $latitude, $longitude';

  /// Officers, on a mismatch: field NAMES only, as the server sends them.
  static String whatDiffers(String names) => 'What differs: $names';
  static String mismatchReason(String code) => 'Reason: $code';
  static const String reviewPassed = 'Passed the automatic checks';
  static const String reviewCleared = 'Cleared by an officer';
  static const String reviewFlagged = 'Flagged: waiting for an officer';
  static const String reviewRejected =
      'Rejected: an officer confirmed the problem';
  static String alertsLine(int total, int open) {
    if (total == 0) return 'No alerts';
    final count = total == 1 ? '1 alert' : '$total alerts';
    return '$count, $open open';
  }

  // ---- Officer alerts (officer alerts plan, T1: alert_words.dart) ----

  // The finding as a heading, one per alert type (plan §4).
  static const String alertDuplicate = 'QR code already registered';
  static const String alertQuantity = 'Weight differs by more than 10%';
  static const String alertGpsZone = 'Registered outside the licensed zones';
  static const String alertSignature = 'Signature does not match';
  static const String alertHandoffOrder = 'Recorded after the purchase';
  static const String alertTampered =
      'Record changed after it was put on the blockchain';
  static const String alertUnknown = 'Unknown alert';

  static const String severityHigh = 'High';
  static const String severityMedium = 'Medium';
  static const String severityLow = 'Low';

  /// Any alert whose details this version cannot read, and an unknown type.
  /// The decisions still work.
  static const String alertDetailsUnreadable =
      'This version of the app cannot show its details.';

  // quantity_discrepancy: "This handoff: 1.6 kg.", then one line per
  // baseline.
  static const String thisHandoff = 'This handoff';
  static const String thisPurchase = 'This purchase';
  static const String thisStep = 'This step';
  static const String theRegistration = 'The registration';
  static const String thePreviousStep = 'The previous step';
  static String stepWeighed(String step, String weight) => '$step: $weight.';

  /// "The registration: 2 kg. This handoff is 0.4 kg (20%) lighter." A
  /// baseline within the limit says so, for example ", within the 10%
  /// allowed".
  static String comparedWith({
    required String baseline,
    required String baselineWeight,
    required String step,
    required String difference,
    required String percent,
    required bool lighter,
    required bool exceeded,
    required int thresholdPercent,
  }) {
    final direction = lighter ? 'lighter' : 'heavier';
    final within = exceeded ? '' : ', within the $thresholdPercent% allowed';
    return '$baseline: $baselineWeight. $step is $difference ($percent) '
        '$direction$within.';
  }

  /// A baseline with exactly the step's weight.
  static String sameWeightAs(String baseline, String baselineWeight) =>
      '$baseline: $baselineWeight, the same weight.';

  /// A difference just over the limit that would read as the limit itself
  /// once cut to one decimal ("10%").
  static String moreThanPercent(int percent) => 'more than $percent%';

  // gps_zone.
  static String outsideZone(int metres, String zone, int tolerance) =>
      '$metres m outside $zone; $tolerance m is allowed.';
  static const String noZoneActive =
      'No licensed zone was active when it was registered.';

  // duplicate_consignment.
  static const String registeredBeforeSameMiner =
      'Registered before by the same miner.';
  static const String registeredBeforeOtherMiner =
      'Registered before by another miner.';
  static String mineralsDiffer(String now, String before) =>
      'This registration says $now; the first one said $before.';

  // invalid_signature.
  static String notThisDeviceKey(String shortFingerprint) =>
      "The signature was not made by this account's registered device key "
      '($shortFingerprint).';

  // handoff_order.
  static const String handoffAfterPurchase =
      'This handoff was recorded after the consignment was bought.';
  static const String purchaseAfterPurchase =
      'This purchase was recorded after the consignment was already bought.';

  // record_tampered: the names of what differs, in words.
  static const String fieldWeight = 'weight';
  static const String fieldMineral = 'mineral';
  static const String fieldLocation = 'location';
  static const String fieldTime = 'time';
  static const String fieldQrCode = 'QR code';
  static const String fieldPerson = 'person who signed';
  static const String fieldStepType = 'kind of step';
  static const String fieldStepId = 'step number';
  static const String fieldSignature = 'signature';
  static const String fieldSignedRecord = 'signed record';
  static const String fieldFingerprint = 'record fingerprint';
  static const String fieldReceipt = 'blockchain receipt';
  static const String fieldOther = 'other details';

  /// "The weight no longer matches the blockchain." / "The weight and
  /// location no longer match the blockchain."
  static String noLongerMatches(List<String> what) {
    final names = switch (what.length) {
      0 => '',
      1 => what.single,
      _ => '${what.sublist(0, what.length - 1).join(', ')} and ${what.last}',
    };
    if (names.isEmpty) {
      return 'Something in this record no longer matches the blockchain.';
    }
    final verb = what.length == 1 ? 'matches' : 'match';
    return 'The $names no longer $verb the blockchain.';
  }

  // ---- Officer alerts: the list (T2) ----

  // Q1: the three-way switch.
  static const String alertsOpen = 'Open';
  static const String alertsConfirmed = 'Confirmed';
  static const String alertsCleared = 'Cleared';
  static const String alertsShowing = 'Show alerts';

  static const String loadingAlerts = 'Loading alerts…';
  static const String noOpenAlerts = 'No open alerts.';
  static const String noConfirmedAlerts = 'No confirmed alerts yet.';
  static const String noClearedAlerts = 'No cleared alerts yet.';
  static const String alertsNeedPassword =
      'Your session has expired. Enter your password to see the alerts.';

  /// Above the list: "1 open alert.", "3 cleared alerts.", or, when only
  /// part is loaded, "Showing 20 of 45 alerts."
  static String alertsCount({
    required String status,
    required int shown,
    required int total,
  }) {
    if (shown < total) return 'Showing $shown of $total alerts.';
    return total == 1 ? '1 $status alert.' : '$total $status alerts.';
  }

  static const String statusOpen = 'open';
  static const String statusConfirmed = 'confirmed';
  static const String statusCleared = 'cleared';

  static const String stepRegistration = 'Registration';
  static const String stepHandoff = 'Handoff';
  static const String stepPurchase = 'Purchase';

  /// "MC-2026-LSK-0008, Copper".
  static String alertConsignment(String qrCode, String mineral) =>
      '$qrCode, $mineral';

  /// "Handoff by transporter patsani".
  static String stepByWhom(String step, String role, String username) =>
      '$step by $role $username';

  /// "Raised 20 Nov, 14:56", in the phone's own time.
  static String raisedAt(DateTime localTime) =>
      'Raised ${_dayAndTime(localTime)}';
  static const String holdsConsignment = 'Holds this consignment';

  /// A closed alert's decision: "Confirmed by officer_chanda, 20 Nov, 15:00".
  static String confirmedBy(String username, DateTime localTime) =>
      'Confirmed by $username, ${_dayAndTime(localTime)}';
  static String clearedBy(String username, DateTime localTime) =>
      'Cleared by $username, ${_dayAndTime(localTime)}';

  // ---- Officer alerts: one alert (T3) ----

  static const String alertTitle = 'Alert';
  static const String loadingAlert = 'Loading the alert…';
  static const String alertNeedsPassword =
      'Your session has expired. Enter your password to see this alert.';
  static const String alertGone =
      'This alert no longer exists. It may have been removed with its '
      'consignment.';
  static const String backToAlerts = 'Back to the alerts';

  static String severityLine(String severity) => 'Severity: $severity';
  static const String alertIsOpen = 'Open: waiting for a decision';
  static const String alertIsConfirmed = 'Confirmed: a real problem';
  static const String alertIsCleared = 'Cleared: no problem';

  static const String whatTheCheckFound = 'What the check found';
  static const String theStep = 'The step';
  static const String theConsignment = 'The consignment';
  static const String otherAlerts = 'Other alerts on this consignment';
  static const String theDecision = 'The decision';

  static String phoneTime(DateTime localTime) =>
      'Recorded on the phone: ${_dayAndTime(localTime)}';
  static String serverTime(DateTime localTime) =>
      'Received by the server: ${_dayAndTime(localTime)}';
  static String qrCodeLine(String qrCode) => 'QR code: $qrCode';
  static const String consignmentHeld =
      'Held: it is not put on the blockchain while an alert on it is open.';
  static const String consignmentNotHeld = 'Not held.';
  static const String noOtherAlerts = 'No other alerts.';

  /// "Open, raised 20 Nov, 14:56".
  static String otherAlertLine(String status, DateTime localTime) =>
      '$status, raised ${_dayAndTime(localTime)}';
  static const String otherStatusOpen = 'Open';
  static const String otherStatusConfirmed = 'Confirmed';
  static const String otherStatusCleared = 'Cleared';
  static const String anotherAlertHolds =
      'Clearing this alert does not release the consignment while another '
      'is open.';
  static String notesLine(String notes) => 'Notes: $notes';

  // ---- Officer alerts: the two decisions (T4) ----

  static const String confirmProblem = 'Confirm problem';
  static const String clearNoProblem = 'Clear, no problem';

  /// Q2: a handoff_order alert can only be confirmed.
  static const String onlyConfirm =
      'This step was recorded after the purchase, so it can only be '
      'confirmed.';

  static const String confirmQuestion = 'Confirm the problem?';
  static const String clearQuestion = 'Clear this alert?';
  static const String confirmExplains =
      'The step is rejected and never put on the blockchain. This cannot be '
      'undone.';
  static const String clearExplains =
      'The step is accepted and put on the blockchain like any other. This '
      'cannot be undone.';
  static const String decisionNotes = 'Notes';
  static const String decisionNotesHint =
      'For example: Weighed again at the depot, 1.6 kg confirmed';
  static const String decisionNotesWarning =
      'Kept for ever in the audit log. Do not add personal details.';
  static const String decisionNotesTooShort = 'Write at least 3 characters.';

  /// Q3: decisions are never queued.
  static const String decisionNotSent =
      'No network: the decision was not sent.';

  /// 404 or 409 INVALID_STATUS_TRANSITION: another officer decided first.
  static const String alertAlreadyDecided =
      'Another officer has already decided this alert. It has been read '
      'again.';

  // The message after a decision, from the server's answer.
  static const String confirmedDone = 'Confirmed.';
  static const String clearedDone = 'Cleared.';
  static const String stepNeverAnchored =
      'The step will never go on the blockchain.';
  static String noLongerHeld(String qrCode) => '$qrCode is no longer held.';
  static String stillHeld(String qrCode) =>
      '$qrCode is still held: another alert on it is open.';

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
  static const String alertNotFound =
      'This alert no longer exists. Refresh the list.';
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
