// Registers this phone's signing key for the signed-in user (plan M2 and §4,
// decision Mobile (17)).
//
// After every sign-in (a login, a re-entered password, a restored session)
// SignedInEvents reports the user. For a miner, transporter or buyer this
// controller then compares the phone's key for that user with the server's
// `publicKeyFingerprint`, following the plan's §4 table:
//
//   phone key | server fingerprint | what happens               | may sign?
//   ----------+--------------------+-----------------------------+----------
//   none      | null               | create the key, PUT it      | yes
//   exists    | null               | PUT the existing key        | yes
//   exists    | equal              | nothing                     | yes
//   exists    | different          | otherDevice                 | NO
//   none      | not null           | otherDevice (reinstall, new | NO
//             |                    | phone): admin reset needed  |
//
// Rules kept here:
// - Never a second key for one alias: a key is created only when the phone
//   has none for this user, and the Keystore refuses to overwrite anyway.
// - Never a deleted key, and never a signature: this controller only reads,
//   creates and registers public keys.
// - No timers and no retry loops. If the PUT cannot get through, the state
//   is "unregistered" and the same key is sent again at the next sign-in
//   (a repeat of the same key is harmless: the server answers 200 again).
// - 401 and 403 are handled by SessionEvents as everywhere else; ApiClient
//   reports them before the failure reaches this code.
//
// Officers and administrators never sign steps: notNeeded, and the Keystore
// is not touched at all.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/network/network_providers.dart';
import '../../../core/network/pinned_http_client.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/text/app_text.dart';
import '../../auth/data/session_store.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/domain/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/device_key_api.dart';
import '../data/device_key_channel.dart';
import '../domain/key_alias.dart';
import '../domain/key_fingerprint.dart';

/// The roles that sign custody steps and so have a device key (api.md,
/// PUT /auth/me/public-key: "miner, transporter or buyer").
const Set<Role> signingRoles = {Role.miner, Role.transporter, Role.buyer};

// ---- States ------------------------------------------------------------------

sealed class DeviceKeyState {
  const DeviceKeyState();

  /// Whether this phone may sign steps for the signed-in user.
  bool get maySign => false;
}

/// Signed out, or an officer or administrator: no key is needed.
final class DeviceKeyNotNeeded extends DeviceKeyState {
  const DeviceKeyNotNeeded();
}

/// Looking at the phone's key and, if needed, registering it.
final class DeviceKeyChecking extends DeviceKeyState {
  const DeviceKeyChecking();
}

/// The server has this phone's key for this user.
final class DeviceKeyReady extends DeviceKeyState {
  const DeviceKeyReady(this.fingerprint);
  final String fingerprint;

  @override
  bool get maySign => true;
}

/// The phone has its key, but the server does not have it yet (no network,
/// the server asleep, or the token expired). It is sent at the next sign-in.
/// Signing is allowed: steps signed now will verify once the key arrives.
final class DeviceKeyUnregistered extends DeviceKeyState {
  const DeviceKeyUnregistered(this.fingerprint);
  final String fingerprint;

  @override
  bool get maySign => true;
}

/// The server has a different key for this user (it was registered from
/// another phone, or before this app was reinstalled). This phone must not
/// sign: its steps would not verify. An administrator must reset the key.
final class DeviceKeyOtherDevice extends DeviceKeyState {
  const DeviceKeyOtherDevice();
}

/// Something went wrong that trying again later will not fix by itself: the
/// Keystore failed, or the server refused the key. [message] is for the user.
final class DeviceKeyFailed extends DeviceKeyState {
  const DeviceKeyFailed(this.message);
  final String message;

  @override
  String toString() => 'DeviceKeyFailed()';
}

// ---- The controller ----------------------------------------------------------

class DeviceKeyController extends Notifier<DeviceKeyState> {
  /// Counts checks, so the result of an older check (a slow request from
  /// before a logout or a second sign-in) never overwrites a newer state.
  int _generation = 0;

  @override
  DeviceKeyState build() {
    final subscription = ref
        .read(signedInEventsProvider)
        .users
        .listen((user) => unawaited(check(user)));
    ref.onDispose(subscription.cancel);

    // Signed out: forget everything, and let any check still running know
    // that its answer is no longer wanted.
    ref.listen<AuthState>(authControllerProvider, (_, next) {
      if (next is SignedOut || next is AuthUnknown) {
        _generation++;
        state = const DeviceKeyNotNeeded();
      }
    });
    return const DeviceKeyNotNeeded();
  }

