// A tiny key-value store for secrets (the login token today; the local
// database key in a later module), backed by flutter_secure_storage.
//
// Why an interface of our own: the rest of the app only needs read, write and
// delete of one key. Hiding the package behind three methods means the options
// below are set in exactly one place, tests use an in-memory fake (no phone
// needed), and there is deliberately no "delete everything" to call by
// mistake.
//
// How the package stores data on Android (read in flutter_secure_storage
// 11.2.0's own source): each value is encrypted with AES-256-GCM and the result
// is kept in the app's private SharedPreferences file. The AES key itself is
// stored "wrapped" (encrypted) by an RSA key that lives inside the Android
// Keystore and can never be read out of it. So the file alone is useless to
// someone who copies it off the phone.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secret storage: one string value per key.
abstract interface class SecureStore {
  /// The value for [key], or null if there is none.
  /// Throws [SecureStoreException] if the store cannot be read.
  Future<String?> read(String key);

  /// Saves [value] under [key], replacing any old value.
  /// Throws [SecureStoreException] if it cannot be saved.
  Future<void> write(String key, String value);

  /// Removes [key] and its value. Nothing happens if there is none.
  /// Throws [SecureStoreException] if it cannot be removed.
  Future<void> delete(String key);
}

/// The store could not be used, for example a Keystore fault. Carries no
/// value and no platform message: those could contain stored data.
final class SecureStoreException implements Exception {
  const SecureStoreException(this.operation);

  /// "read", "write" or "delete".
  final String operation;

  @override
  String toString() => 'SecureStoreException($operation)';
}

/// The real store, on the phone.
class FlutterSecureStore implements SecureStore {
  FlutterSecureStore() : _storage = const FlutterSecureStorage(aOptions: _android);

  final FlutterSecureStorage _storage;

  // The Android settings, chosen from the package's 11.2.0 source:
  //
  // - The default ciphers: RSA-OAEP (in the Keystore) wraps an AES key, and
  //   data is encrypted with AES-256-GCM. The other choice, an AES key kept
  //   directly in the Keystore (KeyCipherAlgorithm.AES_GCM_NoPadding), makes
  //   the key need the user's PIN or fingerprint whenever the phone has a
  //   screen lock, and makes it unusable while the phone is locked
  //   (setUnlockedDeviceRequired). That would mean a prompt at every start
  //   (against NFR-06) and no syncing in the background later.
  //
  // - resetOnError: false. With the package's default (true), ANY error
  //   during a read or write makes it silently delete every value it holds and
  //   carry on. Later this store also holds the local database key, and losing
  //   that would lose every unsynced step (NFR-04). We would rather get an
  //   error and decide what to do.
  //
  // - No storageNamespace: there is one store for the whole app, so isolation
  //   from other stores brings nothing, and the default layout is the one the
  //   package has used longest.
  static const AndroidOptions _android = AndroidOptions(resetOnError: false);

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      throw const SecureStoreException('read');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException {
      throw const SecureStoreException('write');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      throw const SecureStoreException('delete');
    }
  }
}

/// The app's secure store. Tests replace it with an in-memory fake.
final secureStoreProvider = Provider<SecureStore>((ref) => FlutterSecureStore());
