// Saving a registration on the phone (plan M4): build the payload once, sign
// it with the device key, store it with its signature, and only then say
// "saved". No network: this works offline, which is the point (NFR-04).
//
//   1. Refuse at once if this phone may not sign for this user (decision
//      Mobile (11) and plan §4: other device, failed, or no key yet).
//   2. Open the local database, so a step is never signed that cannot then
//      be saved.
//   3. Build the payload ONCE (signing spec, section 4).
//   4. Sign exactly those bytes with the Keystore key.
//   5. Insert ONE row holding the payload, the signature and the key's
//      fingerprint. The row is the step; nothing is stored before it.
//   6. Report saved.
//
// If anything fails, nothing is stored and the reason is returned as a type.
// Nothing here is logged: the payload holds a place and a weight.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/database/database_failure.dart';
import '../../auth/domain/user.dart';
import '../../device_key/data/device_key_channel.dart';
import '../../device_key/domain/key_alias.dart';
import '../../device_key/domain/key_fingerprint.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/domain/local_step.dart';
import '../domain/mineral.dart';
import '../domain/payload_format.dart';
import '../domain/registration_payload.dart';

// ---- What a save came to -----------------------------------------------------

sealed class SaveResult {
  const SaveResult();
}

/// Committed to the encrypted database. Only now may the screen say "Saved
/// on this phone" (plan §3).
final class SaveDone extends SaveResult {
  const SaveDone(this.stepId);
  final String stepId;
}

/// This phone may not sign for this user (other device, failed, no key yet),
/// or the Keystore key is not the one the check approved. Nothing signed.
final class SaveKeyNotUsable extends SaveResult {
  const SaveKeyNotUsable();
}

/// A value breaks the payload grammar ([field] is the payload's name for
/// it). Nothing signed. The screen should not let this happen.
final class SaveInvalidField extends SaveResult {
  const SaveInvalidField(this.field);
  final String field;
}

/// The Keystore did not sign. Nothing stored.
final class SaveSigningFailed extends SaveResult {
  const SaveSigningFailed();
}

/// A step with this id is already saved. Each save makes a fresh id, so this
/// means a bug; the earlier row is kept as it was.
final class SaveDuplicateStepId extends SaveResult {
  const SaveDuplicateStepId();
}

/// The local database could not be opened ([failure] says why) or refused
/// the row. Nothing stored.
final class SaveStorageFailed extends SaveResult {
  const SaveStorageFailed([this.failure]);
  final DatabaseFailure? failure;
}

// ---- The use case ------------------------------------------------------------

class RegisterConsignment {
  // `this._channel` stores the argument in the private field; callers still
  // write `channel:` (as in AuthRepository).
  RegisterConsignment({
    required this._channel,
    required this._steps,
    required this._keyState,
    Clock clock = systemClock,
    this._random,
  }) : _now = clock;

  final DeviceKeyChannel _channel;
  final Future<LocalStepsRepository> Function() _steps;
  final DeviceKeyState Function() _keyState;
  final Clock _now;
  final Random? _random;

  /// Saves a registration by [user] for the custody record [qrCode].
  ///
  /// [weightMg] is the output of parseWeightToMg. [latitude] and [longitude]
  /// are the GPS fix as given by the location service; they are formatted
  /// here, once. The capture time is now, by the phone's clock (plan §5),
  /// read here so a screen cannot pass in a stale one.
  Future<SaveResult> save({
    required User user,
    required String qrCode,
    required Mineral mineral,
    required String weightMg,
    required double latitude,
    required double longitude,
    double? gpsAccuracyM,
  }) async {
    // 1. May this phone sign? Only ready or unregistered (plan §4).
    final String approvedFingerprint;
    switch (_keyState()) {
      case DeviceKeyReady(:final fingerprint) ||
          DeviceKeyUnregistered(:final fingerprint):
        approvedFingerprint = fingerprint;
      case _:
        return const SaveKeyNotUsable();
    }

    // 2. The database first: never sign what cannot be saved.
    final LocalStepsRepository steps;
    try {
      steps = await _steps();
    } on DatabaseFailure catch (failure) {
      return SaveStorageFailed(failure);
    }

    // 3. The payload, built once.
    final latitudeText = coordinateText(latitude, latitude: true);
    if (latitudeText == null) return const SaveInvalidField('latitude');
    final longitudeText = coordinateText(longitude, latitude: false);
    if (longitudeText == null) return const SaveInvalidField('longitude');

    final createdAt = _now();
    final stepId = newStepId(_random);
    final capturedAt = formatCapturedAt(createdAt);
    final String payload;
    try {
      payload = buildRegistrationPayload(
        stepId: stepId,
        actorId: user.id,
        qrCode: qrCode,
        mineral: mineral,
        weightMg: weightMg,
        latitude: latitudeText,
        longitude: longitudeText,
        capturedAt: capturedAt,
      );
    } on PayloadFieldInvalid catch (e) {
      return SaveInvalidField(e.field);
    }

    // 4. Sign exactly these bytes. The payload is ASCII (checked by the
    //    builder), so this is one byte per character.
    final alias = deviceKeyAlias(user.id);
    final Uint8List signature;
    try {
      // The key about to sign must be the one the check approved: a stale
      // state (another user, a key made since) must not sign under the
      // wrong fingerprint.
      final key = await _channel.publicKey(alias);
      if (key == null || keyFingerprint(key) != approvedFingerprint) {
        return const SaveKeyNotUsable();
      }
      signature = await _channel.sign(
        alias,
        Uint8List.fromList(ascii.encode(payload)),
      );
    } on DeviceKeyException {
      return const SaveSigningFailed();
    }

    // 5. One row: payload, signature and fingerprint together.
    try {
      await steps.insert(
        NewLocalStep(
          stepId: stepId,
          actorId: user.id,
          type: 'registration',
          qrCode: qrCode,
          mineral: mineral.name,
          weightMg: weightMg,
          latitude: latitudeText,
          longitude: longitudeText,
          capturedAt: capturedAt,
          payload: payload,
          signature: base64.encode(signature),
          keyFingerprint: approvedFingerprint,
          gpsAccuracyM: gpsAccuracyM,
          createdAt: createdAt,
        ),
      );
    } on LocalStepConflict {
      return const SaveDuplicateStepId();
    } on LocalStepsFailure {
      return const SaveStorageFailed();
    }

    // 6. Committed.
    return SaveDone(stepId);
  }
}

final registerConsignmentProvider = Provider<RegisterConsignment>((ref) {
  return RegisterConsignment(
    channel: ref.watch(deviceKeyChannelProvider),
    steps: () => ref.read(localStepsRepositoryProvider.future),
    keyState: () => ref.read(deviceKeyControllerProvider),
    clock: ref.watch(clockProvider),
  );
});
