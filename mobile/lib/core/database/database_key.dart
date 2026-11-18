// The local database's key: 32 random bytes, made on the first open and kept
// in the secure store (decision Mobile (1)).
//
// Why random and not made from the password: there is nothing for the user to
// remember or forget, and it does not change when the password does.
//
// Why the secure store: its values are encrypted with a key that lives in the
// Android Keystore (secure_store.dart), and it runs with resetOnError: false
// (decision Mobile (19)), so a storage fault is reported instead of silently
// wiping the values, this key among them.
//
// SECURITY: the key is never logged, never put in an exception, and never
// leaves this file except as the value handed to the opening code.

import 'dart:math';

import '../storage/secure_store.dart';
import 'database_failure.dart';

/// The secure store's name for the key. Not one of the session keys, so a
/// logout (SessionStore.clear) never removes it.
const String databaseKeyName = 'db.key';

/// 32 bytes as 64 lower-case hex characters.
final RegExp _keyHex = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] has the shape of a key. The opening code checks this
/// again before putting it into a PRAGMA.
bool isDatabaseKeyHex(String value) => _keyHex.hasMatch(value);

class DatabaseKeyStore {
  DatabaseKeyStore(this._store, {Random? random})
    : _random = random ?? Random.secure();

  final SecureStore _store;
  final Random _random;

  /// The key as hex. Creates one only when there is none AND there is no
  /// database file yet ([databaseExists] false): a file without its key must
  /// never be answered with a fresh key, which would hide the old file's
  /// loss and then fail to open it anyway.
  ///
  /// Throws [DatabaseKeyUnavailable] or [DatabaseKeyMissing].
  Future<String> readOrCreate({required bool databaseExists}) async {
    final String? saved;
    try {
      saved = await _store.read(databaseKeyName);
    } on SecureStoreException {
      throw const DatabaseKeyUnavailable();
    }

    if (saved != null) {
      // Something is stored but it is not a key: never overwrite it.
      if (!isDatabaseKeyHex(saved)) throw const DatabaseKeyUnavailable();
      return saved;
    }
    if (databaseExists) throw const DatabaseKeyMissing();

    final key = _newKey();
    try {
      await _store.write(databaseKeyName, key);
      // Read it back: only a key that is really stored may be used, or the
      // file would be encrypted with a key the next start cannot find.
      if (await _store.read(databaseKeyName) != key) {
        throw const DatabaseKeyUnavailable();
      }
    } on SecureStoreException {
      throw const DatabaseKeyUnavailable();
    }
    return key;
  }

  String _newKey() {
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
