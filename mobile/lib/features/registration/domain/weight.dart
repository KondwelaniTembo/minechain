// The typed weight, turned into whole milligrams for the payload (plan M4,
// Q2) exactly, through the text and whole numbers only.
//
// Why never a double: 0.1 cannot be stored exactly in binary floating point
// (it is 0.1000000000000000055...), so "1.1 kg" * 1000000 as a double can
// come out as 1100000.0000000002 or 1099999.9999999998, and rounding then
// decides the signed weight. Splitting the text at the decimal point and
// joining the digits as a BigInt gives exactly 1100000, every time.
//
// Plain Dart.

import 'mineral.dart';
import 'payload_format.dart';

/// Why a typed weight was refused.
enum WeightProblem {
  /// Nothing typed.
  empty,

  /// Starts with a minus sign.
  negative,

  /// Not digits with at most one decimal point (or comma).
  notANumber,

  /// More decimals than the unit allows (3 for grams, 6 for kilograms),
  /// which would be less than one milligram.
  tooManyDecimals,

  /// Zero: the server requires at least 1 mg.
  zero,

  /// More than the server can store (9223372036854775807 mg).
  tooLarge,
}

sealed class WeightParse {
  const WeightParse();
}

/// The weight in whole milligrams, as the payload's text (no leading zeros).
final class WeightOk extends WeightParse {
  const WeightOk(this.milligrams);
  final String milligrams;
}

final class WeightRefused extends WeightParse {
  const WeightRefused(this.problem);
  final WeightProblem problem;
}

/// Whole milligrams [milligrams] (the signed text, digits only) shown in
/// [unit], exactly: "1500" mg in grams is "1.5", "2000000" mg in kilograms
/// is "2". The reverse of [parseWeightToMg], on text again, never a double.
/// Null if [milligrams] is not plain digits (a damaged row), so the caller
/// can fall back to milligrams.
String? weightInUnit(String milligrams, WeightUnit unit) {
  if (!RegExp(r'^[0-9]+$').hasMatch(milligrams)) return null;
  final digits = milligrams.padLeft(unit.decimals + 1, '0');
  final cut = digits.length - unit.decimals;
  final whole = BigInt.parse(digits.substring(0, cut)).toString();
  final fraction = digits.substring(cut).replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

/// Digits, then optionally one point or comma and more digits. A comma is
/// allowed because some phone keyboards offer only "," as the decimal key.
/// No thousands separators, no sign, no spaces inside.
final RegExp _decimal = RegExp(r'^([0-9]+)(?:[.,]([0-9]+))?$');

/// [text] as typed, in [unit], to whole milligrams.
///
/// Surrounding spaces are ignored (the field's own padding); anything else
/// unusual is refused, never guessed at.
WeightParse parseWeightToMg(String text, WeightUnit unit) {
  final typed = text.trim();
  if (typed.isEmpty) return const WeightRefused(WeightProblem.empty);
  if (typed.startsWith('-')) return const WeightRefused(WeightProblem.negative);

  final match = _decimal.firstMatch(typed);
  if (match == null) return const WeightRefused(WeightProblem.notANumber);

  final whole = match.group(1)!;
  final fraction = match.group(2) ?? '';
  if (fraction.length > unit.decimals) {
    return const WeightRefused(WeightProblem.tooManyDecimals);
  }

  // "1.5" kg -> "1" and "500000" -> "1500000" mg. Padding the fraction to
  // the unit's decimals is the multiplication by 10^decimals, done on text.
  final milligrams = BigInt.parse(
    '$whole${fraction.padRight(unit.decimals, '0')}',
  );
  if (milligrams == BigInt.zero) {
    return const WeightRefused(WeightProblem.zero);
  }
  if (milligrams > maxWeightMg) {
    return const WeightRefused(WeightProblem.tooLarge);
  }
  // BigInt.toString() drops leading zeros ("0001500" -> "1500"), as the
  // payload grammar requires.
  return WeightOk(milligrams.toString());
}
