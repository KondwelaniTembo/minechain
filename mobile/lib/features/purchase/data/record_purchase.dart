// Saving a purchase on the phone (buyer purchase plan T1): the licensed
// buyer signs their own weight, place and time for a bag they are buying.
// The shared steps (key check, database first, sign, one row) are in
// steps/data/save_signed_step.dart; this file adds the purchase's payload.
//
// The mineral is NOT signed (a purchase has no mineral line: the miner's
// registration fixed it). It is kept on the row only as an unsigned display
// hint, the one the screen used for the weight's unit, so "My purchases"
// can show "Copper, 1.9 kg" (as Handoff app (1) does for a handoff).
//
// No network: this works offline (NFR-04).

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../auth/domain/user.dart';
import '../../device_key/data/device_key_channel.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../registration/domain/mineral.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/data/save_signed_step.dart';
import '../../steps/domain/later_step_payload.dart';
import '../domain/purchase_payload.dart';

export '../../steps/data/save_signed_step.dart'
    show
        SaveResult,
        SaveDone,
        SaveKeyNotUsable,
        SaveInvalidField,
        SaveSigningFailed,
        SaveNoScreenLock,
        SaveDuplicateStepId,
        SaveStorageFailed,
        SaveBusy;

class RecordPurchase {
  RecordPurchase({
    required DeviceKeyChannel channel,
    required Future<LocalStepsRepository> Function() steps,
    required DeviceKeyState Function() keyState,
    Clock clock = systemClock,
    Random? random,
  }) : _saver = SignedStepSaver(
         channel: channel,
         steps: steps,
         keyState: keyState,
         clock: clock,
         random: random,
       );

  final SignedStepSaver _saver;

  /// Saves a purchase by [user] (a buyer) for the custody record [qrCode].
  ///
  /// [weightMg] is the buyer's own weighing, from parseWeightToMg in
  /// [mineral]'s unit. [mineral] is stored only as the unsigned hint.
  /// [latitude] and [longitude] are the GPS fix as given by the location
  /// service; they are formatted once, in the shared save.
  Future<SaveResult> save({
    required User user,
    required String qrCode,
    required Mineral mineral,
    required String weightMg,
    required double latitude,
    required double longitude,
    double? gpsAccuracyM,
  }) => _saver.save(
    user: user,
    type: LaterStepType.purchase.type,
    qrCode: qrCode,
    mineralHint: mineral.name,
    weightMg: weightMg,
    latitude: latitude,
    longitude: longitude,
    gpsAccuracyM: gpsAccuracyM,
    build: (v) => buildPurchasePayload(
      stepId: v.stepId,
      actorId: v.actorId,
      qrCode: qrCode,
      weightMg: weightMg,
      latitude: v.latitude,
      longitude: v.longitude,
      capturedAt: v.capturedAt,
    ),
  );
}

final recordPurchaseProvider = Provider<RecordPurchase>((ref) {
  return RecordPurchase(
    channel: ref.watch(deviceKeyChannelProvider),
    steps: () => ref.read(localStepsRepositoryProvider.future),
    keyState: () => ref.read(deviceKeyControllerProvider),
    clock: ref.watch(clockProvider),
  );
});
