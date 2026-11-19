// The consignment check, on top of ConsignmentCheckApi.
//
// Like AdminUsersRepository, it builds the API only when first needed (the
// pinned certificates load in the background) and turns a pinning set-up
// failure into InsecureConnection, so a missing certificate never looks like
// a crash.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/consignment_view.dart';
import 'consignment_check_api.dart';

class ConsignmentCheckRepository {
  ConsignmentCheckRepository({required this._api});

  final Future<ConsignmentCheckApi> Function() _api;

  /// The consignment with [qrCode], as this viewer may see it, with the
  /// server's chain check of each step. Throws an AppFailure.
  Future<ConsignmentView> check({
    required String token,
    required String qrCode,
  }) async {
    final ConsignmentCheckApi api;
    try {
      api = await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
    return api.byQr(token: token, qrCode: qrCode);
  }
}

final consignmentCheckRepositoryProvider = Provider<ConsignmentCheckRepository>(
  (ref) => ConsignmentCheckRepository(
    api: () async =>
        ConsignmentCheckApi(await ref.read(apiClientProvider.future)),
  ),
);
