// A one-way signal from the network layer: "the server refused this user's
// session" (plan section 4.3).
//
// Why it exists: when the server answers a request that carried a token with,
// say, 401 TOKEN_EXPIRED, the app must react (log out, or ask for the password
// again). That decision belongs to auth (F6-F8), but the refusal is seen in
// ApiClient. If ApiClient called auth directly, the network layer would depend
// on a feature, and every test of the network would drag auth in. Instead
// ApiClient only announces the code here, and auth listens. Network knows
// nothing about auth; auth knows about network. Dependencies point one way.

import 'dart:async';

import '../errors/api_codes.dart';

/// Announces session refusals as their error codes.
class SessionEvents {
  // A broadcast stream can have any number of listeners (or none). An event
  // with no listener is simply dropped, which is right: nothing is waiting.
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// The codes of refusals that end or suspend the session, as they happen.
  Stream<String> get refusals => _controller.stream;

  // Which answers mean "this session is over", by HTTP status. 403 FORBIDDEN
  // is deliberately NOT here: it means the account is fine but this role may
  // not do this, which is an app bug to show, not a reason to log out.
  static const Map<int, Set<String>> _sessionEnding = {
    401: {
      ApiCodes.tokenExpired,
      ApiCodes.tokenInvalid,
      ApiCodes.tokenMissing,
    },
    403: {
      ApiCodes.accountPending,
      ApiCodes.accountSuspended,
      ApiCodes.accountRejected,
      ApiCodes.accountNotActive,
    },
  };

  /// Whether an answer with [status] and [code] ends the session. Only
  /// meaningful for a request that carried a token; ApiClient checks that.
  static bool endsSession(int status, String code) =>
      _sessionEnding[status]?.contains(code) ?? false;

  /// Announces [code]. Does nothing after [dispose].
  void report(String code) {
    if (!_controller.isClosed) _controller.add(code);
  }

  void dispose() => _controller.close();
}
