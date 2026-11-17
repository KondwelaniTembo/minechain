// The value rules of the signed payload, version 1 (signing spec, sections
// 3 and 4), on the phone's side.
//
// The server checks every one of these again and refuses anything else
// (PAYLOAD_MALFORMED). Checking here too means the phone never signs a step
// that can only be rejected: a signed record is evidence, so a malformed one
// would sit on the phone as "rejected" for ever.
//
// Plain Dart: no Flutter, no floating-point formatting of signed values.

import 'dart:math';

// ---- Copied from the signing spec, section 4, exactly ---------------------

/// Formats a latitude or longitude for the signed payload (version 1).
String formatCoordinate(double value) {
  // Whole millionths of a degree. Dart's round() rounds halves away from zero.
  final micro = (value * 1000000).round();
  if (micro == 0) return '0.000000';
  final sign = micro < 0 ? '-' : '';
  final abs = micro.abs();
  final whole = abs ~/ 1000000;
  final fraction = (abs % 1000000).toString().padLeft(6, '0');
  return '$sign$whole.$fraction';
}

/// Formats the capture time for the signed payload (version 1).
String formatCapturedAt(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = utc.year.toString().padLeft(4, '0');
  // utc.millisecond ignores utc.microsecond, so this truncates, never rounds.
  final millis = utc.millisecond.toString().padLeft(3, '0');
  return '$year-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.${millis}Z';
}

// ---- Our own additions ---------------------------------------------------------

/// A GPS reading as payload text, or null if it cannot be one: not a finite
/// number, or outside ±90 (latitude) / ±180 (longitude) after rounding (the
/// spec: "After rounding, the app must check the range").
String? coordinateText(double value, {required bool latitude}) {
  // round() on NaN or infinity throws; a GPS fix should never give one.
  if (!value.isFinite) return null;
  final text = formatCoordinate(value);
  return isCoordinate(text, latitude: latitude) ? text : null;
}

/// A fresh step id: a random (version 4) UUID in lower case (signing spec,
/// section 4, "a fresh random UUID (version 4) for each step").
String newStepId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// ---- The grammar of each value (signing spec, section 3, "Value grammar") --

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// `step_id` and `actor_id`: lower-case 8-4-4-4-12. "Upper case is refused,
/// not folded."
bool isLowerCaseUuid(String value) => _uuid.hasMatch(value);

final RegExp _qrCode = RegExp(r'^[A-Za-z0-9._:/-]{4,128}$');

/// `qr_code`: "4–128 characters from `A–Z a–z 0–9 . _ : / -`", exactly as
/// scanned, never trimmed or case-changed.
bool isQrCode(String value) => _qrCode.hasMatch(value);

/// The largest weight the server stores (a PostgreSQL bigint): "at most
/// `9223372036854775807`".
final BigInt maxWeightMg = BigInt.parse('9223372036854775807');

final RegExp _weightMg = RegExp(r'^[1-9][0-9]*$');

/// `weight_mg`: "Whole milligrams as decimal digits: no sign, no leading
/// zeros, at least `1`, at most `9223372036854775807`".
bool isWeightMg(String value) =>
    _weightMg.hasMatch(value) && BigInt.parse(value) <= maxWeightMg;

final RegExp _coordinate = RegExp(r'^(-?)(0|[1-9][0-9]{0,2})\.([0-9]{6})$');

/// `latitude` / `longitude`: "exactly 6 decimal places", pattern
/// `-?(0|[1-9][0-9]{0,2})\.[0-9]{6}`, within ±90 / ±180, and
/// "`-0.000000` is refused". Checked on the text, with integers only.
bool isCoordinate(String value, {required bool latitude}) {
  final match = _coordinate.firstMatch(value);
  if (match == null) return false;
  final negative = match.group(1) == '-';
  final whole = int.parse(match.group(2)!);
  final fraction = int.parse(match.group(3)!);
  if (negative && whole == 0 && fraction == 0) return false; // -0.000000
  final limit = latitude ? 90 : 180;
  return whole < limit || (whole == limit && fraction == 0);
}

final RegExp _capturedAt = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$',
);

/// `captured_at`: `YYYY-MM-DDTHH:MM:SS.sssZ`, "exactly 3 fraction digits and
/// a literal `Z`, and a real calendar date and time" (so not 30 February).
bool isCapturedAt(String value) {
  final m = _capturedAt.firstMatch(value);
  if (m == null) return false;
  final parts = [for (var i = 1; i <= 7; i++) int.parse(m.group(i)!)];
  // DateTime.utc quietly rolls 30 February over into March. Building the
  // time and comparing every part back catches that.
  final t = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
    parts[6],
  );
  return t.year == parts[0] &&
      t.month == parts[1] &&
      t.day == parts[2] &&
      t.hour == parts[3] &&
      t.minute == parts[4] &&
      t.second == parts[5] &&
      t.millisecond == parts[6];
}

/// "printable ASCII only (bytes 0x21 to 0x7E), plus LF (0x0A)".
bool isPayloadText(String payload) {
  for (final unit in payload.codeUnits) {
    if (unit != 0x0a && (unit < 0x21 || unit > 0x7e)) return false;
  }
  return true;
}
