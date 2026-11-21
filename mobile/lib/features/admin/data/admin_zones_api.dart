// The GPS zone endpoints, as docs/api.md ("GPS zone management (FR-11)")
// documents them (GPS zones plan, T1):
//
//   GET  /admin/zones?status=<active|inactive>&limit=<1-100>&offset=<0-10000>
//     200 { "zones": [zone view, ...], "total", "limit", "offset" }
//     By name, ignoring letter case.
//   POST /admin/zones                    { name, licenceNumber?, boundary }
//     201 { "zone": {...} }               active at once
//   POST /admin/zones/{id}/rename        { name }
//     200 { "zone": {...} }
//   POST /admin/zones/{id}/deactivate    { reason }
//     200 { "zone": {...}, "warning": null | { "code", "message" } }
//   POST /admin/zones/{id}/reactivate    none
//     200 { "zone": {...} }
//
// All five: admin only, no rate limit yet. Refusals: VALIDATION_FAILED (with
// field paths such as `boundary.3`), FORBIDDEN, ZONE_NOT_FOUND (404),
// ZONE_NAME_TAKEN (409), INVALID_STATUS_TRANSITION (409), on top of the token
// errors.
//
// Each action answers with the zone's new view, which the zone page then
// shows: there is no GET /admin/zones/{id} to read it again.
//
// This file only turns the answers into Dart values.

import '../../../core/errors/app_failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/gps_zone.dart';

class AdminZonesApi {
  AdminZonesApi(this._api);

  final ApiClient _api;

  /// The same page size as the accounts lists: small answers on a slow
  /// network, and "Show more" for the next.
  static const int pageSize = 20;

  /// GET /admin/zones for zones with [status], after [offset] of them.
  Future<GpsZonesPage> zones({
    required String token,
    required ZoneStatus status,
    int offset = 0,
  }) async {
    final json = await _api.get(
      const ['admin', 'zones'],
      query: {'status': status.name, 'limit': '$pageSize', 'offset': '$offset'},
      token: token,
    );
    if (json is! Map) throw const BadResponse(status: 200);
    final zones = json['zones'];
    final total = json['total'];
    if (zones is! List || total is! int || total < 0) {
      throw const BadResponse(status: 200);
    }
    final page = <GpsZone>[];
    for (final row in zones) {
      // As for accounts: a zone silently missing from the list could never
      // be renamed or deactivated, so one unreadable row makes the page
      // unreadable.
      final zone = GpsZone.fromJson(row);
      if (zone == null) throw const BadResponse(status: 200);
      page.add(zone);
    }
    return GpsZonesPage(zones: page, total: total);
  }

  /// POST /admin/zones. [licenceNumber] null leaves the field out.
  Future<GpsZone> create({
    required String token,
    required String name,
    required String? licenceNumber,
    required List<ZoneCorner> boundary,
  }) async {
    final json = await _api.post(
      const ['admin', 'zones'],
      body: {
        'name': name,
        'licenceNumber': ?licenceNumber,
        'boundary': [for (final corner in boundary) corner.toJson()],
      },
      token: token,
    );
    return _zone(json, status: 201);
  }

  /// POST /admin/zones/{id}/rename.
  Future<GpsZone> rename({
    required String token,
    required String id,
    required String name,
  }) async {
    final json = await _api.post(
      ['admin', 'zones', id, 'rename'],
      body: {'name': name},
      token: token,
    );
    return _zone(json, status: 200);
  }

  /// POST /admin/zones/{id}/deactivate.
  Future<ZoneDeactivated> deactivate({
    required String token,
    required String id,
    required String reason,
  }) async {
    final json = await _api.post(
      ['admin', 'zones', id, 'deactivate'],
      body: {'reason': reason},
      token: token,
    );
    final zone = _zone(json, status: 200);
    return ZoneDeactivated(
      zone: zone,
      warning: ZoneWarning.fromJson((json as Map)['warning']),
    );
  }

  /// POST /admin/zones/{id}/reactivate, with no body.
  Future<GpsZone> reactivate({
    required String token,
    required String id,
  }) async {
    final json = await _api.post([
      'admin',
      'zones',
      id,
      'reactivate',
    ], token: token);
    return _zone(json, status: 200);
  }

  // The answer IS read: the page shows the zone from it. A success with an
  // unreadable zone is reported as an odd answer; the change was made, and
  // the list shows it when read again.
  static GpsZone _zone(Object? json, {required int status}) {
    final zone = json is Map ? GpsZone.fromJson(json['zone']) : null;
    if (zone == null) throw BadResponse(status: status);
    return zone;
  }
}
