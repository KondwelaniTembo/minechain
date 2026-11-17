// The database key: made once, kept, never replaced behind the user's back.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/database/database_failure.dart';
import 'package:minechain/core/database/database_key.dart';
import 'package:minechain/core/storage/secure_store.dart';

import '../../fakes/fake_secure_store.dart';

/// A store whose writes fail, as a broken Keystore would.
class _WriteFailingStore extends FakeSecureStore {
  @override
  Future<void> write(String key, String value) async =>
      throw const SecureStoreException('write');
}

void main() {
  test('first open, no file: makes a 32-byte key and stores it', () async {
    final store = FakeSecureStore();

    final key = await DatabaseKeyStore(store)
        .readOrCreate(databaseExists: false);

    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(store.values[databaseKeyName], key);
  });

  test('later opens get the same key', () async {
    final store = FakeSecureStore();
    final keys = DatabaseKeyStore(store);

    final first = await keys.readOrCreate(databaseExists: false);
    final second = await keys.readOrCreate(databaseExists: true);

    expect(second, first);
  });

  test('two phones (stores) get different keys', () async {
    final a = await DatabaseKeyStore(
      FakeSecureStore(),
      random: Random(1),
    ).readOrCreate(databaseExists: false);
    final b = await DatabaseKeyStore(
      FakeSecureStore(),
      random: Random(2),
    ).readOrCreate(databaseExists: false);
    expect(a, isNot(b));
  });

  test('a file without its key: refused, and no new key is made', () async {
    final store = FakeSecureStore();

    await expectLater(
      DatabaseKeyStore(store).readOrCreate(databaseExists: true),
      throwsA(isA<DatabaseKeyMissing>()),
    );
    expect(store.values, isEmpty);
  });

  test('the store cannot be read: refused', () async {
    final store = FakeSecureStore()..failReads = true;

    await expectLater(
      DatabaseKeyStore(store).readOrCreate(databaseExists: false),
      throwsA(isA<DatabaseKeyUnavailable>()),
    );
  });

  test('the key cannot be saved: refused, nothing to open with', () async {
    await expectLater(
      DatabaseKeyStore(_WriteFailingStore())
          .readOrCreate(databaseExists: false),
      throwsA(isA<DatabaseKeyUnavailable>()),
    );
  });

  test(
    'something stored that is not a key: refused and NOT overwritten',
    () async {
      final store = FakeSecureStore({databaseKeyName: 'not a key'});

      await expectLater(
        DatabaseKeyStore(store).readOrCreate(databaseExists: true),
        throwsA(isA<DatabaseKeyUnavailable>()),
      );
      expect(store.values[databaseKeyName], 'not a key');
    },
  );

  test('failures print no key', () {
    for (final failure in const <DatabaseFailure>[
      DatabaseKeyUnavailable(),
      DatabaseKeyMissing(),
      DatabaseWrongKey(),
    ]) {
      expect(failure.toString(), isNot(matches(RegExp('[0-9a-f]{16}'))));
    }
  });

  test('the key name is not a session key, so logout never removes it', () {
    expect(databaseKeyName.startsWith('auth.'), isFalse);
  });
}
