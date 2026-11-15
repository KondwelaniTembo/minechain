// The codes the API sends, copied from docs/api.md, as constants.
//
// Why constants: the app branches on codes (plan section 3.2), and a code typed
// as a string in several places can be mistyped in one of them without anyone
// noticing. `ApiCodes.tokenExpired` mistyped is a compile error instead.
// test/core/errors/api_codes_test.dart checks that every value here is really
// in docs/api.md, and that every HTTP error code in api.md's tables is here.
//
// Most are `error.code` values in an error answer. Some groups at the end are
// codes inside successful answers (sync results, warnings, anchoring status);
// they are listed so that later modules find every code in one place.
//
// Each constant is named after its code, in Dart's lowerCamelCase.
// Left out on purpose: HTTP methods, environment variable names and contract
// role names, which api.md also writes in capitals but which are not codes.

/// Codes from docs/api.md.
abstract final class ApiCodes {
  // ---- Any endpoint (api.md "Error format") ----
  static const String invalidJson = 'INVALID_JSON';
  static const String validationFailed = 'VALIDATION_FAILED';
  static const String notFound = 'NOT_FOUND';
  static const String payloadTooLarge = 'PAYLOAD_TOO_LARGE';
  static const String tooManyRequests = 'TOO_MANY_REQUESTS';
  static const String internalError = 'INTERNAL_ERROR';

  // ---- Token and account checks on every protected endpoint
  //      (api.md "Authentication") ----
  static const String tokenMissing = 'TOKEN_MISSING';
  static const String tokenInvalid = 'TOKEN_INVALID';
  static const String tokenExpired = 'TOKEN_EXPIRED';
  static const String accountPending = 'ACCOUNT_PENDING';
  static const String accountSuspended = 'ACCOUNT_SUSPENDED';
  static const String accountRejected = 'ACCOUNT_REJECTED';
  static const String accountNotActivated = 'ACCOUNT_NOT_ACTIVATED';
  static const String accountNotActive = 'ACCOUNT_NOT_ACTIVE';
  static const String forbidden = 'FORBIDDEN';

  // ---- POST /auth/login ----
  static const String invalidCredentials = 'INVALID_CREDENTIALS';

  // ---- POST /auth/register (also /auth/activate, /auth/me/password) ----
  static const String weakPassword = 'WEAK_PASSWORD';
  static const String usernameTaken = 'USERNAME_TAKEN';

  // ---- POST /auth/activate ----
  static const String activationInvalid = 'ACTIVATION_INVALID';

  // ---- POST /auth/me/password ----
  static const String currentPasswordIncorrect = 'CURRENT_PASSWORD_INCORRECT';
  static const String passwordUnchanged = 'PASSWORD_UNCHANGED';

  // ---- PUT /auth/me/public-key ----
  static const String invalidPublicKey = 'INVALID_PUBLIC_KEY';
  static const String publicKeyAlreadyRegistered =
      'PUBLIC_KEY_ALREADY_REGISTERED';
  static const String publicKeyInUse = 'PUBLIC_KEY_IN_USE';

  // ---- Admin account management (/admin/users) ----
  static const String userNotFound = 'USER_NOT_FOUND';
  static const String invalidStatusTransition = 'INVALID_STATUS_TRANSITION';
  static const String cannotSuspendSelf = 'CANNOT_SUSPEND_SELF';
  static const String cannotDeleteSelf = 'CANNOT_DELETE_SELF';
  static const String lastActiveAdmin = 'LAST_ACTIVE_ADMIN';
  static const String roleNotApprovable = 'ROLE_NOT_APPROVABLE';
  static const String roleNotCreatable = 'ROLE_NOT_CREATABLE';
  static const String noPublicKey = 'NO_PUBLIC_KEY';

  // ---- GPS zone management (/admin/zones) ----
  static const String zoneNotFound = 'ZONE_NOT_FOUND';
  static const String zoneNameTaken = 'ZONE_NAME_TAKEN';

  // ---- Anchoring administration (/admin/anchoring) ----
  static const String stepNotFound = 'STEP_NOT_FOUND';
  static const String anchorNotRetryable = 'ANCHOR_NOT_RETRYABLE';
  static const String anchoringDisabled = 'ANCHORING_DISABLED';
  static const String anchoringNotStarted = 'ANCHORING_NOT_STARTED';
  static const String anchoringStopped = 'ANCHORING_STOPPED';
  static const String anchoringBusy = 'ANCHORING_BUSY';

