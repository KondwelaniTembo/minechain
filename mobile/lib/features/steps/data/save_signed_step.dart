// Saving any custody step on the phone (plan M4, shared since Transporter
// handoff T2): build the payload once, sign it with the device key, store it
// with its signature, and only then say "saved". No network: this works
// offline, which is the point (NFR-04).
//
//   1. Refuse at once if this phone may not sign for this user (decision
//      Mobile (11): other device, failed, or no key yet).
//   2. Open the local database, so a step is never signed that cannot then
//      be saved.
//   3. Build the payload ONCE (signing spec, section 4). Each step type
//      passes its own builder; everything else here is the same for all.
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

import '../../../core/clock.dart';
import '../../../core/database/database_failure.dart';
import '../../auth/domain/user.dart';
import '../../device_key/data/device_key_channel.dart';
import '../../device_key/domain/key_alias.dart';
import '../../device_key/domain/key_fingerprint.dart';
import '../../device_key/presentation/device_key_controller.dart';
import '../../registration/domain/payload_format.dart';
import '../../registration/domain/registration_payload.dart'
    show PayloadFieldInvalid;
import '../domain/local_step.dart';
import 'local_steps_repository.dart';

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

/// The phone has no screen lock, so the Keystore side refused to sign
/// (Hardening, finding H1). Nothing stored; Save works again once a lock
/// is set.
final class SaveNoScreenLock extends SaveResult {
  const SaveNoScreenLock();
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

/// The database file was in use for a moment (decision Mobile (26)).
/// Nothing stored, nothing wrong with the saved work: Save again works.
/// Never shown as "cannot be opened".
final class SaveBusy extends SaveResult {
  const SaveBusy();
}

// ---- The shared save ---------------------------------------------------------

/// The values every payload type has, made here once per save, already in
/// payload form. A step type's builder adds its own fields (a mineral, for a
/// registration) and returns the exact text to sign.
class StepValues {
  const StepValues({
    required this.stepId,
    required this.actorId,
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
  });

  final String stepId;
  final String actorId;
  final String latitude;
  final String longitude;
  final String capturedAt;
}

/// Builds one step type's payload from [StepValues]. Throws
/// [PayloadFieldInvalid] for a value that breaks the grammar.
typedef PayloadBuilder = String Function(StepValues values);

class SignedStepSaver {
  SignedStepSaver({
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

  /// Saves one step of [type] by [user] for the custody record [qrCode].
  ///
  /// [build] makes the payload text; [mineral] and [mineralHint] are only the
  /// row's copies (the signed mineral of a registration, or the unsigned
  /// display hint of a later step). [latitude] and [longitude] are the GPS
  /// fix as given by the location service; they are formatted here, once.
  /// The capture time is now, by the phone's clock, read here so a screen
  /// cannot pass in a stale one.
  Future<SaveResult> save({
    required User user,
    required String type,
    required String qrCode,
    required String weightMg,
    required double latitude,
    required double longitude,
    required PayloadBuilder build,
    String? mineral,
    String? mineralHint,
    double? gpsAccuracyM,
  }) async {
    // 1. May this phone sign? Only ready or unregistered.
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
      if (isBusyMoment(failure)) return const SaveBusy();
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
      payload = build(
        StepValues(
          stepId: stepId,
          actorId: user.id,
          latitude: latitudeText,
          longitude: longitudeText,
          capturedAt: capturedAt,
        ),
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
    } on DeviceKeyException catch (e) {
      if (e.error == DeviceKeyError.noScreenLock) {
        return const SaveNoScreenLock();
      }
      return const SaveSigningFailed();
    }

    // 5. One row: payload, signature and fingerprint together.
    try {
      await steps.insert(
        NewLocalStep(
          stepId: stepId,
          actorId: user.id,
          type: type,
          qrCode: qrCode,
          mineral: mineral,
          mineralHint: mineralHint,
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
    } on LocalStepsFailure catch (failure) {
      // The signature just made is dropped with the row; Save again signs a
      // fresh step with a new id, so nothing is ever sent twice.
      if (failure.busy) return const SaveBusy();
      return const SaveStorageFailed();
    } on DatabaseFailure catch (failure) {
      // Every call opens the file again (local_database.dart), so opening
      // can fail here too; before, this escaped save() and left the screen
      // saving for ever.
      if (isBusyMoment(failure)) return const SaveBusy();
      return SaveStorageFailed(failure);
    }

    // 6. Committed.
    return SaveDone(stepId);
  }
}
