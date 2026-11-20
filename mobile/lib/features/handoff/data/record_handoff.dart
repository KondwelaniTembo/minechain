// Saving a handoff on the phone (Transporter handoff T2): the transporter
// takes custody of a bag and signs their own weight, place and time. The
// shared steps (key check, database first, sign, one row) are in
// steps/data/save_signed_step.dart; this file adds the handoff's payload.
//
// The mineral is NOT signed (a handoff has no mineral line: the miner's
// registration fixed it). It is kept on the row only as an unsigned display
// hint (plan Q3), the one the screen used for the weight's unit, so "My
// handoffs" can show "Copper, 1.5 kg".
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
import '../domain/handoff_payload.dart';

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

class RecordHandoff {
  RecordHandoff({
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

  /// Saves a handoff by [user] (a transporter) for the custody record
  /// [qrCode].
  ///
  /// [weightMg] is the transporter's own weighing, from parseWeightToMg in
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
    type: 'handoff',
    qrCode: qrCode,
    mineralHint: mineral.name,
    weightMg: weightMg,
    latitude: latitude,
    longitude: longitude,
    gpsAccuracyM: gpsAccuracyM,
    build: (v) => buildHandoffPayload(
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

final recordHandoffProvider = Provider<RecordHandoff>((ref) {
  return RecordHandoff(
    channel: ref.watch(deviceKeyChannelProvider),
    steps: () => ref.read(localStepsRepositoryProvider.future),
    keyState: () => ref.read(deviceKeyControllerProvider),
    clock: ref.watch(clockProvider),
  );
});
