// The handoff payload, version 1 (signing spec, section 3): exactly eight
// `key=value` lines, in this order, each ending with LF, the last one
// included.
//
//   minechain-step/1/handoff
//   step_id=...
//   actor_id=...
//   qr_code=...
//   weight_mg=...
//   latitude=...
//   longitude=...
//   captured_at=...
//
// There is no `mineral` line: the mineral was fixed by the miner's signed
// registration, and a transporter cannot restate it. The server refuses a
// handoff that has one (the "mineral line on a handoff" vector).
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

/// The exact text to sign for a handoff.
///
/// Every value must already be in payload form (for coordinates and time,
/// from [formatCoordinate] and [formatCapturedAt]). Each one is checked
/// against the spec's grammar; the first that fails throws
/// [PayloadFieldInvalid], and nothing is built.
String buildHandoffPayload({
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
    ..write('minechain-step/1/handoff\n')
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
