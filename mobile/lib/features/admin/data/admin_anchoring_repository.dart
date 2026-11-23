// The administrator's anchoring status, on top of AdminAnchoringApi
// (anchoring status plan, T2).
//
// Like AdminZonesRepository, it builds the API only when first needed (the
// pinned certificates load in the background) and turns a pinning set-up
// failure into InsecureConnection. It throws an AppFailure if refused.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/anchoring_status.dart';
import 'admin_anchoring_api.dart';

class AdminAnchoringRepository {
  AdminAnchoringRepository({required this._api});

  final Future<AdminAnchoringApi> Function() _api;

  Future<AnchoringStatus> status({required String token}) async {
    final AdminAnchoringApi api;
    try {
      api = await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
    return api.status(token: token);
  }
}

final adminAnchoringRepositoryProvider = Provider<AdminAnchoringRepository>((
  ref,
) {
  return AdminAnchoringRepository(
    api: () async =>
        AdminAnchoringApi(await ref.read(apiClientProvider.future)),
  );
});
