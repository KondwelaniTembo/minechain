// The administrator's account actions, on top of AdminUsersApi.
//
// Like AuthRepository, it builds the API only when first needed (the pinned
// certificates load in the background) and turns a pinning set-up failure
// into InsecureConnection, so a missing certificate never looks like a crash.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../../auth/domain/user.dart' show AccountStatus, Role;
import '../domain/account_request.dart';
import '../domain/admin_account.dart';
import 'admin_users_api.dart';

class AdminUsersRepository {
  AdminUsersRepository({required this._api});

  final Future<AdminUsersApi> Function() _api;

  /// One page of pending requests, oldest first. Throws an AppFailure.
  Future<AccountRequestsPage> pendingRequests({
    required String token,
    int offset = 0,
  }) async {
    final api = await _apiOrInsecure();
    return api.pendingRequests(token: token, offset: offset);
  }

  /// Approves the request [id]. Throws an AppFailure if refused.
  Future<void> approve({required String token, required String id}) async {
    final api = await _apiOrInsecure();
    await api.approve(token: token, id: id);
  }

  /// Rejects the request [id] with [reason]. Throws an AppFailure if refused.
  ///
  /// The reason is sent trimmed. The server trims it too, but it is kept for
  /// ever in the audit log, so what is sent should be exactly what is meant.
  Future<void> reject({
    required String token,
    required String id,
    required String reason,
  }) async {
    final api = await _apiOrInsecure();
    await api.reject(token: token, id: id, reason: reason.trim());
  }

  // ---- Accounts (admin accounts plan) -----------------------------------
  //
  // Every action throws an AppFailure if refused. Names and reasons are sent
  // trimmed: the server trims them too, but a reason is kept for ever in the
  // audit log, so what is sent should be exactly what is meant.

  /// One page of accounts with [status], oldest first.
  Future<AdminAccountsPage> accounts({
    required String token,
    required AccountStatus status,
    int offset = 0,
  }) async {
    final api = await _apiOrInsecure();
    return api.accounts(token: token, status: status, offset: offset);
  }

  /// A new invited officer or administrator account, with its code.
  Future<InvitedAccount> create({
    required String token,
    required String username,
    required String fullName,
    required Role role,
  }) async {
    final api = await _apiOrInsecure();
    return api.create(
      token: token,
      username: username.trim(),
      fullName: fullName.trim(),
      role: role,
    );
  }

  /// A new code for the invited account [id]; the old one stops working.
  Future<InvitedAccount> newActivationCode({
    required String token,
    required String id,
  }) async {
    final api = await _apiOrInsecure();
    return api.newActivationCode(token: token, id: id);
  }

  Future<AdminAccount> rename({
    required String token,
    required String id,
    required String fullName,
  }) async {
    final api = await _apiOrInsecure();
    return api.rename(token: token, id: id, fullName: fullName.trim());
  }

  Future<AdminAccount> suspend({
    required String token,
    required String id,
    required String reason,
  }) async {
    final api = await _apiOrInsecure();
    return api.suspend(token: token, id: id, reason: reason.trim());
  }

  Future<AdminAccount> reactivate({
    required String token,
    required String id,
  }) async {
    final api = await _apiOrInsecure();
    return api.reactivate(token: token, id: id);
  }

  Future<AdminAccount> resetKey({
    required String token,
    required String id,
    required String reason,
  }) async {
    final api = await _apiOrInsecure();
    return api.resetKey(token: token, id: id, reason: reason.trim());
  }

  Future<AdminAccount> delete({
    required String token,
    required String id,
    required String reason,
  }) async {
    final api = await _apiOrInsecure();
    return api.delete(token: token, id: id, reason: reason.trim());
  }

  Future<AdminUsersApi> _apiOrInsecure() async {
    try {
      return await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
  }
}

final adminUsersRepositoryProvider = Provider<AdminUsersRepository>((ref) {
  return AdminUsersRepository(
    api: () async => AdminUsersApi(await ref.read(apiClientProvider.future)),
  );
});
