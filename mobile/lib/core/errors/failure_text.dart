// Turns an AppFailure into one plain sentence for the screen (plan section 3.2,
// step 3).
//
// The order, for a ServerRefused:
//   1. our own sentence, for the codes the app handles now;
//   2. otherwise the server's message (api.md promises it is plain language
//      and safe to show);
//   3. otherwise, if the server sent no message, a fixed sentence.
// The other four failure types always get their own fixed sentence.
//
// This only chooses words. What the app DOES about a failure (log out, ask for
// the password, offer "Try again") is decided elsewhere, from the code, by the
// controllers built in F6-F8.

import '../text/app_text.dart';
import 'api_codes.dart';
import 'app_failure.dart';

/// The sentence to show the user for [failure].
String failureText(AppFailure failure) {
  // A switch over a sealed type must handle every subtype; the compiler
  // checks it. The `ServerRefused(:final code, ...)` pattern reads those
  // fields out of the object into local variables of the same name.
  return switch (failure) {
    ServerRefused(:final code, :final serverMessage) =>
      _ourTextFor(code) ??
          (serverMessage.trim().isNotEmpty
              ? serverMessage
              : AppText.somethingWentWrong),
    NoConnection() => AppText.noConnection,
    TimedOut() => AppText.timedOut,
    InsecureConnection() => AppText.insecureConnection,
    BadResponse() => AppText.badResponse,
  };
}

/// Our own sentence for a code the app handles now, or null for any other.
///
/// These are the login and session codes of plan section 4.3, plus
/// TOO_MANY_REQUESTS and VALIDATION_FAILED, and (F9) WEAK_PASSWORD and
/// ACTIVATION_INVALID. More are added as screens need them; until then the
/// server's own message is used.
String? _ourTextFor(String code) {
  return switch (code) {
    ApiCodes.invalidCredentials => AppText.invalidCredentials,
    ApiCodes.tokenMissing || ApiCodes.tokenInvalid => AppText.sessionNotValid,
    ApiCodes.tokenExpired => AppText.sessionExpired,
    ApiCodes.accountPending => AppText.accountPending,
    ApiCodes.accountSuspended => AppText.accountSuspended,
    ApiCodes.accountRejected => AppText.accountRejected,
    ApiCodes.accountNotActive => AppText.accountNotActive,
    ApiCodes.forbidden => AppText.notAllowed,
    ApiCodes.tooManyRequests => AppText.tooManyTries,
    ApiCodes.validationFailed => AppText.checkTheForm,
    // F9: the register and activate forms.
    ApiCodes.weakPassword => AppText.weakPassword,
    ApiCodes.activationInvalid => AppText.activationInvalid,
    // Officer alerts. STEP_CANNOT_BE_CLEARED is left to the server's
    // message on purpose: it names which of the three cases this is.
    ApiCodes.alertNotFound => AppText.alertNotFound,
    // Admin accounts. INVALID_STATUS_TRANSITION and LAST_ACTIVE_ADMIN are
    // left to the server's message: it names the account's actual status.
    // USERNAME_TAKEN goes under the username field on the forms that send
    // one, so it is not here.
    ApiCodes.userNotFound => AppText.accountNotFound,
    ApiCodes.cannotSuspendSelf => AppText.cannotSuspendSelf,
    ApiCodes.cannotDeleteSelf => AppText.cannotDeleteSelf,
    ApiCodes.noPublicKey => AppText.noDeviceKeyToReset,
    // GPS zones. ZONE_NAME_TAKEN goes under the name field on the forms
    // that send one (its server sentence explains that inactive zones keep
    // their names), so it is not here; INVALID_STATUS_TRANSITION keeps the
    // server's sentence, as for accounts.
    ApiCodes.zoneNotFound => AppText.zoneNotFound,
    // Reports. TOO_MANY_REQUESTS, USER_NOT_FOUND and CONSIGNMENT_NOT_FOUND
    // get report words in reports/presentation (reportFailureText): the
    // shared sentences are about login tries and the admin's lists.
    ApiCodes.reportTooLarge => AppText.reportTooLarge,
    _ => null,
  };
}
