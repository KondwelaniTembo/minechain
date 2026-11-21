// A zone's corners as the administrator types them, or as the phone's GPS
// gives them (GPS zones plan §3, Q1 and Q3).
//
// The app checks only what it can on its own: each corner is two numbers, in
// range, with at most 6 decimal places, and a zone has 3 to 100 corners. The
// shape rules (no repeated corner, no closed ring, inside Zambia, at least
// 100 m², at most 50 km across) stay with the server, whose messages the
// create screen shows on the corner they name. One set of shape rules, in one
// place.
//
// Plain Dart, no Flutter.

import 'gps_zone.dart';

/// api.md, "The boundary": "3 to 100 corners".
const int minZoneCorners = 3;
const int maxZoneCorners = 100;

/// api.md: "at most 6 decimal places. More places are refused, not rounded."
const int maxCornerDecimals = 6;

/// api.md, POST /admin/zones: the name is 3–100 characters and the licence
/// number 1–50, both after trimming.
const int zoneNameMin = 3;
const int zoneNameMax = 100;
const int zoneLicenceMax = 50;

/// Why a typed corner was not taken.
enum CornerProblem {
  /// Not exactly two numbers, such as "-15.41" or "-15.41, 28.28, 3".
  notTwoNumbers,

  /// Latitude outside -90 to 90.
  latitudeOutOfRange,

  /// Longitude outside -180 to 180.
  longitudeOutOfRange,

  /// More than 6 decimal places (Q3: refused as typed, as the server does).
  tooManyDecimals,
}

/// What [parseCorner] made of the text: a corner, or why not.
class CornerInput {
  const CornerInput._(this.corner, this.problem);

  final ZoneCorner? corner;
  final CornerProblem? problem;

  @override
  String toString() => 'CornerInput(problem: ${problem?.name})';
}

// A plain decimal number: an optional sign, digits, and an optional point
// with digits after it. No exponent ("1e3") and no "1." or ".5": a corner is
// copied from a map or a GPS screen, which never write those.
final RegExp _number = RegExp(r'^[+-]?\d+(\.\d+)?$');

/// Reads "latitude, longitude", the way Google Maps shows a dropped pin
/// ("-15.418327, 28.289494"). A comma, spaces, or both may separate the two.
///
/// A corner that looks swapped ("28.29, -15.42") is in range, so it is taken
/// here; the server's Zambia box refuses it with a sentence that explains
/// the order.
CornerInput parseCorner(String text) {
  // U+2212 is the typographic minus some pages and keyboards use.
  final cleaned = text.trim().replaceAll('−', '-');
  final parts = cleaned
      .split(RegExp(r'[,\s]+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length != 2 || !parts.every(_number.hasMatch)) {
    return const CornerInput._(null, CornerProblem.notTwoNumbers);
  }
  if (parts.any((part) => _decimals(part) > maxCornerDecimals)) {
    return const CornerInput._(null, CornerProblem.tooManyDecimals);
  }
  final latitude = double.parse(parts[0]);
  final longitude = double.parse(parts[1]);
  if (latitude < -90 || latitude > 90) {
    return const CornerInput._(null, CornerProblem.latitudeOutOfRange);
  }
  if (longitude < -180 || longitude > 180) {
    return const CornerInput._(null, CornerProblem.longitudeOutOfRange);
  }
  return CornerInput._(ZoneCorner(latitude, longitude), null);
}

int _decimals(String number) {
  final point = number.indexOf('.');
  return point < 0 ? 0 : number.length - point - 1;
}

/// A GPS reading as a corner, rounded to 6 decimal places (about 10 cm,
/// far finer than the 25 m the fix policy allows). Rounded through decimal
/// text, so the double sent is exactly the 6-place value.
ZoneCorner cornerFromReading(double latitude, double longitude) => ZoneCorner(
  double.parse(latitude.toStringAsFixed(maxCornerDecimals)),
  double.parse(longitude.toStringAsFixed(maxCornerDecimals)),
);

/// One coordinate for the screen, with at most 6 decimals and no trailing
/// zeros: -15.45 rather than -15.450000, and -13 rather than -13.0.
String coordinateText(double value) {
  var text = value.toStringAsFixed(maxCornerDecimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  // -0.000000 rounds to "-0".
  return text == '-0' ? '0' : text;
}

/// "-15.418327, 28.289494": latitude first, as typed and as Google Maps
/// shows it.
String cornerText(ZoneCorner corner) =>
    '${coordinateText(corner.latitude)}, ${coordinateText(corner.longitude)}';

/// Which corner a field path from the server names, counting from 0:
/// `boundary.3` and `boundary.3.1` are both corner 3 (the fourth). Null for
/// `boundary` itself and for any other field.
int? cornerIndexOfField(String field) {
  final match = RegExp(r'^boundary\.(\d+)(\.[01])?$').firstMatch(field);
  return match == null ? null : int.parse(match.group(1)!);
}