  /// Runs the §4 table for [user]. Called for every sign-in; also public so
  /// a later module (sync, M6) can run it once more before sending.
  Future<void> check(User user) async {
    final generation = ++_generation;
    bool stillWanted() => ref.mounted && generation == _generation;

    if (!signingRoles.contains(user.role)) {
      state = const DeviceKeyNotNeeded();
      return;
    }
    state = const DeviceKeyChecking();

    final String alias;
    try {
      alias = deviceKeyAlias(user.id);
    } on ArgumentError {
      // The server always sends a lower-case UUID; anything else is a bug.
      state = const DeviceKeyFailed(AppText.deviceKeyProblem);
      return;
    }
    final channel = ref.read(deviceKeyChannelProvider);

    // 1. The phone's key for this user, if any.
    Uint8List? phoneKey;
    try {
      phoneKey = await channel.publicKey(alias);
    } on DeviceKeyException {
      if (stillWanted()) {
        state = const DeviceKeyFailed(AppText.deviceKeyProblem);
      }
      return;
    }
    if (!stillWanted()) return;

    final serverFingerprint = user.publicKeyFingerprint;

    if (phoneKey != null) {
      final phoneFingerprint = keyFingerprint(phoneKey);
      if (serverFingerprint == phoneFingerprint) {
        state = DeviceKeyReady(phoneFingerprint); // row 3
        return;
      }
      if (serverFingerprint != null) {
        state = const DeviceKeyOtherDevice(); // row 4
        return;
      }
      // Row 2: the phone has a key the server does not know yet (the last
      // PUT got no answer, or an administrator reset the key and this same
      // phone is back). Send THIS key; never make a second one, because the
      // unsynced steps on this phone were signed with it.
    } else {
      if (serverFingerprint != null) {
        // Row 5: the server has a key this phone does not (reinstall, new
        // phone, cleared data). Making a new key here would be pointless:
        // the server keeps the first one until an administrator resets it.
        state = const DeviceKeyOtherDevice();
        return;
      }
      // Row 1: first sign-in on this phone. Create the key.
      try {
        phoneKey = await channel.createKey(alias);
      } on DeviceKeyException catch (e) {
        if (e.error == DeviceKeyError.keyExists) {
          // A check running at the same moment created it first. Use that
          // one: still exactly one key for this alias.
          try {
            phoneKey = await channel.publicKey(alias);
          } on DeviceKeyException {
            phoneKey = null;
          }
        }
        if (phoneKey == null) {
          if (stillWanted()) {
            state = const DeviceKeyFailed(AppText.deviceKeyProblem);
          }
          return;
        }
      }
      if (!stillWanted()) return;
    }

    // Rows 1 and 2: send the key.
    await _register(user, phoneKey, stillWanted);
  }

  Future<void> _register(
    User user,
    Uint8List phoneKey,
    bool Function() stillWanted,
  ) async {
    final phoneFingerprint = keyFingerprint(phoneKey);
    // Until the server confirms, the key is this phone's but not registered.
    state = DeviceKeyUnregistered(phoneFingerprint);

    final auth = ref.read(authControllerProvider);
    if (auth is! SignedIn || auth.user.id != user.id) {
      // The token has expired (or another account is signing in): try again
      // at the next sign-in, which a re-entered password is.
      return;
    }

    final UserParseResult answer;
    try {
      final api = DeviceKeyApi(await ref.read(apiClientProvider.future));
      answer = await api.register(token: auth.token, spki: phoneKey);
    } on PinningSetupError {
      return; // stays unregistered; the safety message is shown elsewhere
    } on AppFailure catch (failure) {
      if (stillWanted()) state = _stateForRefusal(failure, phoneFingerprint);
      return;
    }
    if (!stillWanted()) return;

    switch (answer) {
      case UserParsed(user: final fresh)
          when fresh.id == user.id &&
              fresh.publicKeyFingerprint == phoneFingerprint:
        state = DeviceKeyReady(phoneFingerprint);
        // Saved, so the next start knows the key is registered, and handed
        // to the auth controller, so the user in memory matches.
        try {
          await ref.read(sessionStoreProvider).saveUser(fresh);
        } on SecureStoreException {
          // Registered all the same; at worst the next sign-in sends the
          // same key again, which the server answers with 200.
        }
        if (ref.mounted) {
          ref.read(authControllerProvider.notifier).userUpdated(fresh);
        }
      case UserParsed():
        // 200, but not for this account or not this key: should never
        // happen, and must not be called "registered".
        state = const DeviceKeyFailed(AppText.deviceKeyProblem);
      case UserUnsupportedRole() || UserMalformed():
        // An answer the app cannot read. The PUT is a harmless repeat, so
        // leave it to the next sign-in.
        break;
    }
  }

  /// What a refused or failed PUT means (plan §4, "PUT answers").
  static DeviceKeyState _stateForRefusal(
    AppFailure failure,
    String phoneFingerprint,
  ) {
    if (failure is! ServerRefused) {
      // No network, timed out, an unsafe connection, an unreadable answer:
      // nothing was decided. The same key goes again at the next sign-in.
      return DeviceKeyUnregistered(phoneFingerprint);
    }
    return switch (failure.code) {
      // "This account already has a different device key."
      ApiCodes.publicKeyAlreadyRegistered => const DeviceKeyOtherDevice(),
      // Another account has this key. Each account has its own alias on
      // this phone, so this means a bug; the server's own words say what.
      ApiCodes.publicKeyInUse => DeviceKeyFailed(failureText(failure)),
      // The key is malformed, or the body was, or the server says this role
      // does not sign (FORBIDDEN): an app bug either way.
      ApiCodes.invalidPublicKey ||
      ApiCodes.validationFailed ||
      ApiCodes.forbidden => const DeviceKeyFailed(AppText.deviceKeyProblem),
      // 401 and 403 have already gone through SessionEvents (logout or
      // "enter your password"); a server fault (500) decided nothing. Either
      // way the key is still this phone's, to be sent at the next sign-in.
      _ => DeviceKeyUnregistered(phoneFingerprint),
    };
  }
}

/// The Keystore channel. A provider, so tests can put a fake in its place.
final deviceKeyChannelProvider = Provider<DeviceKeyChannel>(
  (ref) => DeviceKeyChannel(),
);

/// Kept for the whole run (not autoDispose): it must be listening before the
/// first sign-in is announced. main.dart creates it before restore().
final deviceKeyControllerProvider =
    NotifierProvider<DeviceKeyController, DeviceKeyState>(
      DeviceKeyController.new,
    );
