// The handoff payload, version 1 (signing spec, section 3): the eight lines
// of steps/domain/later_step_payload.dart under `minechain-step/1/handoff`.
// Since buyer purchase T1 the builder is shared with the purchase; this
// file keeps the handoff's own name, so its callers and tests are unchanged.
//
// Plain Dart.

import '../../steps/domain/later_step_payload.dart';

export '../../steps/domain/later_step_payload.dart' show PayloadFieldInvalid;

/// The exact text to sign for a handoff. See [buildLaterStepPayload].
String buildHandoffPayload({
  required String stepId,
  required String actorId,
  required String qrCode,
  required String weightMg,
  required String latitude,
  required String longitude,
  required String capturedAt,
}) => buildLaterStepPayload(
  LaterStepType.handoff,
  stepId: stepId,
  actorId: actorId,
  qrCode: qrCode,
  weightMg: weightMg,
  latitude: latitude,
  longitude: longitude,
  capturedAt: capturedAt,
);
