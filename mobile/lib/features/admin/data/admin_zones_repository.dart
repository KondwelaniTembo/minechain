// The administrator's GPS zone actions, on top of AdminZonesApi (GPS zones
// plan, T1).
//
// Like AdminUsersRepository, it builds the API only when first needed (the
// pinned certificates load in the background) and turns a pinning set-up
// failure into InsecureConnection.
//
// Every call throws an AppFailure if refused. Names, licence numbers and
// reasons are sent trimmed: the server trims them too, but a reason is kept
// for ever in the audit log and a name in every report, so what is sent
// should be exactly what is meant.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../domain/gps_zone.dart';
import 'admin_zones_api.dart';

class AdminZonesRepository {
  AdminZonesRepository({required this._api});

  final Future<AdminZonesApi> Function() _api;

  /// One page of zones with [status], by name.
  Future<GpsZonesPage> zones({
    required String token,
    required ZoneStatus status,
    int offset = 0,
  }) async {
    final api = await _apiOrInsecure();
    return api.zones(token: token, status: status, offset: offset);
  }

  /// A new zone, active at once. A licence number that is empty after
  /// trimming is left out (the field is optional, and "" would be refused).
  Future<GpsZone> create({
    required String token,
    required String name,
    required String? licenceNumber,
    required List<ZoneCorner> boundary,
  }) async {
    final api = await _apiOrInsecure();
    final licence = licenceNumber?.trim();
    return api.create(
      token: token,
      name: name.trim(),
      licenceNumber: (licence == null || licence.isEmpty) ? null : licence,
      boundary: boundary,
    );
  }

  Future<GpsZone> rename({
    required String token,
    required String id,
    required String name,
  }) async {
    final api = await _apiOrInsecure();
    return api.rename(token: token, id: id, name: name.trim());
  }

  Future<ZoneDeactivated> deactivate({
    required String token,
    required String id,
    required String reason,
  }) async {
    final api = await _apiOrInsecure();
    return api.deactivate(token: token, id: id, reason: reason.trim());
  }

  Future<GpsZone> reactivate({
    required String token,
    required String id,
  }) async {
    final api = await _apiOrInsecure();
    return api.reactivate(token: token, id: id);
  }

  Future<AdminZonesApi> _apiOrInsecure() async {
    try {
      return await _api();
    } on PinningSetupError {
      throw const InsecureConnection();
    }
  }
}

final adminZonesRepositoryProvider = Provider<AdminZonesRepository>((ref) {
  return AdminZonesRepository(
    api: () async => AdminZonesApi(await ref.read(apiClientProvider.future)),
  );
});
