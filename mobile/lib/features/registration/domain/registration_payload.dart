// The registration payload, version 1 (signing spec, section 3): exactly
// nine `key=value` lines, in this order, each ending with LF, the last one
// included.
//
//   minechain-step/1/registration
//   step_id=...
//   actor_id=...
//   qr_code=...
//   mineral=...
//   weight_mg=...
//   latitude=...
//   longitude=...
//   captured_at=...
//
// "The phone must build the payload ONCE, when the step is captured, store
// that exact string in the encrypted local database, sign it, and later send
// the same string. It must never rebuild the payload from stored fields
// before sending" (section 4).
//
// Plain Dart.

import 'mineral.dart';
import 'payload_format.dart';

/// A value that breaks the payload grammar. [field] is the payload's own
/// name for it (`qr_code`, `latitude`, ...); the value itself is not kept.
final class PayloadFieldInvalid implements Exception {
  const PayloadFieldInvalid(this.field);
  final String field;

  @override
  String toString() => 'PayloadFieldInvalid($field)';
}

/// The exact text to sign for a registration.
///
/// Every value must already be in payload form (for coordinates and time,
/// from [formatCoordinate] and [formatCapturedAt]). Each one is checked
/// against the spec's grammar; the first that fails throws
/// [PayloadFieldInvalid], and nothing is built.
String buildRegistrationPayload({
  required String stepId,
  required String actorId,
  required String qrCode,
  required Mineral mineral,
  required String weightMg,
  required String latitude,
  required String longitude,
  required String capturedAt,
}) {
  void check(String field, bool ok) {
    if (!ok) throw PayloadFieldInvalid(field);
  }

  check('step_id', isLowerCaseUuid(stepId));
  check('actor_id', isLowerCaseUuid(actorId));
  check('qr_code', isQrCode(qrCode));
  check('weight_mg', isWeightMg(weightMg));
  check('latitude', isCoordinate(latitude, latitude: true));
  check('longitude', isCoordinate(longitude, latitude: false));
  check('captured_at', isCapturedAt(capturedAt));

  final payload = StringBuffer()
    ..write('minechain-step/1/registration\n')
    ..write('step_id=$stepId\n')
    ..write('actor_id=$actorId\n')
    ..write('qr_code=$qrCode\n')
    ..write('mineral=${mineral.name}\n')
    ..write('weight_mg=$weightMg\n')
    ..write('latitude=$latitude\n')
    ..write('longitude=$longitude\n')
    ..write('captured_at=$capturedAt\n');
  final text = payload.toString();

  // Every value above is already pure ASCII by its grammar; this is the
  // last guard that nothing else slipped in.
  check('payload', isPayloadText(text));
  return text;
}
