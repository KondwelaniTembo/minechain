// The administrator's account actions, on top of AdminUsersApi.
//
// Like AuthRepository, it builds the API only when first needed (the pinned
// certificates load in the background) and turns a pinning set-up failure
// into InsecureConnection, so a missing certificate never looks like a crash.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/account_request.dart';
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
