// The GPS policy (plan §5, Q3 approved 17 Nov 2026): which readings may be
// signed as the place of extraction.
//
// "A location is never invented": no last-known position, no default point,
// no typed coordinates, and no override. A reading counts only if it is
//   - measured to within 25 m (the server's zone-edge tolerance),
//   - not from a fake-location app (Android marks those "mocked"),
//   - fresh: taken within the last 30 s.
//
// Plain Dart.

/// One reading from the location service, reduced to what the policy and
/// the payload need.
class GpsReading {
  const GpsReading({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.hasAccuracy,
    required this.isMocked,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;

  /// The radius, in metres, within which the true position probably lies.
  /// Smaller is better.
  final double accuracyM;

  /// False when the platform gave no accuracy at all: [accuracyM] is then a
  /// placeholder 0.0 that must not be read as "perfect" (geolocator's own
  /// warning on Position.hasAccuracy).
  final bool hasAccuracy;

  /// True when Android says the reading came from a mock-location provider.
  final bool isMocked;

  /// When the fix was taken (not when it was delivered).
  final DateTime timestamp;

  // A place is personal data: never in a log.
  @override
  String toString() => 'GpsReading(accuracy: ${accuracyM.round()} m)';
}

/// The worst accuracy accepted (Q3).
const double maxAccuracyM = 25;

/// The oldest a fix may be when it is used.
const Duration maxFixAge = Duration(seconds: 30);

/// Why a reading may not be used.
enum FixProblem { noAccuracy, tooInaccurate, mocked, stale }

/// Null if [reading] may be signed at [now]; otherwise the first reason why
/// not. Mocked comes first: a fake location must be named as such, however
/// accurate it claims to be.
FixProblem? fixProblem(GpsReading reading, DateTime now) {
  if (reading.isMocked) return FixProblem.mocked;
  if (!reading.hasAccuracy) return FixProblem.noAccuracy;
  if (!reading.accuracyM.isFinite || reading.accuracyM > maxAccuracyM) {
    return FixProblem.tooInaccurate;
  }
  final age = now.difference(reading.timestamp);
  // A timestamp ahead of the phone's clock by more than a moment is as
  // untrustworthy as an old one.
  if (age > maxFixAge || age < -const Duration(seconds: 5)) {
    return FixProblem.stale;
  }
  return null;
}
