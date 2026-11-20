// Saving a registration on the phone (plan M4). The steps every step type
// shares (key check, database first, sign, one row) are in
// steps/data/save_signed_step.dart; this file adds only what a
// registration has of its own: its payload, with the signed mineral.
//
// No network: this works offline, which is the point (NFR-04).

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../auth/domain/user.dart';
import '../../device_key/data/device_key_channel.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/data/save_signed_step.dart';
import '../domain/mineral.dart';
import '../domain/registration_payload.dart';

// The screens and tests name the results through this file, as before the
// split.
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

class RegisterConsignment {
  // The same parameters as before the split, handed to the shared save.
  RegisterConsignment({
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

  /// Saves a registration by [user] for the custody record [qrCode].
  ///
  /// [weightMg] is the output of parseWeightToMg. [latitude] and [longitude]
  /// are the GPS fix as given by the location service; they are formatted
  /// once, in the shared save.
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
    type: 'registration',
    qrCode: qrCode,
    // The signed mineral: the row's copy of the payload's own line.
    mineral: mineral.name,
    weightMg: weightMg,
    latitude: latitude,
    longitude: longitude,
    gpsAccuracyM: gpsAccuracyM,
    build: (v) => buildRegistrationPayload(
      stepId: v.stepId,
      actorId: v.actorId,
      qrCode: qrCode,
      mineral: mineral,
      weightMg: weightMg,
      latitude: v.latitude,
      longitude: v.longitude,
      capturedAt: v.capturedAt,
    ),
  );
}

final registerConsignmentProvider = Provider<RegisterConsignment>((ref) {
  return RegisterConsignment(
    channel: ref.watch(deviceKeyChannelProvider),
    steps: () => ref.read(localStepsRepositoryProvider.future),
    keyState: () => ref.read(deviceKeyControllerProvider),
    clock: ref.watch(clockProvider),
  );
});
