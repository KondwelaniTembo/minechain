// TEST ONLY: an in-memory SecureStore, so tests never touch the phone's
// Keystore. It lives under test/, so it can never be built into the app.

import 'package:minechain/core/storage/secure_store.dart';

class FakeSecureStore implements SecureStore {
  FakeSecureStore([Map<String, String>? initial]) : values = {...?initial};

  /// What is "saved", for tests to inspect or prepare.
  final Map<String, String> values;

  /// Set to make every read fail, as a broken Keystore would.
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw const SecureStoreException('read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
