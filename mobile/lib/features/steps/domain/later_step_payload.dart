// The payload of a step that follows the registration, version 1 (signing
// spec, section 3): a handoff or a purchase. Both are exactly eight
// `key=value` lines, in this order, each ending with LF, the last one
// included; only the first line differs.
//
//   minechain-step/1/<handoff|purchase>
//   step_id=...
//   actor_id=...
//   qr_code=...
//   weight_mg=...
//   latitude=...
//   longitude=...
//   captured_at=...
//
// One builder for both (buyer purchase plan T1), so the two can never drift
// apart. The header comes from [LaterStepType], never from a string, so no
// other first line can be written.
//
// There is no `mineral` line: the mineral was fixed by the miner's signed
// registration, and a later custodian cannot restate it. The server refuses
// a handoff or purchase that has one.
//
// The same rule as registration: built ONCE when the step is captured,
// stored and signed as this exact text, never rebuilt before sending.
//
// Plain Dart.

import '../../registration/domain/payload_format.dart';
import '../../registration/domain/registration_payload.dart'
    show PayloadFieldInvalid;

export '../../registration/domain/registration_payload.dart'
    show PayloadFieldInvalid;

/// A step after the registration: its type, as the server and the local
/// database spell it.
enum LaterStepType {
  handoff('handoff'),
  purchase('purchase');

  const LaterStepType(this.type);

  /// `handoff` or `purchase`.
  final String type;

  /// The payload's first line, without its LF.
  String get header => 'minechain-step/1/$type';
}

/// The exact text to sign for a [type] step.
///
/// Every value must already be in payload form (for coordinates and time,
/// from [formatCoordinate] and [formatCapturedAt]). Each one is checked
/// against the spec's grammar; the first that fails throws
/// [PayloadFieldInvalid], and nothing is built.
String buildLaterStepPayload(
  LaterStepType type, {
  required String stepId,
  required String actorId,
  required String qrCode,
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
    ..write('${type.header}\n')
    ..write('step_id=$stepId\n')
    ..write('actor_id=$actorId\n')
    ..write('qr_code=$qrCode\n')
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
