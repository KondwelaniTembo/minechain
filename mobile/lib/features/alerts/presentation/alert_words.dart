// The plain words for an alert (officer alerts plan §4, T1): its heading, its
// severity, and "what the check found" as sentences built from `details`.
//
// Why here and not in domain/: every sentence comes from AppText, and the
// unit words from mineral_text.dart, as for the other screens' words. The
// arithmetic itself is plain Dart.
//
// Weights: `details` holds whole milligrams as text. They are shown in the
// consignment's unit with weightInUnit (text and BigInt, never a double), and
// the percentage is worked out with whole numbers only: tenths of a percent
// = |difference| x 1000 ~/ baseline, cut, never rounded up. So a sentence
// never says more than the numbers do.
//
// Anything odd in `details` (a missing field, a wrong type) gives the one
// sentence AppText.alertDetailsUnreadable instead of a guess. The alert
// itself is still shown and can still be decided.

import '../../../core/text/app_text.dart';
import '../../device_key/domain/key_fingerprint.dart';
import '../../registration/domain/mineral.dart';
import '../../registration/domain/weight.dart';
import '../../registration/presentation/mineral_text.dart';
import '../../verification/domain/consignment_view.dart' show StepType;
import '../domain/alert.dart';

/// The finding as a heading, for example "Weight differs by more than 10%".
String alertHeading(AlertType type) => switch (type) {
  AlertType.duplicateConsignment => AppText.alertDuplicate,
  AlertType.quantityDiscrepancy => AppText.alertQuantity,
  AlertType.gpsZone => AppText.alertGpsZone,
  AlertType.invalidSignature => AppText.alertSignature,
  AlertType.handoffOrder => AppText.alertHandoffOrder,
  AlertType.recordTampered => AppText.alertTampered,
  AlertType.unknown => AppText.alertUnknown,
};

/// "High", "Medium" or "Low".
String severityWord(AlertSeverity severity) => switch (severity) {
  AlertSeverity.high => AppText.severityHigh,
  AlertSeverity.medium => AppText.severityMedium,
  AlertSeverity.low => AppText.severityLow,
};

/// "What the check found", one sentence per line.
List<String> alertFindings(Alert alert) {
  final lines = switch (alert.type) {
    AlertType.duplicateConsignment => _duplicate(alert.details),
    AlertType.quantityDiscrepancy => _quantity(alert),
    AlertType.gpsZone => _gpsZone(alert.details),
    AlertType.invalidSignature => _signature(alert.details),
    AlertType.handoffOrder => _handoffOrder(alert.step.type),
    AlertType.recordTampered => _tampered(alert.details),
    AlertType.unknown => null,
  };
  return lines ?? const [AppText.alertDetailsUnreadable];
}

// ---- quantity_discrepancy ---------------------------------------------------

final RegExp _positiveMg = RegExp(r'^[1-9][0-9]*$');
final RegExp _signedMg = RegExp(r'^-?[0-9]+$');

List<String>? _quantity(Alert alert) {
  final details = alert.details;
  final weightMg = details['weightMg'];
  final threshold = details['thresholdPercent'];
  final failed = details['failedBaselines'];
  if (weightMg is! String || !_positiveMg.hasMatch(weightMg)) return null;
  if (threshold is! int || threshold < 0 || failed is! List) return null;

  final unit = alert.consignment.mineral.unit;
  final step = switch (alert.step.type) {
    StepType.handoff => AppText.thisHandoff,
    StepType.purchase => AppText.thisPurchase,
    StepType.registration => AppText.thisStep,
  };

  // The registration first, then the previous step; a failed baseline
  // before one within the limit (a stable sort keeps that order otherwise).
  final names = [
    for (final name in const ['registration', 'previous'])
      if (details.containsKey(name)) name,
  ];
  if (names.isEmpty) return null;
  final failedFirst = [
    ...names.where(failed.contains),
    ...names.where((n) => !failed.contains(n)),
  ];

  final lines = [AppText.stepWeighed(step, _weight(weightMg, unit))];
  for (final name in failedFirst) {
    final line = _baselineLine(
      details[name],
      baseline: name == 'registration'
          ? AppText.theRegistration
          : AppText.thePreviousStep,
      step: step,
      unit: unit,
      threshold: threshold,
    );
    if (line == null) return null;
    lines.add(line);
  }
  return lines;
}

String? _baselineLine(
  Object? json, {
  required String baseline,
  required String step,
  required WeightUnit unit,
  required int threshold,
}) {
  if (json is! Map) return null;
  final baselineMg = json['weightMg'];
  final differenceMg = json['differenceMg'];
  final exceeded = json['exceeded'];
  if (baselineMg is! String || !_positiveMg.hasMatch(baselineMg)) return null;
  if (differenceMg is! String || !_signedMg.hasMatch(differenceMg)) {
    return null;
  }
  if (exceeded is! bool) return null;

  final baselineWeight = _weight(baselineMg, unit);
  final difference = BigInt.parse(differenceMg);
  if (difference == BigInt.zero) {
    return AppText.sameWeightAs(baseline, baselineWeight);
  }
  final size = difference.abs();
  return AppText.comparedWith(
    baseline: baseline,
    baselineWeight: baselineWeight,
    step: step,
    difference: _weight(size.toString(), unit),
    percent: _percent(size, BigInt.parse(baselineMg), threshold, exceeded),
    lighter: difference.isNegative,
    exceeded: exceeded,
    thresholdPercent: threshold,
  );
}

