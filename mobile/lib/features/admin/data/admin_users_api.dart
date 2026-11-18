// The three admin endpoints the "Account requests" screen needs, as
// docs/api.md documents them:
//
//   GET  /admin/users?status=pending&limit=<1-100>&offset=<0-10000>
//     200 { "users": [admin view, ...], "total", "limit", "offset" }
//     Oldest request first. "total counts every account with that status,
//     not only this page."
//   POST /admin/users/{id}/approve     body: none, or {}
//     200 { "user": {admin view, "status": "active"} }
//   POST /admin/users/{id}/reject      body: { "reason": 3-500 characters }
//     200 { "user": {admin view, "status": "rejected"} }
//
// All three: admin only, no rate limit yet. Approve and reject refuse with
// VALIDATION_FAILED, FORBIDDEN, USER_NOT_FOUND (404), INVALID_STATUS_TRANSITION
// (409, "the account is not pending") or ROLE_NOT_APPROVABLE (409, an officer
// or administrator account), on top of the token errors.
//
// This file only turns the answers into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/account_request.dart';

class AdminUsersApi {
  AdminUsersApi(this._api);

  final ApiClient _api;

  /// The most requests asked for at once. The API allows up to 100; 20 keeps
  /// each answer small on a slow network, and "Show more" loads the next.
  static const int pageSize = 20;

  /// GET /admin/users for pending accounts, starting after [offset] of them.
  Future<AccountRequestsPage> pendingRequests({
    required String token,
    int offset = 0,
  }) async {
    final json = await _api.get(
      const ['admin', 'users'],
      // The API takes these as plain digits; Dart's int.toString() gives
      // exactly that.
      query: {'status': 'pending', 'limit': '$pageSize', 'offset': '$offset'},
      token: token,
    );
    if (json is! Map) throw const BadResponse(status: 200);
    final users = json['users'];
    final total = json['total'];
    if (users is! List || total is! int || total < 0) {
      throw const BadResponse(status: 200);
    }

    final requests = <AccountRequest>[];
    for (final user in users) {
      final request = AccountRequest.fromJson(user);
      // One unreadable row makes the whole answer unreadable, rather than
      // being skipped: a request silently missing from the list would never
      // be approved, and nobody would know why.
      if (request == null) throw const BadResponse(status: 200);
      requests.add(request);
    }
    return AccountRequestsPage(requests: requests, total: total);
  }

  /// POST /admin/users/{id}/approve, with no body.
  ///
  /// The answer's user is not checked further: a 200 means the account is
  /// now active, and calling that a failure because of an odd echo would make
  /// the administrator try again and get INVALID_STATUS_TRANSITION.
  Future<void> approve({required String token, required String id}) async {
    await _api.post(['admin', 'users', id, 'approve'], token: token);
  }

  /// POST /admin/users/{id}/reject with the reason.
  Future<void> reject({
    required String token,
    required String id,
    required String reason,
  }) async {
    await _api.post(
      ['admin', 'users', id, 'reject'],
      body: {'reason': reason},
      token: token,
    );
  }
}
