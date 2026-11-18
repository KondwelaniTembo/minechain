// Every way a request to the API can fail, as a small, fixed set of types
// (plan section 3.2).
//
// Why one set: screens and controllers should not have to know about sockets,
// TLS, HTTP status codes or JSON. The API client (F5) turns whatever went wrong
// into exactly one of these, and everything above it only ever sees these.
//
// Why sealed: no other kind of AppFailure can exist outside this file, so a
// `switch` that handles all five is complete. If a sixth is ever added, every
// switch that forgot it stops compiling, instead of silently doing nothing.
//
// SECURITY: none of these holds a request body, a token or a response body,
// and toString() prints only status codes, error codes and counts. Failures end
// up in logs and crash reports; those must never contain a password, a token or
// someone's details.
//
// Plain Dart only: no Flutter imports, so these can be used and tested
// anywhere.

/// Something went wrong talking to the API.
sealed class AppFailure implements Exception {
  const AppFailure();
}

/// The server answered with its error format, `{ error: { code, message } }`.
///
/// The app decides what to do from [code] only, never from [serverMessage]:
/// codes are stable, messages may be reworded at any time.
final class ServerRefused extends AppFailure {
  const ServerRefused({
    required this.status,
    required this.code,
    required this.serverMessage,
    this.details = const [],
    this.retryAfter,
  });

  /// From a `Retry-After` header in whole seconds, sent with 429
  /// `TOO_MANY_REQUESTS` (api.md, rate limits). Null when absent or not a
  /// whole number of seconds.
  final Duration? retryAfter;

  /// The HTTP status, for example 401.
  final int status;

  /// The stable error code, for example `INVALID_CREDENTIALS` (see ApiCodes).
  final String code;

  /// The server's plain-language message. Safe to show to the user, but never
  /// used to decide anything.
  final String serverMessage;

  /// Per-field problems, sent only with a few codes (for example
  /// `VALIDATION_FAILED` and `WEAK_PASSWORD`), so a form can show each message
  /// under its field. Empty otherwise.
  final List<FieldProblem> details;

  // Only the status, the code and how many details there are. The message and
  // the details' text are left out: they come from the response body.
  @override
  String toString() =>
      'ServerRefused(status: $status, code: $code, details: ${details.length})';
}

/// One entry of an error's `details` list.
class FieldProblem {
  const FieldProblem({required this.field, required this.message, this.code});

  /// The request field the problem is about, for example `password`, or
  /// `body` for the request as a whole.
  final String field;

  /// Plain-language text for the user.
  final String message;

  /// Set only for password problems, for example `PASSWORD_TOO_SHORT`.
  final String? code;

  @override
  String toString() => 'FieldProblem(field: $field, code: $code)';
}

/// No connection could be made: no network, the name could not be looked up,
/// or the connection was refused.
final class NoConnection extends AppFailure {
  const NoConnection();

  @override
  String toString() => 'NoConnection()';
}

/// The server did not answer within the time limit.
final class TimedOut extends AppFailure {
  const TimedOut();

  @override
  String toString() => 'TimedOut()';
}

/// The secure connection was refused: the server's certificate chain does not
/// end at one of the pinned roots, or it could not do TLS 1.3. This may mean
/// someone is intercepting the connection, so it is never treated like an
/// ordinary network problem.
final class InsecureConnection extends AppFailure {
  const InsecureConnection();

  @override
  String toString() => 'InsecureConnection()';
}

/// The server answered, but not in its error format and not with what was
/// expected: an HTML page from Cloudflare, an empty body, broken JSON.
final class BadResponse extends AppFailure {
  const BadResponse({required this.status});

  /// The HTTP status of the answer, for example 502.
  final int status;

  @override
  String toString() => 'BadResponse(status: $status)';
}