/// [size] as a percentage of [baseline], cut to one decimal: "20%",
/// "10.4%". A flagged difference that would read as the limit itself (10.04%
/// shown as "10%") says "more than 10%" instead, so the sentence agrees with
/// the flag.
String _percent(BigInt size, BigInt baseline, int threshold, bool exceeded) {
  final tenths = size * BigInt.from(1000) ~/ baseline;
  if (exceeded && tenths <= BigInt.from(threshold * 10)) {
    return AppText.moreThanPercent(threshold);
  }
  final whole = tenths ~/ BigInt.from(10);
  final tenth = tenths % BigInt.from(10);
  return tenth == BigInt.zero ? '$whole%' : '$whole.$tenth%';
}

/// "1.6 kg", "150 g". Only ever called with checked digits.
String _weight(String milligrams, WeightUnit unit) =>
    '${weightInUnit(milligrams, unit)} ${unitSymbol(unit)}';

// ---- gps_zone ---------------------------------------------------------------

List<String>? _gpsZone(Map<String, Object?> details) {
  if (details['noActiveZones'] == true) return const [AppText.noZoneActive];
  final zone = details['nearestZoneName'];
  final distance = details['distanceMetres'];
  final tolerance = details['toleranceMetres'];
  if (zone is! String || zone.isEmpty) return null;
  if (distance is! int || tolerance is! int) return null;
  return [AppText.outsideZone(distance, zone, tolerance)];
}

// ---- duplicate_consignment ----------------------------------------------------

List<String>? _duplicate(Map<String, Object?> details) {
  final sameMiner = details['sameMiner'];
  if (sameMiner is! bool) return null;
  final lines = [
    sameMiner
        ? AppText.registeredBeforeSameMiner
        : AppText.registeredBeforeOtherMiner,
  ];
  // Both minerals only when they differ: the same bag registered as two
  // different minerals is worth saying out loud.
  final now = _mineral(details['mineral']);
  final before = _mineral(details['originalMineral']);
  if (now != null && before != null && now != before) {
    lines.add(AppText.mineralsDiffer(mineralName(now), mineralName(before)));
  }
  return lines;
}

Mineral? _mineral(Object? raw) =>
    raw is String ? Mineral.fromApiName(raw) : null;

// ---- invalid_signature --------------------------------------------------------

final RegExp _fingerprint = RegExp(r'^[0-9a-f]{64}$');

List<String>? _signature(Map<String, Object?> details) {
  final fingerprint = details['keyFingerprint'];
  if (fingerprint is! String || !_fingerprint.hasMatch(fingerprint)) {
    return null;
  }
  return [AppText.notThisDeviceKey(shortFingerprint(fingerprint))];
}

// ---- handoff_order --------------------------------------------------------------

List<String>? _handoffOrder(StepType type) => switch (type) {
  StepType.handoff => const [AppText.handoffAfterPurchase],
  StepType.purchase => const [AppText.purchaseAfterPurchase],
  StepType.registration => null,
};

// ---- record_tampered --------------------------------------------------------------

/// The chain check's field names (backend chainCheck.js), in words. Several
/// names can share one word (latitude and longitude are "location").
String _fieldWord(String name) {
  if (name.startsWith('receipt.') || name.startsWith('event.')) {
    return AppText.fieldReceipt;
  }
  return switch (name) {
    'weight_mg' => AppText.fieldWeight,
    'mineral_type' => AppText.fieldMineral,
    'latitude' || 'longitude' => AppText.fieldLocation,
    'captured_at' => AppText.fieldTime,
    'qr_code' => AppText.fieldQrCode,
    'actor_id' => AppText.fieldPerson,
    'type' => AppText.fieldStepType,
    'idempotency_key' => AppText.fieldStepId,
    'signature' || 'signer_public_key' => AppText.fieldSignature,
    'signed_payload' => AppText.fieldSignedRecord,
    'data_hash' || 'hash_version' => AppText.fieldFingerprint,
    'chain_tx_hash' => AppText.fieldTransaction,
    _ => AppText.fieldOther,
  };
}

List<String>? _tampered(Map<String, Object?> details) {
  final fields = details['fields'];
  if (fields is! List || !fields.every((f) => f is String)) return null;
  // The chain check names chain_tx_hash alone, for TX_NOT_FOUND (backend
  // chainCheck.js, step 4); "no longer matches" would not say what happened.
  if (fields.length == 1 && fields.single == 'chain_tx_hash') {
    return const [AppText.transactionNotFound];
  }
  // In the server's order, each word once.
  final words = <String>[];
  for (final field in fields.cast<String>()) {
    final word = _fieldWord(field);
    if (!words.contains(word)) words.add(word);
  }
  // "other details" last: it reads oddly in the middle of a list.
  if (words.remove(AppText.fieldOther)) words.add(AppText.fieldOther);
  return [AppText.noLongerMatches(words)];
}
