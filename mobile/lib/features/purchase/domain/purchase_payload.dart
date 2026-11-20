// The purchase payload, version 1 (signing spec, section 3): the eight
// lines of steps/domain/later_step_payload.dart under
// `minechain-step/1/purchase` (buyer purchase plan T1). The buyer signs
// their own weight, place and time; no mineral and no price.
//
// Plain Dart.

import '../../steps/domain/later_step_payload.dart';

export '../../steps/domain/later_step_payload.dart' show PayloadFieldInvalid;

/// The exact text to sign for a purchase. See [buildLaterStepPayload].
String buildPurchasePayload({
  required String stepId,
  required String actorId,
  required String qrCode,
  required String weightMg,
  required String latitude,
  required String longitude,
  required String capturedAt,
}) => buildLaterStepPayload(
  LaterStepType.purchase,
  stepId: stepId,
  actorId: actorId,
  qrCode: qrCode,
  weightMg: weightMg,
  latitude: latitude,
  longitude: longitude,
  capturedAt: capturedAt,
);
