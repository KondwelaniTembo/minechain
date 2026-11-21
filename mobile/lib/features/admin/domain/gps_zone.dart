// One licensed extraction zone as the administrator's "GPS zones" screens
// show it (GPS zones plan, T1), read from the API's zone view (docs/api.md,
// "GPS zone management (FR-11)", "The zone view"):
//
//   id, name, licenceNumber, status, boundary, createdBy, createdAt,
//   updatedAt
//
// `createdBy` (an administrator's id) is not shown, so it is not kept.
//
// The boundary is a list of corners, each `[latitude, longitude]`, latitude
// first, as JSON numbers. Zones are not signed, so the numbers are kept as
// doubles: the "values stay as text" rule is for signed payloads, and a
// double holds a 6-decimal value exactly enough to send it back unchanged
// (Dart writes the shortest text that reads back as the same double).
//
// Plain Dart, no Flutter.

/// Whether sync checks registrations against the zone.
enum ZoneStatus { active, inactive }

/// One corner of a boundary.
class ZoneCorner {
  const ZoneCorner(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// `[latitude, longitude]`, the API's order.
  List<double> toJson() => [latitude, longitude];

  @override
  bool operator ==(Object other) =>
      other is ZoneCorner &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  // No coordinates: a place in a log line is evidence of where someone
  // works.
  @override
  String toString() => 'ZoneCorner(hidden)';
}

class GpsZone {
  const GpsZone({
    required this.id,
    required this.name,
    required this.licenceNumber,
    required this.status,
    required this.boundary,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// Null when none was given (an empty one is read as none).
  final String? licenceNumber;
  final ZoneStatus status;

  /// The corners in the order they were created, never closed (the last is
  /// not the first again).
  final List<ZoneCorner> boundary;

  /// In UTC.
  final DateTime createdAt;

  /// When it last changed (a rename or a status change), in UTC.
  final DateTime updatedAt;

  bool get isActive => status == ZoneStatus.active;

  GpsZone copyWith({String? name, ZoneStatus? status}) => GpsZone(
    id: id,
    name: name ?? this.name,
    licenceNumber: licenceNumber,
    status: status ?? this.status,
    boundary: boundary,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  /// Reads one zone, or null if a field is missing, has the wrong type, the
  /// status is not one this app knows, or a corner is not two numbers.
  ///
  /// Never guesses, like AdminAccount.fromJson. Extra fields are ignored.
  static GpsZone? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    for (final value in [id, name, status, createdAt, updatedAt]) {
      if (value is! String || value.isEmpty) return null;
    }
    final licenceJson = json['licenceNumber'];
    if (licenceJson != null && licenceJson is! String) return null;
    final licence = licenceJson as String?;

    final parsedStatus = switch (status) {
      'active' => ZoneStatus.active,
      'inactive' => ZoneStatus.inactive,
      _ => null,
    };
    if (parsedStatus == null) return null;

    final boundary = _corners(json['boundary']);
    if (boundary == null) return null;

    final created = DateTime.tryParse(createdAt as String);
    final updated = DateTime.tryParse(updatedAt as String);
    if (created == null || updated == null) return null;

    return GpsZone(
      id: id as String,
      name: name as String,
      licenceNumber: (licence == null || licence.isEmpty) ? null : licence,
      status: parsedStatus,
      boundary: boundary,
      createdAt: created.toUtc(),
      updatedAt: updated.toUtc(),
    );
  }

  /// The corners, or null if the list is not 3 or more pairs of numbers.
  static List<ZoneCorner>? _corners(Object? json) {
    if (json is! List || json.length < 3) return null;
    final corners = <ZoneCorner>[];
    for (final pair in json) {
      if (pair is! List || pair.length != 2) return null;
      final [lat, lng] = pair;
      if (lat is! num || lng is! num) return null;
      corners.add(ZoneCorner(lat.toDouble(), lng.toDouble()));
    }
    return corners;
  }

  // Only the status and how many corners: a zone's name, licence number and
  // corners say where a licensed site is.
  @override
  String toString() =>
      'GpsZone(status: ${status.name}, corners: ${boundary.length})';
}

/// One page of zones with one status.
class GpsZonesPage {
  const GpsZonesPage({required this.zones, required this.total});

  final List<GpsZone> zones;

  /// How many zones have this status in all, not only on this page.
  final int total;

  @override
  String toString() => 'GpsZonesPage(zones: ${zones.length}, total: $total)';
}

/// The warning a deactivation can carry (api.md, "No active zones left").
///
/// [message] is the server's sentence, or null if the warning came without a
/// readable one: the warning is still shown, in the app's own words, because
/// it must never be missed.
class ZoneWarning {
  const ZoneWarning({required this.code, required this.message});

  final String? code;
  final String? message;

  /// Null for `warning: null` (or absent); otherwise a warning, readable or
  /// not.
  static ZoneWarning? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) return const ZoneWarning(code: null, message: null);
    final code = json['code'];
    final message = json['message'];
    return ZoneWarning(
      code: code is String ? code : null,
      message: message is String && message.trim().isNotEmpty ? message : null,
    );
  }

  @override
  String toString() => 'ZoneWarning(code: $code)';
}

/// The answer to a deactivation: the zone, now inactive, and the warning
/// when it was the last active one.
class ZoneDeactivated {
  const ZoneDeactivated({required this.zone, required this.warning});

  final GpsZone zone;
  final ZoneWarning? warning;

  @override
  String toString() => 'ZoneDeactivated($zone, warning: $warning)';
}
