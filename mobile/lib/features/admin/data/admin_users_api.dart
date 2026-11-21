// The admin account endpoints, as docs/api.md documents them. First the
// three the "Account requests" screen needs:
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
// Then the "Accounts" screens' (admin accounts plan, T1):
//
//   GET  /admin/users?status=<active|suspended|invited|rejected|deleted>&...
//   POST /admin/users                         { username, fullName, role }
//     201 { "user": {...}, "activation": { "code", "expiresAt" } }
//   POST /admin/users/{id}/rename             { fullName }
//   POST /admin/users/{id}/suspend            { reason }
//   POST /admin/users/{id}/reactivate         none
//   POST /admin/users/{id}/reset-key          { reason }
//   POST /admin/users/{id}/activation-code    none
//     200 { "user": {...}, "activation": { "code", "expiresAt" } }
//   POST /admin/users/{id}/delete             { reason }
//
// Each action answers with the account's new admin view, which the account
// page then shows: there is no GET /admin/users/{id} to read it again.
//
// This file only turns the answers into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../../auth/domain/user.dart' show AccountStatus, Role;
import '../domain/account_request.dart';
import '../domain/admin_account.dart';

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

  // ---- Accounts (admin accounts plan) -----------------------------------

  /// GET /admin/users for accounts with [status], after [offset] of them.
  Future<AdminAccountsPage> accounts({
    required String token,
    required AccountStatus status,
    int offset = 0,
  }) async {
    final json = await _api.get(
      const ['admin', 'users'],
      query: {'status': status.name, 'limit': '$pageSize', 'offset': '$offset'},
      token: token,
    );
    if (json is! Map) throw const BadResponse(status: 200);
    final users = json['users'];
    final total = json['total'];
    if (users is! List || total is! int || total < 0) {
      throw const BadResponse(status: 200);
    }
    final accounts = <AdminAccount>[];
    for (final user in users) {
      // As for requests: an account silently missing from the list could
      // never be found, so one unreadable row makes the page unreadable.
      final account = AdminAccount.fromJson(user);
      if (account == null) throw const BadResponse(status: 200);
      accounts.add(account);
    }
    return AdminAccountsPage(accounts: accounts, total: total);
  }

  /// POST /admin/users: a new invited officer or administrator account.
  Future<InvitedAccount> create({
    required String token,
    required String username,
    required String fullName,
    required Role role,
  }) async {
    final json = await _api.post(
      const ['admin', 'users'],
      body: {'username': username, 'fullName': fullName, 'role': role.name},
      token: token,
    );
    return _invited(json, status: 201);
  }

  /// POST /admin/users/{id}/activation-code: a new code; the old one stops
  /// working.
  Future<InvitedAccount> newActivationCode({
    required String token,
    required String id,
  }) async {
    final json = await _api.post([
      'admin',
      'users',
      id,
      'activation-code',
    ], token: token);
    return _invited(json, status: 200);
  }

  /// POST /admin/users/{id}/rename.
  Future<AdminAccount> rename({
    required String token,
    required String id,
    required String fullName,
  }) => _action(token, id, 'rename', {'fullName': fullName});

  /// POST /admin/users/{id}/suspend.
  Future<AdminAccount> suspend({
    required String token,
    required String id,
    required String reason,
  }) => _action(token, id, 'suspend', {'reason': reason});

  /// POST /admin/users/{id}/reactivate, with no body.
  Future<AdminAccount> reactivate({
    required String token,
    required String id,
  }) => _action(token, id, 'reactivate', null);

  /// POST /admin/users/{id}/reset-key.
  Future<AdminAccount> resetKey({
    required String token,
    required String id,
    required String reason,
  }) => _action(token, id, 'reset-key', {'reason': reason});

  /// POST /admin/users/{id}/delete.
  Future<AdminAccount> delete({
    required String token,
    required String id,
    required String reason,
  }) => _action(token, id, 'delete', {'reason': reason});

  Future<AdminAccount> _action(
    String token,
    String id,
    String action,
    Map<String, String>? body,
  ) async {
    final json = await _api.post(
      ['admin', 'users', id, action],
      body: body,
      token: token,
    );
    // Unlike approve, the answer IS read: the page shows the account from
    // it. A 200 with an unreadable account is reported as an odd answer; the
    // change was made, and the list shows it when read again.
    final account = json is Map ? AdminAccount.fromJson(json['user']) : null;
    if (account == null) throw const BadResponse(status: 200);
    return account;
  }

  static InvitedAccount _invited(Object? json, {required int status}) {
    if (json is! Map) throw BadResponse(status: status);
    final account = AdminAccount.fromJson(json['user']);
    final activation = ActivationCode.fromJson(json['activation']);
    if (account == null || activation == null) {
      throw BadResponse(status: status);
    }
    return InvitedAccount(account: account, activation: activation);
  }
}
