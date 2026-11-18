// The Dart end of the "minechain/device_key" platform channel (plan M1,
// decision Mobile (4)). The Kotlin end is DeviceKeyPlugin.kt.
//
// A platform channel is a named pipe between Dart and the Android code of the
// same app. Dart sends a method name and arguments, Kotlin runs the work and
// sends back a result or an error code. Values are converted on the way:
// a Dart Uint8List arrives in Kotlin as a ByteArray, and back.
//
// This wrapper adds three things on top of the raw channel:
// - typed methods, so no other code spells the method names;
// - one exception type with a fixed set of reasons, so callers can switch
//   on them;
// - size checks on what comes back, so a wrong answer fails here rather than
//   at the server.
//
// The private key never crosses this channel: only public keys and
// signatures do.

import 'package:flutter/services.dart';

/// Why a device key operation failed. The first four match the Kotlin codes
/// exactly.
enum DeviceKeyError {
  /// The alias, or the bytes to sign, were refused (a bug in the caller).
  badArgument,

  /// There is no key with this alias on this phone.
  keyNotFound,

  /// createKey was asked for an alias that already has a key.
  keyExists,

  /// The Keystore failed, or answered with something unexpected.
  keystoreError,

  /// The channel is not there: not running on Android, or the Kotlin side
  /// was not registered.
  unavailable,
}

/// Thrown by [DeviceKeyChannel]. It carries only the reason: the Kotlin side
/// sends no message or details, so nothing about the device or the key can
/// end up in a log or on screen through it.
class DeviceKeyException implements Exception {
  const DeviceKeyException(this.error);

  final DeviceKeyError error;

  @override
  String toString() => 'DeviceKeyException(${error.name})';
}

class DeviceKeyChannel {
  DeviceKeyChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'minechain/device_key';

  /// A P-256 public key in SPKI DER form (signing spec, section 2).
  static const int publicKeyLength = 91;

  /// A DER ECDSA signature is never more than 72 bytes for P-256, and the
  /// server refuses fewer than 8 (api.md, SIGNATURE_MALFORMED).
  static const int minSignatureLength = 8;
  static const int maxSignatureLength = 72;

  final MethodChannel _channel;

  /// The public key of [alias], or null when this phone has no such key.
  Future<Uint8List?> publicKey(String alias) async {
    final result = await _invoke('publicKey', {'alias': alias});
    if (result == null) return null;
    return _checkedPublicKey(result);
  }

  /// Makes a new P-256 signing key for [alias] inside the Keystore and returns
  /// its public key. Throws [DeviceKeyError.keyExists] if [alias] already has
  /// one: a key is never replaced from the app.
  Future<Uint8List> createKey(String alias) async {
    final result = await _invoke('createKey', {'alias': alias});
    return _checkedPublicKey(result);
  }

  /// Signs [bytes] with [alias]'s key and returns the DER signature.
  ///
  /// [bytes] are the payload itself, never its hash: SHA256withECDSA hashes
  /// them inside the Keystore (signing spec, section 5).
  Future<Uint8List> sign(String alias, Uint8List bytes) async {
    final result = await _invoke('sign', {'alias': alias, 'bytes': bytes});
    if (result is! Uint8List ||
        result.length < minSignatureLength ||
        result.length > maxSignatureLength) {
      throw const DeviceKeyException(DeviceKeyError.keystoreError);
    }
    return result;
  }

  Future<Object?> _invoke(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw DeviceKeyException(_errorFor(e.code));
    } on MissingPluginException {
      throw const DeviceKeyException(DeviceKeyError.unavailable);
    }
  }

  static Uint8List _checkedPublicKey(Object? result) {
    if (result is! Uint8List || result.length != publicKeyLength) {
      throw const DeviceKeyException(DeviceKeyError.keystoreError);
    }
    return result;
  }

  static DeviceKeyError _errorFor(String code) => switch (code) {
    'BAD_ARGUMENT' => DeviceKeyError.badArgument,
    'KEY_NOT_FOUND' => DeviceKeyError.keyNotFound,
    'KEY_EXISTS' => DeviceKeyError.keyExists,
    // KEYSTORE_ERROR, and any code a future Kotlin version might add.
    _ => DeviceKeyError.keystoreError,
  };
}