  // ---- Alerts (/alerts) ----
  static const String alertNotFound = 'ALERT_NOT_FOUND';
  static const String stepCannotBeCleared = 'STEP_CANNOT_BE_CLEARED';

  // ---- GET /consignments/by-qr/{qrCode}
  //      (also a sync step code, "deferred": the registration has not
  //      arrived yet) ----
  static const String consignmentNotFound = 'CONSIGNMENT_NOT_FOUND';

  // ---- Reports (/reports) ----
  static const String reportTooLarge = 'REPORT_TOO_LARGE';

  // ===== Codes inside successful answers =====

  // ---- WEAK_PASSWORD details: `details[].code` ----
  static const String passwordTooShort = 'PASSWORD_TOO_SHORT';
  static const String passwordTooLong = 'PASSWORD_TOO_LONG';
  static const String passwordRepeated = 'PASSWORD_REPEATED';
  static const String passwordContainsUsername = 'PASSWORD_CONTAINS_USERNAME';
  static const String passwordTooCommon = 'PASSWORD_TOO_COMMON';

  // ---- POST /sync/steps: the per-step result code (api.md "Codes") ----
  // flagged: stored, under review
  static const String invalidSignature = 'INVALID_SIGNATURE';
  static const String duplicateConsignment = 'DUPLICATE_CONSIGNMENT';
  static const String handoffOrder = 'HANDOFF_ORDER';
  static const String quantityDiscrepancy = 'QUANTITY_DISCREPANCY';
  static const String gpsZone = 'GPS_ZONE';
  // rejected: not stored
  static const String payloadMalformed = 'PAYLOAD_MALFORMED';
  static const String payloadUnsupportedVersion = 'PAYLOAD_UNSUPPORTED_VERSION';
  static const String signatureMalformed = 'SIGNATURE_MALFORMED';
  static const String actorMismatch = 'ACTOR_MISMATCH';
  static const String stepNotAllowedForRole = 'STEP_NOT_ALLOWED_FOR_ROLE';
  static const String stepIdConflict = 'STEP_ID_CONFLICT';
  // deferred: send again later (CONSIGNMENT_NOT_FOUND is above)
  static const String noDeviceKey = 'NO_DEVICE_KEY';
  static const String stageNotReady = 'STAGE_NOT_READY';

  // ---- POST /admin/zones/{id}/deactivate: warning in a 200 answer ----
  static const String noActiveZones = 'NO_ACTIVE_ZONES';

  // ---- GET /admin/anchoring: `problems[].code` ----
  static const String workerDisabled = 'WORKER_DISABLED';
  static const String workerNotStarted = 'WORKER_NOT_STARTED';
  static const String workerStopped = 'WORKER_STOPPED';
  static const String workerBackoff = 'WORKER_BACKOFF';
  static const String workerPaused = 'WORKER_PAUSED';
  static const String stuckSubmitted = 'STUCK_SUBMITTED';
  static const String failedSteps = 'FAILED_STEPS';
  static const String noRecentTick = 'NO_RECENT_TICK';

  // ---- GET /admin/anchoring: a failed step's `anchor_error` code, and a
  //      stuck step's last refusal. Some carry a detail after a colon, for
  //      example INVALID_STAGE:None; these constants are the part before it ----
  static const String anchorErrorUnknown = 'UNKNOWN';
  static const String maxAttempts = 'MAX_ATTEMPTS';
  static const String invalidStage = 'INVALID_STAGE';
  static const String invalidInput = 'INVALID_INPUT';
  static const String stepTypeUnknown = 'STEP_TYPE_UNKNOWN';
  static const String bytes32Invalid = 'BYTES32_INVALID';
  static const String weightInvalid = 'WEIGHT_INVALID';
  static const String idAlreadyAnchored = 'ID_ALREADY_ANCHORED';
  static const String receiptMismatch = 'RECEIPT_MISMATCH';
  static const String feeTooHigh = 'FEE_TOO_HIGH';
  static const String insufficientFunds = 'INSUFFICIENT_FUNDS';
}
