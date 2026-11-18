// TEST ONLY: a stand-in for the Keystore channel. Keys are kept in a map by
// alias, as the Keystore keeps them. It records every call, and fails the
// test outright if anything asks it to sign: M2 only reads, creates and
// registers public keys.

import 'dart:typed_data';

import 'package:minechain/features/device_key/data/device_key_channel.dart';

class FakeDeviceKeyChannel extends DeviceKeyChannel {
  FakeDeviceKeyChannel({Map<String, Uint8List>? keys, Uint8List? nextKey})
    : keys = {...?keys},
      nextKey = nextKey ?? fakeKey(1);

  /// The keys "in the Keystore", by alias.
  final Map<String, Uint8List> keys;

  /// What the next createKey makes.
  Uint8List nextKey;

  /// Set to make publicKey or createKey fail with that reason.
  DeviceKeyError? failPublicKey;
  DeviceKeyError? failCreate;

  /// Makes createKey behave as if another check created the key a moment
  /// earlier: the key is stored, but this call is refused with keyExists.
  bool createLosesRace = false;

  /// Every call, as `publicKey:ALIAS` or `createKey:ALIAS`.
  final List<String> calls = [];

  int get createCalls => calls.where((c) => c.startsWith('createKey')).length;

  @override
  Future<Uint8List?> publicKey(String alias) async {
    calls.add('publicKey:$alias');
    final failure = failPublicKey;
    if (failure != null) throw DeviceKeyException(failure);
    return keys[alias];
  }

  @override
  Future<Uint8List> createKey(String alias) async {
    calls.add('createKey:$alias');
    final failure = failCreate;
    if (failure != null) throw DeviceKeyException(failure);
    // The real Kotlin side refuses to overwrite, and so does this.
    if (keys.containsKey(alias)) {
      throw const DeviceKeyException(DeviceKeyError.keyExists);
    }
    keys[alias] = nextKey;
    if (createLosesRace) {
      throw const DeviceKeyException(DeviceKeyError.keyExists);
    }
    return nextKey;
  }

  @override
  Future<Uint8List> sign(String alias, Uint8List bytes) =>
      throw StateError('Registering a device key must never sign anything.');
}

/// A 91-byte stand-in for an SPKI key. Different [n], different bytes, so
/// different fingerprints. Not a real key: nothing here verifies signatures.
Uint8List fakeKey(int n) {
  final bytes = Uint8List(91);
  bytes[0] = 0x30;
  bytes[90] = n;
  return bytes;
}
